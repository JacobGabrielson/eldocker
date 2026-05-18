;;; eltainer.el --- Unified container porcelain for Emacs -*- lexical-binding: t -*-
;;
;; Adds `docker/' and `k8s/' to the load-path and requires both halves
;; so `M-x docker', `M-x k8s', and `M-x eltainer' are all available
;; after a single `(require 'eltainer)'.
;;
;; `M-x eltainer' opens a magit-section dashboard listing every
;; available view in both backends.  Press the key beside an entry —
;; or `RET' / mouse-1 on the row — to jump in.

(require 'cl-lib)
(require 'magit-section)
(require 'eltainer-ui)

(defconst eltainer--source-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this `eltainer.el' file.")

(add-to-list 'load-path (expand-file-name "docker" eltainer--source-dir))
(add-to-list 'load-path (expand-file-name "k8s"    eltainer--source-dir))

(require 'eltainer-terminal)
(require 'eltainer-shell-helper)
(require 'docker)
(require 'k8s)

;;; ---------------------------------------------------------------------------
;;; Dashboard

(defvar eltainer-views
  '(("Docker" .
     (("c" "Containers" docker-containers
       "Running containers (a toggles all).")
      ("I" "Images"     docker-images
       "Image inventory; p in `?' pulls a new one.")
      ("N" "Networks"   docker-networks
       "Networks + connected containers.")
      ("p" "Pull"       docker-pull-image
       "Pull an image by reference, with live progress.")))
    ("Kubernetes" .
     (("k" "Pods"          k8s-pods
       "Pods view grouped by namespace.")
      ("d" "Deployments"   k8s-deployments)
      ("s" "Services"      k8s-services)
      ("S" "StatefulSets"  k8s-statefulsets)
      ("D" "DaemonSets"    k8s-daemonsets)
      ("j" "Jobs"          k8s-jobs)
      ("J" "CronJobs"      k8s-cronjobs)
      ("i" "Ingresses"     k8s-ingresses)
      ("m" "ConfigMaps"    k8s-configmaps)
      ("x" "Secrets"       k8s-secrets))))
  "Dashboard entries.  Alist of (BACKEND-LABEL . ((KEY LABEL COMMAND [BLURB]) …)).")

(defvar-keymap eltainer-mode-map
  :parent magit-section-mode-map
  "q" #'quit-window
  "g" #'eltainer-refresh
  "?" #'describe-mode
  "RET" #'eltainer-dwim-ret)

(define-derived-mode eltainer-mode magit-section-mode "Eltainer"
  "Dashboard for the unified docker + k8s frontend."
  :group 'eltainer
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm) (eltainer-refresh))))

(defun eltainer--bind-launchers ()
  "Wire each entry's KEY to its COMMAND in the current buffer."
  (dolist (group eltainer-views)
    (dolist (entry (cdr group))
      (let ((key (nth 0 entry))
            (cmd (nth 2 entry)))
        (keymap-set eltainer-mode-map key cmd)))))

(defun eltainer--insert-entry (entry)
  "Insert one dashboard row for ENTRY."
  (let* ((key   (nth 0 entry))
         (label (nth 1 entry))
         (cmd   (nth 2 entry))
         (blurb (nth 3 entry))
         (start (point))
         (avail (fboundp cmd)))
    (magit-insert-section (eltainer-entry cmd t)
      (insert "  "
              (propertize (format "%-3s" key)
                          'font-lock-face (if avail
                                              'eltainer-resource-name
                                            'eltainer-dim))
              (propertize (format "%-15s" label)
                          'font-lock-face (if avail
                                              'default
                                            'eltainer-dim))
              (propertize (or blurb (symbol-name cmd))
                          'font-lock-face 'eltainer-dim))
      (insert "\n")
      (add-text-properties start (point) `(eltainer-cmd ,cmd))
      (unless avail
        (add-text-properties start (point)
                             '(help-echo "command unavailable (module not loaded)"))))))

(defun eltainer-refresh ()
  "(Re)render the dashboard buffer."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (eltainer-root)
      (insert (propertize "eltainer" 'font-lock-face 'eltainer-section-heading)
              " — unified container porcelain\n\n")
      (insert (propertize "Press the key beside an entry, or RET on a row.\n"
                          'font-lock-face 'eltainer-dim))
      (insert (propertize "g refreshes, q quits.\n\n"
                          'font-lock-face 'eltainer-dim))
      (dolist (group eltainer-views)
        (magit-insert-section (eltainer-group (car group))
          (magit-insert-heading
            (propertize (car group) 'font-lock-face 'eltainer-section-heading))
          (dolist (entry (cdr group))
            (eltainer--insert-entry entry))
          (insert "\n")))
      (insert "\n"))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

(defun eltainer-dwim-ret ()
  "On a dashboard row, run its command.  On a section heading, toggle it."
  (interactive)
  (let ((cmd (get-text-property (point) 'eltainer-cmd)))
    (cond
     ((and cmd (fboundp cmd)) (call-interactively cmd))
     ((magit-current-section) (call-interactively #'magit-section-toggle))
     (t (user-error "Nothing actionable at point")))))

;;;###autoload
(defun eltainer ()
  "Open the eltainer dashboard listing every available view."
  (interactive)
  (let ((buf (get-buffer-create "*eltainer*")))
    (with-current-buffer buf
      (eltainer-mode)
      (eltainer--bind-launchers)
      (eltainer-refresh))
    (pop-to-buffer buf)))

(provide 'eltainer)
;;; eltainer.el ends here
