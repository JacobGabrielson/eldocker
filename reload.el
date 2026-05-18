;;; reload.el --- Dev helper: byte-compile + reload all modules -*- lexical-binding: t -*-
;;
;; Eval-buffer this file (or `M-x eltainer-reload') to rebuild and
;; re-`load' every module in dependency order across both halves of
;; the merged repo (docker/ and k8s/).  Also re-enters the major mode
;; in any live buffer whose mode starts with `docker-' or `k8s-' so
;; freshly-bound keys land in already-open windows.

(require 'cl-lib)
(require 'bytecomp)

(defconst eltainer--source-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this `reload.el' file (captured at load time).")

(defconst eltainer-docker-modules
  '("docker-config"
    "docker-http"
    "docker-stream"
    "docker-api"
    "docker-ps"
    "docker-images"
    "docker-networks"
    "docker-events"
    "docker-logs"
    "docker-terminal"
    "docker-exec"
    "docker-auth"
    "docker-pull"
    "docker")
  "Docker-side modules in load order (dependencies first).")

(defconst eltainer-k8s-modules
  '("k8s-config"
    "k8s-api"
    "k8s-watch"
    "k8s-fs"
    "k8s-fs-ui"
    "k8s-pods"
    "k8s-exec"
    "k8s")
  "K8s-side modules in load order (dependencies first).")

(defun eltainer-reload ()
  "Byte-compile and reload every eltainer module.
Refreshes both `docker/' and `k8s/' subtrees, then re-enters the
major mode in any live `docker-*-mode' / `k8s-*-mode' buffer."
  (interactive)
  (let* ((docker-dir (expand-file-name "docker" eltainer--source-dir))
         (k8s-dir (expand-file-name "k8s" eltainer--source-dir))
         (load-path (append (list docker-dir k8s-dir) load-path))
         (errors nil))
    (cl-loop for (subdir . mods) in `((,docker-dir . ,eltainer-docker-modules)
                                      (,k8s-dir   . ,eltainer-k8s-modules))
             do
             (dolist (mod mods)
               (let ((src (expand-file-name (concat mod ".el") subdir)))
                 (when (file-exists-p src)
                   (unless (byte-compile-file src)
                     (push mod errors))
                   (setq features (delq (intern mod) features))
                   (load (file-name-sans-extension src) nil 'nomessage)))))
    ;; Top-level loader.
    (let ((eltainer (expand-file-name "eltainer.el" eltainer--source-dir)))
      (when (file-exists-p eltainer)
        (byte-compile-file eltainer)
        (setq features (delq 'eltainer features))
        (load (file-name-sans-extension eltainer) nil 'nomessage)))
    ;; Refresh live buffers.
    (let ((rebound 0))
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (when (and (symbolp major-mode)
                     (or (string-prefix-p "docker-" (symbol-name major-mode))
                         (string-prefix-p "k8s-" (symbol-name major-mode)))
                     (string-suffix-p "-mode" (symbol-name major-mode))
                     (fboundp major-mode))
            (funcall major-mode)
            (cl-incf rebound))))
      (message "eltainer-reload: refreshed %d buffer%s%s"
               rebound (if (= rebound 1) "" "s")
               (if errors
                   (format ", %d compile failure(s): %s"
                           (length errors) (mapconcat #'identity errors ", "))
                 "")))))

;; Backwards-compatible alias from the old name.
(defalias 'eldocker-reload #'eltainer-reload)

(provide 'reload)
;;; reload.el ends here
