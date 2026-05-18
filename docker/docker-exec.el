;;; docker-exec.el --- Run commands inside containers via the engine API -*- lexical-binding: t -*-
;;
;; Two-step exec like the daemon's API:
;;   1. POST /containers/{id}/exec        → returns an exec instance Id
;;   2. POST /exec/{id}/start             → hijacks the connection, raw bytes
;;
;; When called with TTY=t, the daemon returns one unmultiplexed stream
;; and we hand the network process to `docker-terminal-attach' for
;; rendering.  Non-TTY exec demultiplexes stdout/stderr the same way
;; logs do.

(require 'cl-lib)
(require 'docker-api)
(require 'docker-http)
(require 'docker-stream)
(require 'docker-terminal)

(defun docker-exec--create (cfg container cmd tty)
  "POST /containers/{id}/exec, return the new exec instance Id.
CMD is a list of strings; we encode it as a JSON array."
  (let ((result (docker-engine-post
                 cfg (format "/containers/%s/exec" container)
                 :json `((AttachStdin . ,(if tty t :false))
                         (AttachStdout . t)
                         (AttachStderr . t)
                         (Tty . ,(if tty t :false))
                         (Cmd . ,(apply #'vector cmd))))))
    (alist-get 'Id result)))

(defun docker-exec--start-hijacked (cfg exec-id tty on-chunk on-close)
  "POST /exec/{id}/start, stream bytes back via ON-CHUNK.
With TTY=t we negotiate a real hijack (Upgrade: tcp), so the same
socket carries both the daemon's output (to ON-CHUNK) AND the user's
keystrokes (via `process-send-string' from the caller).  Without TTY
we let the daemon use chunked transfer for the multiplexed stream.
Returns the live network process; ON-CLOSE fires on EOF."
  (let* ((body (json-serialize
                `((Detach . :false) (Tty . ,(if tty t :false)))
                :null-object nil :false-object :false))
         (headers (if tty
                      '(("Content-Type" . "application/json")
                        ("Upgrade" . "tcp")
                        ("Connection" . "Upgrade"))
                    '(("Content-Type" . "application/json")))))
    (docker-http-stream
     cfg "POST"
     (format "%s/exec/%s/start" (docker--api-prefix cfg) exec-id)
     :headers headers
     :body body
     :on-chunk on-chunk
     :on-close on-close)))

;;;###autoload
(defun docker-exec-at-point (&optional cmd)
  "Exec a command in the container at point.  Prompts for CMD if not given.
With prefix arg, force non-TTY mode (capture output, no terminal emulator)."
  (interactive)
  (let* ((c (docker--container-at-point))
         (cname (docker-container-name c))
         (cfg (docker--ensure-config))
         (tty (not current-prefix-arg))
         (cmd (or cmd (read-shell-command
                       (format "Exec in %s: " cname)
                       (if tty "/bin/sh" "/bin/sh -c 'uname -a'"))))
         (argv (split-string-shell-command cmd))
         (exec-id (docker-exec--create cfg cname argv tty)))
    (if tty
        (docker-exec--start-tty cfg cname exec-id)
      (docker-exec--start-non-tty cfg cname exec-id))))

(defvar-local docker-exec--id nil
  "Engine exec instance Id for this buffer (used by the resize hook).")
(defvar-local docker-exec--config nil
  "Docker config for this exec buffer (used by the resize hook).")
(defvar-local docker-exec--last-dim nil
  "Last (HEIGHT . WIDTH) we posted to /exec/{id}/resize.")

(defun docker-exec--post-resize (cfg exec-id h w)
  "POST a resize for EXEC-ID to (H, W).  Errors are swallowed."
  (ignore-errors
    (docker-engine-post cfg (format "/exec/%s/resize" exec-id)
                        :query `(("h" . ,(format "%d" h))
                                 ("w" . ,(format "%d" w))))))

(defun docker-exec--maybe-resize (buf)
  "Post a resize if BUF's window size differs from the last one we sent.
Resizes both the local terminal emulator and the remote PTY."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and docker-exec--id docker-exec--config)
        (let* ((dim (docker-terminal-window-size buf))
               (h (car dim)) (w (cdr dim)))
          (unless (and docker-exec--last-dim
                       (equal docker-exec--last-dim (cons h w)))
            (setq docker-exec--last-dim (cons h w))
            (docker-terminal-resize buf h w)
            (docker-exec--post-resize docker-exec--config
                                      docker-exec--id h w)))))))

(defun docker-exec--window-size-change (frame)
  "`window-size-change-functions' hook: resize every visible exec buffer."
  (dolist (win (window-list frame))
    (let ((buf (window-buffer win)))
      (when (and (buffer-live-p buf)
                 (buffer-local-value 'docker-exec--id buf))
        (docker-exec--maybe-resize buf)))))

(defun docker-exec--start-tty (cfg cname exec-id)
  "Launch a TTY exec into CNAME and host it in the configured terminal backend.
The Upgrade hijack makes the same socket bidirectional: docker-http's
stream filter strips the response headers, `docker-terminal-feed' pushes
the decoded body bytes into the backend (eat / vterm / term), and
`docker-terminal-bind' routes the user's keystrokes back over the same
process.  A `window-size-change-functions' hook keeps the remote PTY in
sync with the Emacs window."
  (let* ((bufname (format "*docker:exec:%s*" cname))
         (buf (docker-terminal-open bufname))
         (deliver (lambda (bytes) (docker-terminal-feed buf bytes)))
         (proc (docker-exec--start-hijacked
                cfg exec-id t deliver nil)))
    (with-current-buffer buf
      (setq docker-exec--id exec-id
            docker-exec--config cfg
            docker-exec--last-dim nil))
    (docker-terminal-bind buf proc)
    (add-hook 'window-size-change-functions
              #'docker-exec--window-size-change)
    (pop-to-buffer buf)
    ;; Best-effort initial sync once the buffer is in a window so
    ;; `window-body-height/width' return real numbers.
    (docker-exec--maybe-resize buf)
    buf))

(defun docker-exec--start-non-tty (cfg cname exec-id)
  "Run a non-TTY exec, demultiplex into a buffer, return that buffer."
  (let* ((bufname (format "*docker:exec:%s*" cname))
         (buf (get-buffer-create bufname))
         (demux
          (docker-stream-make-demux
           (lambda (typ payload)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (let ((inhibit-read-only t)
                       (face (pcase typ
                               ('stderr 'docker-logs-stderr)
                               (_       'docker-logs-stdout))))
                   (goto-char (point-max))
                   (insert (propertize payload 'font-lock-face face)))))))))
    (with-current-buffer buf
      (let ((inhibit-read-only t)) (erase-buffer))
      (special-mode))
    (docker-exec--start-hijacked
     cfg exec-id nil
     (lambda (bytes) (funcall demux bytes))
     nil)
    (pop-to-buffer buf)
    buf))

(provide 'docker-exec)
;;; docker-exec.el ends here
