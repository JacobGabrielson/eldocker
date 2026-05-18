;;; eltainer.el --- Unified container porcelain for Emacs -*- lexical-binding: t -*-
;;
;; One Emacs interface for both Docker daemons and Kubernetes clusters.
;; Adds `docker/' and `k8s/' to the load-path and requires both halves
;; so `M-x docker', `M-x k8s', and `M-x eltainer' are all available
;; after a single `(require 'eltainer)'.
;;
;; Phase A — the two halves still live in their own files and use
;; their own transports; only the entry point is unified.  Phase B
;; lifts the shared HTTP transport up.

(require 'cl-lib)

(defconst eltainer--source-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this `eltainer.el' file.")

(add-to-list 'load-path (expand-file-name "docker" eltainer--source-dir))
(add-to-list 'load-path (expand-file-name "k8s"    eltainer--source-dir))

(require 'docker)
(require 'k8s)

(defcustom eltainer-default-backend nil
  "Backend to default to when invoking `M-x eltainer' without a prefix arg.
nil prompts each time; symbols `docker' or `k8s' skip the prompt."
  :type '(choice (const :tag "Prompt every time" nil)
                 (const docker)
                 (const k8s))
  :group 'docker)

(defun eltainer--choose-backend ()
  "Resolve which backend to invoke for `M-x eltainer'."
  (or (and (not current-prefix-arg) eltainer-default-backend)
      (intern (completing-read "eltainer backend: "
                               '("docker" "k8s") nil t))))

;;;###autoload
(defun eltainer ()
  "Open the eltainer view for the chosen backend (`docker' or `k8s').
With no `eltainer-default-backend' set, prompts.  A prefix arg forces
the prompt even if a default is configured."
  (interactive)
  (pcase (eltainer--choose-backend)
    ('docker (call-interactively #'docker))
    ('k8s    (call-interactively #'k8s))
    (other   (user-error "eltainer: unknown backend %S" other))))

(provide 'eltainer)
;;; eltainer.el ends here
