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
       "Pods grouped by namespace; l streams logs, w toggles watch.")
      ("d" "Deployments"   k8s-deployments
       "Workload deployments with ready/available replica counts.")
      ("s" "Services"      k8s-services
       "Services with cluster-IP, type, and port mappings.")
      ("S" "StatefulSets"  k8s-statefulsets
       "Stateful workloads with ordered replicas + volume claims.")
      ("D" "DaemonSets"    k8s-daemonsets
       "Per-node DaemonSets and their rollout state.")
      ("j" "Jobs"          k8s-jobs
       "One-shot Jobs and their completion status.")
      ("J" "CronJobs"      k8s-cronjobs
       "Scheduled CronJobs and their last/next run times.")
      ("i" "Ingresses"     k8s-ingresses
       "Ingresses with their hosts, paths, and backends.")
      ("m" "ConfigMaps"    k8s-configmaps
       "ConfigMaps; expand to peek at key/value pairs.")
      ("x" "Secrets"       k8s-secrets
       "Secrets (metadata only — values stay redacted)."))))
  "Dashboard entries.  Alist of (BACKEND-LABEL . ((KEY LABEL COMMAND [BLURB]) …)).")

(defvar-keymap eltainer-mode-map
  :parent magit-section-mode-map
  "q" #'quit-window
  "g" #'eltainer-refresh
  "?" #'describe-mode
  "b" #'eltainer-switch-kubeconfig
  "RET" #'eltainer-dwim-ret)

;;; ---------------------------------------------------------------------------
;;; Kubeconfig switching (magit-branch-style `b')

(defcustom eltainer-kubeconfig-extra-paths nil
  "Additional kubeconfig paths to offer alongside the auto-discovered ones.
Each entry is an absolute file path."
  :type '(repeat file)
  :group 'eltainer)

(defcustom eltainer-kubeconfig-search-dirs
  '("~/.kube" "~/.kube/configs")
  "Directories scanned for kubeconfig files.
Files matching `config' or `config-*' in any of these are offered as
switch targets in the dashboard."
  :type '(repeat directory)
  :group 'eltainer)

(defun eltainer--discover-kubeconfigs ()
  "Return the de-duplicated list of kubeconfig paths to offer.
Sources, in order: `$KUBECONFIG' (colon-separated), files in
`eltainer-kubeconfig-search-dirs', and `eltainer-kubeconfig-extra-paths'.
Only existing readable files are included."
  (let* ((env (getenv "KUBECONFIG"))
         (env-paths (and env (split-string env ":" t)))
         (dir-paths
          (cl-loop for dir in eltainer-kubeconfig-search-dirs
                   for expanded = (expand-file-name dir)
                   when (file-directory-p expanded)
                   append (directory-files expanded t
                                           "\\`config\\(?:-.*\\)?\\'" t)))
         (all (append env-paths dir-paths eltainer-kubeconfig-extra-paths))
         seen out)
    (dolist (p all)
      (let ((full (and p (expand-file-name p))))
        (when (and full
                   (file-readable-p full)
                   (not (file-directory-p full))
                   (not (member full seen)))
          (push full seen)
          (push full out))))
    (nreverse out)))

(defun eltainer--current-kubeconfig ()
  "Return the path eltainer is currently pointed at for k8s, or nil."
  (or (bound-and-true-p k8s-kubeconfig-path)
      (let ((env (getenv "KUBECONFIG")))
        (and env (car (split-string env ":" t))))
      (let ((default (expand-file-name "~/.kube/config")))
        (and (file-readable-p default) default))))

(defun eltainer--kubeconfig-context (path)
  "Return the `current-context' string from PATH, or nil on any failure."
  (when (and path (file-readable-p path))
    (condition-case nil
        (k8s-config-current-context (k8s-config-load path))
      (error nil))))

(defun eltainer--kill-k8s-buffers ()
  "Kill every live `*k8s:…*' buffer so a kubeconfig switch is clean."
  (let ((kill-buffer-query-functions nil))
    (dolist (buf (buffer-list))
      (when (string-prefix-p "*k8s:" (buffer-name buf))
        (ignore-errors (kill-buffer buf))))))

(defun eltainer-switch-kubeconfig ()
  "Switch the active k8s kubeconfig and refresh the dashboard.
Like magit's branch switch (`b'), but for clusters.  Closes any open
`*k8s:…*' buffers so they re-open against the new config."
  (interactive)
  (let* ((current (eltainer--current-kubeconfig))
         (candidates (eltainer--discover-kubeconfigs))
         (annotated
          (mapcar (lambda (p)
                    (let ((ctx (eltainer--kubeconfig-context p)))
                      (cons (format "%s%s%s"
                                    (abbreviate-file-name p)
                                    (if ctx (format "  (%s)" ctx) "")
                                    (if (equal p current) "  *current*" ""))
                            p)))
                  candidates))
         (choice (completing-read "Switch kubeconfig: " annotated nil t))
         (target (cdr (assoc choice annotated))))
    (unless target (user-error "No kubeconfig selected"))
    (setq k8s-kubeconfig-path target)
    (eltainer--kill-k8s-buffers)
    (when (get-buffer "*eltainer*")
      (with-current-buffer "*eltainer*" (eltainer-refresh)))
    (message "eltainer: switched to %s" (abbreviate-file-name target))))

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

(defun eltainer--insert-active-kubeconfig ()
  "Render a `Kubeconfig: PATH (context)' line with a hint about `b'."
  (let* ((path (eltainer--current-kubeconfig))
         (ctx (and path (eltainer--kubeconfig-context path))))
    (insert (propertize "Kubeconfig:  " 'font-lock-face 'eltainer-dim))
    (if path
        (progn
          (insert (propertize (abbreviate-file-name path)
                              'font-lock-face 'eltainer-resource-name))
          (when ctx
            (insert (propertize (format " (%s)" ctx)
                                'font-lock-face 'eltainer-resource-secondary))))
      (insert (propertize "(none — set k8s-kubeconfig-path or $KUBECONFIG)"
                          'font-lock-face 'eltainer-dim)))
    (insert (propertize "    [b] switch\n\n"
                        'font-lock-face 'eltainer-dim))))

(defun eltainer-refresh ()
  "(Re)render the dashboard buffer."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (magit-insert-section (eltainer-root)
      (insert (propertize "eltainer" 'font-lock-face 'eltainer-section-heading)
              " — unified container porcelain\n\n")
      (eltainer--insert-active-kubeconfig)
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
