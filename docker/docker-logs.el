;;; docker-logs.el --- Stream container logs via the engine API -*- lexical-binding: t -*-
;;
;; Direct-to-daemon log streaming.  We open
;; `GET /containers/{id}/logs?follow=1&stdout=1&stderr=1' and run the
;; bytes through `docker-stream-make-demux' so stdout and stderr land
;; with distinct faces.  When the daemon attaches a TTY to the
;; container the response is *not* multiplexed; we detect that via the
;; container's `Config.Tty' and skip the demuxer.

(require 'cl-lib)
(require 'docker-api)
(require 'docker-http)
(require 'docker-stream)
(require 'docker-ps)

(defcustom docker-logs-default-tail 200
  "Default number of historical lines to fetch on open."
  :type '(choice (const :tag "All history" "all") integer)
  :group 'docker)

(defcustom docker-logs-follow t
  "When non-nil, follow the log stream as new lines arrive."
  :type 'boolean
  :group 'docker)

(defcustom docker-logs-timestamps nil
  "When non-nil, include per-line timestamps from the daemon."
  :type 'boolean
  :group 'docker)

(defface docker-logs-stdout
  '((t :inherit default))
  "Face for stdout log bytes."
  :group 'docker)

(defface docker-logs-stderr
  '((t :inherit error))
  "Face for stderr log bytes."
  :group 'docker)

(defvar-local docker-logs--container nil)
(defvar-local docker-logs--process nil)
(defvar-local docker-logs--config nil)

(defvar-keymap docker-logs-mode-map
  "q" #'quit-window
  "g" #'docker-logs-restart
  "k" #'docker-logs-stop
  "G" #'end-of-buffer)

(define-derived-mode docker-logs-mode special-mode "Docker:Logs"
  "Mode for streaming Docker container logs.

\\{docker-logs-mode-map}"
  :group 'docker
  (setq-local truncate-lines nil)
  (add-hook 'kill-buffer-hook #'docker-logs--cleanup nil t))

(defun docker-logs--buffer-name (container)
  (format "*docker:logs:%s*" container))

(defun docker-logs--cleanup ()
  "Kill any associated log stream when the buffer dies."
  (when (process-live-p docker-logs--process)
    (delete-process docker-logs--process)))

(defun docker-logs--insert (buffer stream-type bytes)
  "Insert BYTES into BUFFER, colorized by STREAM-TYPE (`stdout'/`stderr')."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (at-end (= (point) (point-max)))
            (face (pcase stream-type
                    ('stderr 'docker-logs-stderr)
                    (_ 'docker-logs-stdout))))
        (save-excursion
          (goto-char (point-max))
          (insert (propertize bytes 'font-lock-face face)))
        (when at-end (goto-char (point-max)))))))

(defun docker-logs--tty-p (cfg container)
  "Return non-nil if CONTAINER's daemon-side TTY is enabled."
  (let ((detail (docker-inspect-container-json cfg container)))
    (eq t (alist-get 'Tty (alist-get 'Config detail)))))

(cl-defun docker-logs-start (cfg container &key tail follow timestamps)
  "Open a log buffer for CONTAINER and stream from the engine API.
TAIL, FOLLOW, TIMESTAMPS default to the matching `docker-logs-*' customs.
Returns the buffer."
  (let* ((tail (or tail docker-logs-default-tail))
         (follow (if (eq follow 'unset) docker-logs-follow follow))
         (timestamps (if (eq timestamps 'unset) docker-logs-timestamps timestamps))
         (buf (get-buffer-create (docker-logs--buffer-name container)))
         (tty-p (docker-logs--tty-p cfg container))
         (demux (unless tty-p
                  (docker-stream-make-demux
                   (lambda (typ payload)
                     (docker-logs--insert buf typ payload))))))
    (with-current-buffer buf
      (docker-logs-mode)
      (setq docker-logs--container container
            docker-logs--config cfg)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize
                 (format "GET /containers/%s/logs%s%s%s\n\n"
                         container
                         (if follow "?follow=1" "?follow=0")
                         (if timestamps "&timestamps=1" "")
                         (format "&tail=%s&stdout=1&stderr=1" tail))
                 'font-lock-face 'shadow)))
      (docker-logs--cleanup)
      (setq docker-logs--process
            (docker-http-stream
             cfg "GET" (format "/containers/%s/logs" container)
             :query `(("follow" . ,(if follow "1" "0"))
                      ("stdout" . "1")
                      ("stderr" . "1")
                      ("tail" . ,(format "%s" tail))
                      ,@(when timestamps '(("timestamps" . "1"))))
             :on-chunk
             (if demux
                 (lambda (bytes) (funcall demux bytes))
               (lambda (bytes) (docker-logs--insert buf 'stdout bytes))))))
    buf))

(defun docker-logs-restart ()
  "Restart the log stream in the current buffer."
  (interactive)
  (unless (and docker-logs--container docker-logs--config)
    (user-error "Not a docker logs buffer"))
  (docker-logs-start docker-logs--config docker-logs--container))

(defun docker-logs-stop ()
  "Stop the log stream without closing the buffer."
  (interactive)
  (docker-logs--cleanup)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (insert (propertize "\n[stream stopped]\n" 'font-lock-face 'shadow)))))

;;;###autoload
(cl-defun docker-logs (cfg container &key tail (follow 'unset) (timestamps 'unset))
  "Open a log buffer for CONTAINER and stream via the engine API."
  (let ((buf (docker-logs-start cfg container
                                :tail tail :follow follow :timestamps timestamps)))
    (pop-to-buffer buf)
    buf))

(provide 'docker-logs)
;;; docker-logs.el ends here
