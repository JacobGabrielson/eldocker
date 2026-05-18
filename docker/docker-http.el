;;; docker-http.el --- HTTP/1.1 client for the Docker engine API -*- lexical-binding: t -*-
;;
;; Speaks HTTP/1.1 to a Docker daemon over a Unix domain socket, plain
;; TCP, or TLS-wrapped TCP.  This is the transport for the no-CLI
;; rewrite: every module that needs to talk to docker eventually routes
;; through here.  See docs/direct-daemon-rewrite.md.
;;
;; Hard requirements (the rewrite is Emacs 30+ only):
;; - Native JSON parser (`json-parse-string').  Checked at load time.
;; - GnuTLS — checked lazily, only when a TLS-requiring `docker-config'
;;   is actually used.  Unix-socket and plain-TCP daemons need no TLS.
;;
;; Public API:
;;   (docker-http-request CFG METHOD PATH &key headers body query)
;;     → `docker-http-response'
;;   (docker-http-json RESPONSE) → decoded JSON
;;
;; Streaming (`docker-http-stream') is deferred to a later phase.

(require 'cl-lib)
(require 'gnutls)
(require 'url-util)
(require 'docker-config)

;; Load-time capability check: native JSON.
(unless (fboundp 'json-parse-string)
  (error "eldocker requires native JSON support (Emacs built --with-json)"))

(defgroup docker-http nil
  "HTTP transport for the Docker engine API."
  :group 'docker)

(defcustom docker-http-default-tcp-port 2375
  "Default TCP port for plain (non-TLS) `tcp://' daemons."
  :type 'integer
  :group 'docker-http)

(defcustom docker-http-default-tls-port 2376
  "Default TCP port for TLS-wrapped `tcp://' daemons."
  :type 'integer
  :group 'docker-http)

;;; ---------------------------------------------------------------------------
;;; Response type

(cl-defstruct (docker-http-response
               (:constructor docker-http-response--new)
               (:copier nil))
  "An HTTP response from the Docker engine."
  status     ; integer HTTP status code
  reason     ; status reason phrase
  headers    ; alist of (LOWERCASE-NAME . VALUE) strings
  body)      ; raw body string after transfer-encoding decode

(define-error 'docker-http-error "Docker HTTP error")

;;; ---------------------------------------------------------------------------
;;; Connection

(defun docker-http--require-tls (host)
  "Refuse if GnuTLS is unavailable but HOST is a TLS endpoint."
  (unless (gnutls-available-p)
    (error
     "eldocker: TLS required for %s but Emacs lacks GnuTLS — rebuild --with-gnutls"
     host)))

(defun docker-http--connect (cfg)
  "Open a network process to the daemon described by CFG.
Returns a live process whose buffer accumulates the raw response."
  (let* ((host (docker-config-host cfg))
         (port (docker-config-port cfg))
         (socket-path (docker-config-socket-path cfg))
         (tls-verify (docker-config-tls-verify cfg))
         (buf (generate-new-buffer " *docker-http*")))
    (condition-case err
        (cond
         (socket-path
          (make-network-process
           :name "docker-http"
           :buffer buf
           :family 'local
           :service socket-path
           :coding '(binary . binary)
           :nowait nil))
         ((and host tls-verify)
          (docker-http--require-tls host)
          (make-network-process
           :name "docker-http"
           :buffer buf
           :host host
           :service (or port docker-http-default-tls-port)
           :coding '(binary . binary)
           :nowait nil
           :tls-parameters
           (cons 'gnutls-x509pki
                 (gnutls-boot-parameters
                  :type 'gnutls-x509pki
                  :hostname host
                  :trustfiles (when (docker-config-tls-ca-cert cfg)
                                (list (docker-config-tls-ca-cert cfg)))
                  :keylist (when (and (docker-config-tls-cert cfg)
                                      (docker-config-tls-key cfg))
                             (list (list (docker-config-tls-cert cfg)
                                         (docker-config-tls-key cfg))))))))
         (host
          (make-network-process
           :name "docker-http"
           :buffer buf
           :host host
           :service (or port docker-http-default-tcp-port)
           :coding '(binary . binary)
           :nowait nil))
         (t
          (error "docker-http: docker-config has neither socket-path nor host")))
      (error
       (when (buffer-live-p buf) (kill-buffer buf))
       (signal (car err) (cdr err))))))

;;; ---------------------------------------------------------------------------
;;; Request building

(defun docker-http--encode-query (alist)
  "Encode ALIST of (KEY . VALUE) pairs as a URL query string."
  (mapconcat (lambda (p)
               (concat (url-hexify-string (format "%s" (car p)))
                       "="
                       (url-hexify-string (format "%s" (cdr p)))))
             alist "&"))

(defun docker-http--merge-headers (defaults overrides)
  "Combine DEFAULTS and OVERRIDES, letting OVERRIDES win by header name."
  (let ((seen (mapcar (lambda (h) (downcase (car h))) overrides)))
    (append (cl-remove-if (lambda (h)
                            (member (downcase (car h)) seen))
                          defaults)
            overrides)))

(defun docker-http--build-request (method path headers body query)
  "Build a raw HTTP/1.1 request string.
HEADERS take precedence over the per-name defaults; pass e.g.
`((\"Connection\" . \"Upgrade\"))' to override `Connection: close'."
  (let* ((qs (when query (docker-http--encode-query query)))
         (full-path (if (and qs (> (length qs) 0)) (concat path "?" qs) path))
         (default-headers
          (append `(("Host" . "localhost")
                    ("User-Agent" . "eldocker/0.1")
                    ("Accept" . "application/json")
                    ("Connection" . "close"))
                  (when body
                    `(("Content-Length" . ,(number-to-string
                                            (string-bytes body)))))))
         (all-headers (docker-http--merge-headers default-headers headers))
         (header-block
          (mapconcat (lambda (h) (format "%s: %s" (car h) (cdr h)))
                     all-headers "\r\n")))
    (concat method " " full-path " HTTP/1.1\r\n"
            header-block "\r\n\r\n"
            (or body ""))))

;;; ---------------------------------------------------------------------------
;;; Response parsing (also exported for unit testing)

(defun docker-http--parse-status-line (line)
  "Parse \"HTTP/1.1 200 OK\" → (CODE . REASON)."
  (unless (string-match "\\`HTTP/[0-9.]+ \\([0-9]+\\) ?\\(.*\\)\\'" line)
    (signal 'docker-http-error (list "malformed status line" line)))
  (cons (string-to-number (match-string 1 line))
        (match-string 2 line)))

(defun docker-http--parse-headers (header-block)
  "Parse HEADER-BLOCK (CRLF-separated, no trailing CRLFCRLF) into an alist.
Header names are lower-cased; values are trimmed."
  (mapcar (lambda (line)
            (let ((c (string-search ":" line)))
              (unless c
                (signal 'docker-http-error (list "malformed header" line)))
              (cons (downcase (string-trim (substring line 0 c)))
                    (string-trim (substring line (1+ c))))))
          (split-string header-block "\r\n" t)))

(defun docker-http--decode-chunked (body)
  "Decode HTTP/1.1 chunked-transfer BODY into the raw payload string."
  (let ((pos 0) (len (length body)) (chunks nil))
    (while (< pos len)
      (let ((eol (string-search "\r\n" body pos)))
        (unless eol
          (signal 'docker-http-error (list "malformed chunk header at" pos)))
        (let* ((size-hex (substring body pos eol))
               (size (string-to-number
                      (replace-regexp-in-string ";.*\\'" "" size-hex) 16)))
          (setq pos (+ eol 2))
          (if (zerop size)
              (setq pos len)
            (push (substring body pos (+ pos size)) chunks)
            (setq pos (+ pos size 2))))))
    (apply #'concat (nreverse chunks))))

(defun docker-http--decode-body (headers raw-body)
  "Decode RAW-BODY per Transfer-Encoding / Content-Length in HEADERS."
  (cond
   ((string= (alist-get "transfer-encoding" headers nil nil #'string=) "chunked")
    (docker-http--decode-chunked raw-body))
   (t raw-body)))

(defun docker-http--split-response (raw)
  "Split RAW response bytes into (STATUS-LINE HEADERS-BLOCK BODY)."
  (let ((sep (string-search "\r\n\r\n" raw)))
    (unless sep
      (signal 'docker-http-error '("no header/body separator")))
    (let* ((head (substring raw 0 sep))
           (body (substring raw (+ sep 4)))
           (lines (split-string head "\r\n"))
           (status-line (car lines))
           (header-block (mapconcat #'identity (cdr lines) "\r\n")))
      (list status-line header-block body))))

;;; ---------------------------------------------------------------------------
;;; Public: sync request

(cl-defun docker-http-request (cfg method path &key headers body query)
  "Send METHOD PATH (an engine-API path) over CFG.
Return a `docker-http-response'.

QUERY is an alist of (KEY . VALUE) pairs URL-encoded into the path.
HEADERS is an alist of extra request headers (merged on top of defaults).
BODY is a string (typically pre-`json-serialize'd); set this *and*
add a `Content-Type: application/json' header for JSON requests."
  (let ((proc (docker-http--connect cfg))
        (request (docker-http--build-request method path headers body query)))
    (unwind-protect
        (let (raw parts status headers* body*)
          (process-send-string proc request)
          (while (process-live-p proc)
            (accept-process-output proc 1.0))
          (setq raw (with-current-buffer (process-buffer proc)
                      (buffer-string)))
          (setq parts (docker-http--split-response raw))
          (setq status (docker-http--parse-status-line (nth 0 parts)))
          (setq headers* (docker-http--parse-headers (nth 1 parts)))
          (setq body* (docker-http--decode-body headers* (nth 2 parts)))
          (docker-http-response--new
           :status (car status)
           :reason (cdr status)
           :headers headers*
           :body body*))
      (when (process-live-p proc) (delete-process proc))
      (let ((buf (process-buffer proc)))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;; ---------------------------------------------------------------------------
;;; Public: streaming request
;;;
;; Send a request and hand the response off to user-supplied filter
;; callbacks rather than buffering the whole body.  The process the
;; caller gets back is owned by them: kill it to abort the stream.

(cl-defstruct (docker-http--stream-state
               (:constructor docker-http--stream-state--new))
  buffer       ; raw read buffer (string accumulator)
  headers-seen ; t once we've parsed the status line + headers
  chunked      ; t if Transfer-Encoding: chunked
  on-headers
  on-chunk
  on-close)

(defun docker-http--stream-pump-body (state new)
  "Pump NEW bytes into STATE; deliver decoded chunks via on-chunk."
  (let ((buf (concat (docker-http--stream-state-buffer state) new)))
    (cond
     ((docker-http--stream-state-chunked state)
      ;; Pull off whole chunks; leftover stays in the buffer.
      (let ((pos 0) (len (length buf)) (out nil))
        (catch 'done
          (while (< pos len)
            (let ((eol (string-search "\r\n" buf pos)))
              (unless eol (throw 'done nil))
              (let* ((size-hex (substring buf pos eol))
                     (size (string-to-number
                            (replace-regexp-in-string ";.*\\'" "" size-hex)
                            16))
                     (body-start (+ eol 2)))
                (when (zerop size)
                  ;; trailer + close
                  (setq pos len)
                  (throw 'done nil))
                (if (> (+ body-start size 2) len)
                    (throw 'done nil)
                  (push (substring buf body-start (+ body-start size)) out)
                  (setq pos (+ body-start size 2)))))))
        (setf (docker-http--stream-state-buffer state) (substring buf pos))
        (dolist (c (nreverse out))
          (funcall (docker-http--stream-state-on-chunk state) c))))
     (t
      (setf (docker-http--stream-state-buffer state) "")
      (when (> (length buf) 0)
        (funcall (docker-http--stream-state-on-chunk state) buf))))))

(defun docker-http--stream-filter (state)
  "Return a process filter closed over STATE."
  (lambda (proc data)
    (if (docker-http--stream-state-headers-seen state)
        (docker-http--stream-pump-body state data)
      (setf (docker-http--stream-state-buffer state)
            (concat (docker-http--stream-state-buffer state) data))
      (let* ((buf (docker-http--stream-state-buffer state))
             (sep (string-search "\r\n\r\n" buf)))
        (when sep
          (let* ((head (substring buf 0 sep))
                 (rest (substring buf (+ sep 4)))
                 (lines (split-string head "\r\n"))
                 (status-line (car lines))
                 (header-block (mapconcat #'identity (cdr lines) "\r\n"))
                 (status (docker-http--parse-status-line status-line))
                 (headers (docker-http--parse-headers header-block))
                 (chunked (string= (alist-get "transfer-encoding"
                                              headers nil nil #'string=)
                                   "chunked")))
            (setf (docker-http--stream-state-headers-seen state) t)
            (setf (docker-http--stream-state-chunked state) chunked)
            (setf (docker-http--stream-state-buffer state) "")
            (when (docker-http--stream-state-on-headers state)
              (funcall (docker-http--stream-state-on-headers state)
                       (car status) (cdr status) headers))
            (docker-http--stream-pump-body state rest)))
        (ignore proc)))))

(defun docker-http--stream-sentinel (state)
  "Return a process sentinel for STATE; fires on-close on EOF."
  (lambda (proc _event)
    (unless (process-live-p proc)
      (when (docker-http--stream-state-on-close state)
        (funcall (docker-http--stream-state-on-close state))))))

(cl-defun docker-http-stream (cfg method path
                                  &key headers body query
                                       on-headers on-chunk on-close)
  "Send METHOD PATH and stream the body via callbacks.
Returns the live process so the caller can `delete-process' to abort.
HEADERS, BODY, QUERY behave like in `docker-http-request'.
Callbacks:
  ON-HEADERS  (lambda (STATUS REASON HEADERS-ALIST))
  ON-CHUNK    (lambda (BYTES))  — invoked for each whole decoded chunk
  ON-CLOSE    (lambda ())       — invoked once when the daemon closes"
  (unless on-chunk
    (error "docker-http-stream: on-chunk is required"))
  (let* ((proc (docker-http--connect cfg))
         (state (docker-http--stream-state--new
                 :buffer ""
                 :headers-seen nil
                 :chunked nil
                 :on-headers on-headers
                 :on-chunk on-chunk
                 :on-close on-close))
         (req (docker-http--build-request method path headers body query)))
    (set-process-filter proc (docker-http--stream-filter state))
    (set-process-sentinel proc (docker-http--stream-sentinel state))
    (process-send-string proc req)
    proc))

(defun docker-http-ok-p (response)
  "Return non-nil when RESPONSE is a 2xx status."
  (let ((s (docker-http-response-status response)))
    (and (>= s 200) (< s 300))))

(defun docker-http-json (response)
  "Parse RESPONSE's body as JSON, returning alists/lists per house style.
Returns nil for an empty body.  Signals `docker-http-error' on malformed JSON."
  (let ((body (docker-http-response-body response)))
    (when (and body (> (length body) 0))
      (condition-case err
          (json-parse-string body
                             :object-type 'alist
                             :array-type 'list
                             :null-object nil
                             :false-object :false)
        (error (signal 'docker-http-error
                       (list "JSON parse failed" (error-message-string err))))))))

(provide 'docker-http)
;;; docker-http.el ends here
