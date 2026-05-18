;;; docker-pull.el --- Pull images via the engine API -*- lexical-binding: t -*-
;;
;; Implements `docker pull' on top of `POST /images/create?fromImage='.
;; The endpoint streams newline-delimited JSON progress events; we
;; render them into a `*docker:pull:NAME*' buffer.  Registry auth is
;; resolved through `docker-auth' if the user has run `docker login'.

(require 'cl-lib)
(require 'docker-api)
(require 'docker-http)
(require 'docker-stream)
(require 'docker-auth)

(defun docker-pull--registry-from-image (image)
  "Return the registry hostname embedded in IMAGE, or nil for Docker Hub."
  (let ((slash (string-search "/" image)))
    (when slash
      (let ((prefix (substring image 0 slash)))
        (when (or (string-search "." prefix)
                  (string-search ":" prefix)
                  (string= prefix "localhost"))
          prefix)))))

(defun docker-pull--split-image-tag (image)
  "Split IMAGE into (REPO . TAG); default TAG is `latest'."
  (let ((last-colon (cl-loop for i from (1- (length image)) downto 0
                             when (eq (aref image i) ?:) return i))
        (last-slash (cl-loop for i from (1- (length image)) downto 0
                             when (eq (aref image i) ?/) return i)))
    (cond
     ;; "host:5000/repo" → no tag
     ((or (null last-colon)
          (and last-slash (< last-colon last-slash)))
      (cons image "latest"))
     (t
      (cons (substring image 0 last-colon) (substring image (1+ last-colon)))))))

(defun docker-pull--render-progress (buf event)
  "Render one JSON progress EVENT into BUF in a stable place."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (status (alist-get 'status event))
            (id (alist-get 'id event))
            (progress (alist-get 'progress event))
            (error-msg (alist-get 'error event)))
        (cond
         (error-msg
          (goto-char (point-max))
          (insert (propertize (format "[error] %s\n" error-msg)
                              'font-lock-face 'error)))
         (id
          ;; Per-layer line: replace any existing one for this id (the
          ;; whole physical line, newline included).
          (goto-char (point-min))
          (if (re-search-forward (format "^%s: " (regexp-quote id)) nil t)
              (progn (beginning-of-line)
                     (delete-region (point)
                                    (min (point-max) (1+ (line-end-position)))))
            (goto-char (point-max)))
          (insert (format "%s: %-30s %s\n"
                          id (or status "")
                          (or progress ""))))
         (status
          (goto-char (point-max))
          (insert status "\n")))))))

;;;###autoload
(defun docker-pull-image (cfg image)
  "Pull IMAGE (e.g. \"nginx\" or \"ghcr.io/foo/bar:1.2\") into the local daemon.
Surfaces the daemon's streamed progress in a `*docker:pull:IMAGE*'
buffer.  Returns the buffer."
  (interactive (list (docker--ensure-config)
                     (read-string "Image to pull: ")))
  (let* ((registry (docker-pull--registry-from-image image))
         (parts (docker-pull--split-image-tag image))
         (repo (car parts))
         (tag (cdr parts))
         (auth (docker-auth-header registry))
         (bufname (format "*docker:pull:%s*" image))
         (buf (get-buffer-create bufname))
         (ndjson (docker-stream-make-ndjson
                  (lambda (event)
                    (docker-pull--render-progress buf event)))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize
                 (format "POST /images/create?fromImage=%s&tag=%s\n\n" repo tag)
                 'font-lock-face 'shadow)))
      (special-mode))
    (docker-http-stream
     cfg "POST" "/images/create"
     :query `(("fromImage" . ,repo) ("tag" . ,tag))
     :headers (when auth `(("X-Registry-Auth" . ,auth)))
     :on-chunk (lambda (bytes) (funcall ndjson bytes))
     :on-close (lambda ()
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (let ((inhibit-read-only t))
                       (goto-char (point-max))
                       (insert (propertize "\n[done]\n"
                                           'font-lock-face 'shadow)))))))
    (pop-to-buffer buf)
    buf))

(provide 'docker-pull)
;;; docker-pull.el ends here
