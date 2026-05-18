;;; docker.el --- Docker porcelain for Emacs -*- lexical-binding: t -*-
;;
;; Main entry point for eldocker.  Provides shared infrastructure
;; (connection, faces, helpers) and magit-section-based views for
;; containers and images.
;;
;; Usage:
;;   M-x docker

(require 'cl-lib)
(require 'magit-section)
(require 'transient)
(require 'docker-config)
(require 'docker-api)
(require 'docker-ps)
(require 'docker-images)
(require 'docker-logs)
(require 'docker-networks)
(require 'docker-events)
(require 'docker-exec)
(require 'docker-pull)

;;; ---------------------------------------------------------------------------
;;; Customization

(defgroup docker nil
  "Docker porcelain for Emacs."
  :prefix "docker-"
  :group 'tools)

(defcustom docker-config-override nil
  "Override the auto-detected Docker config.
Set this to a `docker-config' struct to bypass environment detection."
  :type '(choice (const nil) (const docker-config))
  :group 'docker)

;;; ---------------------------------------------------------------------------
;;; Internal state

(defvar-local docker--config nil
  "The `docker-config' for the current buffer.")

(defvar-local docker--header-end nil
  "Buffer position where the scrollable content begins (after header).")

;;; ---------------------------------------------------------------------------
;;; Faces

(defface docker-section-heading
  '((t :inherit magit-section-heading))
  "Face for section headings."
  :group 'docker)

(defface docker-container-name
  '((t :inherit magit-branch-local))
  "Face for container names."
  :group 'docker)

(defface docker-image-name
  '((t :inherit magit-tag))
  "Face for image names."
  :group 'docker)

(defface docker-network-name
  '((t :inherit magit-branch-remote))
  "Face for network names."
  :group 'docker)

(defface docker-status-running
  '((t :inherit success))
  "Face for Running status."
  :group 'docker)

(defface docker-status-exited
  '((t :inherit error))
  "Face for Exited status."
  :group 'docker)

(defface docker-status-other
  '((t :inherit warning))
  "Face for other statuses."
  :group 'docker)

(defface docker-dim
  '((t :inherit shadow))
  "Face for secondary information."
  :group 'docker)

;;; ---------------------------------------------------------------------------
;;; Connection helpers

(defun docker--detect-config ()
  "Return the Docker config to use."
  (or docker-config-override
      (docker-config-detect)))

(defun docker--ensure-config ()
  "Return the current buffer's config, detecting one if needed."
  (or docker--config
      (setq docker--config (docker--detect-config))))

;;; ---------------------------------------------------------------------------
;;; Shared helpers

(defun docker--age-string (timestamp)
  "Convert ISO TIMESTAMP to a human-readable age string."
  (if (null timestamp)
      "?"
    (let* ((then (float-time (date-to-time timestamp)))
           (now (float-time))
           (secs (- now then)))
      (cond
       ((< secs 60)       (format "%ds" (truncate secs)))
       ((< secs 3600)     (format "%dm" (truncate (/ secs 60))))
       ((< secs 86400)    (format "%dh" (truncate (/ secs 3600))))
       (t                 (format "%dd" (truncate (/ secs 86400))))))))

(defun docker--status-face (state)
  "Return the face for STATE string."
  (pcase state
    ("running"  'docker-status-running)
    ("up"       'docker-status-running)
    ("exited"   'docker-status-exited)
    ("dead"     'docker-status-exited)
    (_          'docker-status-other)))

(defun docker--truncate (str width)
  "Truncate STR to WIDTH characters, appending ellipsis if needed."
  (if (> (length str) width)
      (concat (substring str 0 (- width 3)) "...")
    str))

;;; ---------------------------------------------------------------------------
;;; Keymaps

(defvar-keymap docker-common-map
  "g" #'revert-buffer
  "q" #'quit-window
  "d" #'docker-delete-at-point
  "i" #'docker-inspect-at-point
  "l" #'docker-logs-at-point
  "?" #'docker-dispatch
  "RET" #'docker-dwim-ret)

;;; ---------------------------------------------------------------------------
;;; Header insertion

(defun docker--insert-header (view-name)
  "Insert the header with config info and current VIEW-NAME."
  (let* ((cfg (docker--ensure-config))
         (socket (docker-config-socket-path cfg))
         (host (docker-config-host cfg))
         (port (docker-config-port cfg)))
    (insert (propertize "Docker:    " 'font-lock-face 'docker-dim)
            view-name
            "\n")
    (insert (propertize "Endpoint:  " 'font-lock-face 'docker-dim)
            (cond
             (host (format "tcp://%s:%d" host (or port 2375)))
             (socket (format "unix://%s" socket))
             (t "unknown"))
            "\n\n")))

;;; ---------------------------------------------------------------------------
;;; Generic refresh engine

(defun docker--generic-refresh (view-name items column-header line-fn)
  "Refresh buffer showing VIEW-NAME.
ITEMS is a vector of structs.  COLUMN-HEADER is a string rendered
above the rows (nil to omit).  LINE-FN inserts one item as a
section."
  (let* ((inhibit-read-only t))
    (erase-buffer)
    (setq header-line-format nil)
    (magit-insert-section (docker-root)
      (docker--insert-header view-name)
      (when column-header
        (insert (propertize column-header 'font-lock-face 'docker-section-heading)))
      (dolist (item (append items nil))
        (funcall line-fn item))
      (insert "\n"))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (goto-char (point-min))))

;;; ---------------------------------------------------------------------------
;;; Container view

(defun docker--container-insert-line (container)
  "Insert a single container summary line as a section."
  (let* ((name (docker-container-name container))
         (image (docker-container-image container))
         (state (or (docker-container-state container) "?"))
         (status (or (docker-container-status container) ""))
         (ports (or (docker-container-ports container) ""))
         (created (docker-container-created container))
         (age (docker--age-string created)))
    (magit-insert-section (container container t)
      (magit-insert-heading
        (format "  %-30s %-10s %-10s %-12s %-6s\n"
                (propertize name 'font-lock-face 'docker-container-name)
                (propertize state 'font-lock-face (docker--status-face state))
                (docker--truncate image 25)
                (propertize ports 'font-lock-face 'docker-dim)
                (propertize age 'font-lock-face 'docker-dim)))
      ;; Collapsible detail body
      (insert (propertize (format "    Status:  %s\n" status)
                          'font-lock-face 'docker-dim))
      (insert (propertize (format "    Image:   %s\n" image)
                          'font-lock-face 'docker-dim))
      (insert (propertize (format "    Command: %s\n"
                                  (or (docker-container-command container) ""))
                          'font-lock-face 'docker-dim))
      (insert "\n"))))

(defvar-local docker-containers--show-all nil
  "When non-nil, the containers view includes stopped containers.")

(defun docker--containers-refresh ()
  "Refresh the containers buffer using the buffer-local `--show-all' flag."
  (let* ((cfg (docker--ensure-config))
         (items (docker-list-containers cfg :all docker-containers--show-all))
         (hdr (format "  %-30s %-10s %-10s %-12s %-6s\n"
                      "NAME" "STATE" "IMAGE" "PORTS" "AGE"))
         (label (if docker-containers--show-all
                    "Containers (all)" "Containers (running)")))
    (docker--generic-refresh label items hdr #'docker--container-insert-line)))

(defun docker-containers-toggle-all ()
  "Toggle between running-only and all-containers in the current view."
  (interactive)
  (unless (derived-mode-p 'docker-containers-mode)
    (user-error "Not in a docker-containers buffer"))
  (setq docker-containers--show-all (not docker-containers--show-all))
  (docker--containers-refresh))

;;; ---------------------------------------------------------------------------
;;; Image view

(defun docker--image-insert-line (image)
  "Insert a single image summary line as a section."
  (let* ((repo (or (docker-image-repository image) "<none>"))
         (tag (or (docker-image-tag image) "<none>"))
         (id (docker-image-id image))
         (created (docker-image-created image))
         (age (docker--age-string created))
         (size (or (docker-image-size image) "?")))
    (magit-insert-section (image image t)
      (magit-insert-heading
        (format "  %-35s %-20s %-12s %-6s\n"
                (propertize repo 'font-lock-face 'docker-image-name)
                (propertize tag 'font-lock-face 'docker-dim)
                (propertize size 'font-lock-face 'docker-dim)
                (propertize age 'font-lock-face 'docker-dim)))
      ;; Collapsible detail body
      (insert (propertize (format "    ID:   %s\n" id)
                          'font-lock-face 'docker-dim))
      (insert "\n"))))

;;; ---------------------------------------------------------------------------
;;; View definitions

(defvar-keymap docker-containers-mode-map
  :parent magit-section-mode-map
  "a" #'docker-containers-toggle-all
  "s" #'docker-start-at-point
  "S" #'docker-stop-at-point
  "r" #'docker-restart-at-point
  "K" #'docker-kill-at-point)
(map-keymap (lambda (key def)
              (keymap-set docker-containers-mode-map
                          (key-description (vector key)) def))
            docker-common-map)

(define-derived-mode docker-containers-mode magit-section-mode "Docker:Containers"
  "Major mode for viewing Docker containers.

\\{docker-containers-mode-map}"
  :interactive nil
  :group 'docker
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm) (docker--containers-refresh)))
  (add-hook 'kill-buffer-hook #'docker--cleanup nil t))

;;;###autoload
(defun docker-containers ()
  "Display Docker containers (running by default; `a' toggles to show all)."
  (interactive)
  (let ((buf (get-buffer-create "*docker:containers*")))
    (with-current-buffer buf
      (docker-containers-mode)
      (let ((cfg (docker--ensure-config)))
        (docker--containers-refresh)
        (docker--subscribe-events
         cfg
         (docker-events-match-types "container" "network")
         #'docker--containers-refresh)))
    (pop-to-buffer buf)))

(defun docker--images-refresh ()
  "Refresh the images buffer."
  (let* ((cfg (docker--ensure-config))
         (images (docker-list-images cfg))
         (hdr (format "  %-35s %-20s %-12s %-6s\n"
                      "REPOSITORY" "TAG" "SIZE" "AGE")))
    (docker--generic-refresh "Images" images hdr #'docker--image-insert-line)))

(defvar-keymap docker-images-mode-map
  :parent magit-section-mode-map)
(map-keymap (lambda (key def)
              (keymap-set docker-images-mode-map
                          (key-description (vector key)) def))
            docker-common-map)

(define-derived-mode docker-images-mode magit-section-mode "Docker:Images"
  "Major mode for viewing Docker images.

\\{docker-images-mode-map}"
  :interactive nil
  :group 'docker
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm) (docker--images-refresh)))
  (add-hook 'kill-buffer-hook #'docker--cleanup nil t))

;;;###autoload
(defun docker-images ()
  "Display all Docker images."
  (interactive)
  (let ((buf (get-buffer-create "*docker:images*")))
    (with-current-buffer buf
      (docker-images-mode)
      (let ((cfg (docker--ensure-config)))
        (docker--images-refresh)
        (docker--subscribe-events
         cfg (docker-events-match-types "image") #'docker--images-refresh)))
    (pop-to-buffer buf)))

;;; ---------------------------------------------------------------------------
;;; Networks view

(defun docker--network-insert-line (net detail)
  "Insert a network summary section for NET, expanding members from DETAIL."
  (let* ((name (docker-network-name net))
         (driver (docker-network-driver net))
         (scope (docker-network-scope net))
         (subnet (and detail (docker-network-detail-subnet detail)))
         (members (and detail (docker-network-detail-members detail))))
    (magit-insert-section (network net t)
      (magit-insert-heading
        (format "  %-20s %-10s %-8s %-22s %s\n"
                (propertize name 'font-lock-face 'docker-network-name)
                (propertize driver 'font-lock-face 'docker-dim)
                (propertize scope 'font-lock-face 'docker-dim)
                (propertize (or subnet "-") 'font-lock-face 'docker-dim)
                (propertize (format "(%d)" (length members))
                            'font-lock-face 'docker-dim)))
      (dolist (m members)
        (magit-insert-section (network-member m)
          (insert (format "    %-30s  %s\n"
                          (propertize (or (docker-network-member-container-name m) "?")
                                      'font-lock-face 'docker-container-name)
                          (propertize (or (docker-network-member-ipv4 m) "")
                                      'font-lock-face 'docker-dim)))))
      (insert "\n"))))

(defun docker--networks-refresh ()
  "Refresh the networks buffer."
  (let* ((cfg (docker--ensure-config))
         (networks (docker-list-networks cfg))
         (names (mapcar #'docker-network-name (append networks nil)))
         (details (docker-inspect-networks cfg names))
         (by-name (let ((h (make-hash-table :test 'equal)))
                    (dolist (d details)
                      (puthash (docker-network-detail-name d) d h))
                    h))
         (hdr (format "  %-20s %-10s %-8s %-22s %s\n"
                      "NAME" "DRIVER" "SCOPE" "SUBNET" "MEMBERS")))
    (docker--generic-refresh "Networks" networks hdr
                             (lambda (net)
                               (docker--network-insert-line
                                net (gethash (docker-network-name net) by-name))))))

(defvar-keymap docker-networks-mode-map
  :parent magit-section-mode-map)
(map-keymap (lambda (key def)
              (keymap-set docker-networks-mode-map
                          (key-description (vector key)) def))
            docker-common-map)

(define-derived-mode docker-networks-mode magit-section-mode "Docker:Networks"
  "Major mode for viewing Docker networks.

\\{docker-networks-mode-map}"
  :interactive nil
  :group 'docker
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm) (docker--networks-refresh)))
  (add-hook 'kill-buffer-hook #'docker--cleanup nil t))

;;;###autoload
(defun docker-networks ()
  "Display all Docker networks with their connected containers."
  (interactive)
  (let ((buf (get-buffer-create "*docker:networks*")))
    (with-current-buffer buf
      (docker-networks-mode)
      (let ((cfg (docker--ensure-config)))
        (docker--networks-refresh)
        (docker--subscribe-events
         cfg (docker-events-match-types "network" "container")
         #'docker--networks-refresh)))
    (pop-to-buffer buf)))

;;; ---------------------------------------------------------------------------
;;; Network connect/disconnect (from a container at point)

(defun docker--read-network (cfg prompt &optional default-names)
  "Prompt for a network name.  DEFAULT-NAMES restricts the completion set."
  (let ((names (or default-names
                   (mapcar #'docker-network-name
                           (append (docker-list-networks cfg) nil)))))
    (completing-read prompt names nil t)))

(defun docker--container-networks (cfg name)
  "Return the list of network names CONTAINER is currently a member of."
  (let* ((detail (docker-inspect-container cfg name))
         (nets (cdr (assq 'Networks
                          (docker-container-detail-network-settings detail)))))
    (mapcar (lambda (e) (symbol-name (car e))) nets)))

(defun docker-network-connect-at-point ()
  "Connect the container at point to a network (prompts for the network)."
  (interactive)
  (let* ((c (docker--container-at-point))
         (cname (docker-container-name c))
         (cfg (docker--ensure-config))
         (net (docker--read-network cfg (format "Connect %s to network: " cname))))
    (if (docker-network-connect cfg net cname)
        (progn (message "eldocker: connected %s to %s" cname net)
               (revert-buffer))
      (message "eldocker: connect failed (%s → %s)" cname net))))

(defun docker-network-disconnect-at-point ()
  "Disconnect the container at point from one of its networks."
  (interactive)
  (let* ((c (docker--container-at-point))
         (cname (docker-container-name c))
         (cfg (docker--ensure-config))
         (current (docker--container-networks cfg cname))
         (_ (unless current (user-error "%s is not on any network" cname)))
         (net (docker--read-network cfg
                                    (format "Disconnect %s from network: " cname)
                                    current)))
    (if (docker-network-disconnect cfg net cname)
        (progn (message "eldocker: disconnected %s from %s" cname net)
               (revert-buffer))
      (message "eldocker: disconnect failed (%s → %s)" cname net))))

;; Bind in the containers view (j = join, J = jettison).
(keymap-set docker-containers-mode-map "j" #'docker-network-connect-at-point)
(keymap-set docker-containers-mode-map "J" #'docker-network-disconnect-at-point)
(keymap-set docker-containers-mode-map "e" #'docker-exec-at-point)

;;; ---------------------------------------------------------------------------
;;; Transient dispatch

(transient-define-prefix docker-dispatch ()
  "Main eldocker command menu."
  ["Views"
   ("c" "Containers" docker-containers)
   ("I" "Images"     docker-images)
   ("N" "Networks"   docker-networks)]
  ["Images"
   ("p" "Pull image" docker-pull-image)]
  ["Containers view"
   ("a" "Toggle running/all" docker-containers-toggle-all)]
  ["Container at point"
   ("s" "Start"        docker-start-at-point)
   ("S" "Stop"         docker-stop-at-point)
   ("r" "Restart"      docker-restart-at-point)
   ("K" "Kill"         docker-kill-at-point)
   ("l" "Logs"         docker-logs-at-point)
   ("e" "Exec"         docker-exec-at-point)
   ("i" "Inspect"      docker-inspect-at-point)
   ("d" "Remove"       docker-delete-at-point)
   ("j" "Join network" docker-network-connect-at-point)
   ("J" "Leave network" docker-network-disconnect-at-point)]
  ["Buffer"
   ("g" "Refresh" revert-buffer)
   ("q" "Quit"    quit-window)])

;;;###autoload
(defun docker ()
  "Main entry point for eldocker.  Shows running containers by default."
  (interactive)
  (docker-containers))

;;; ---------------------------------------------------------------------------
;;; Inspect resource

(defun docker-inspect-at-point ()
  "Inspect the Docker object at point."
  (interactive)
  (let ((section (magit-current-section)))
    (unless section
      (user-error "Not on a resource"))
    (let* ((value (oref section value))
           (cfg (docker--ensure-config))
           (name (cond
                  ((docker-container-p value)
                   (docker-container-name value))
                  ((docker-image-p value)
                   (docker-image-repository value))
                  ((docker-network-p value)
                   (docker-network-name value))
                  ((docker-network-member-p value)
                   (docker-network-member-container-name value))
                  (t (user-error "Unknown resource type"))))
           (buf (get-buffer-create (format "*docker:inspect:%s*" name)))
           (json (cond
                  ((docker-container-p value)
                   (docker-inspect-container-json cfg name))
                  ((docker-image-p value)
                   (docker-inspect-image cfg name))
                  ((docker-network-p value)
                   (docker-inspect-network-json cfg name))
                  ((docker-network-member-p value)
                   (docker-inspect-container-json cfg name)))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize (format "Inspect: %s\n" name)
                              'font-lock-face 'docker-container-name)
                  "\n")
          (if json
              (docker--describe-value json 0)
            (insert "Inspect returned nil\n")))
        (goto-char (point-min))
        (special-mode)
        (local-set-key "q" #'quit-window)
        (local-set-key "g" #'docker-inspect-at-point))
      (pop-to-buffer buf))))

(defun docker--describe-value (value indent)
  "Recursively format VALUE as readable text at INDENT level."
  (cond
   ((null value) (insert "nil\n"))
   ((stringp value) (insert value "\n"))
   ((numberp value) (insert (format "%s\n" value)))
   ((eq value t) (insert "true\n"))
   ((vectorp value)
    (insert "\n")
    (seq-doseq (item (append value nil))
      (insert (make-string indent ?\s) "- ")
      (docker--describe-value item (+ indent 2))))
   ((and (listp value) (consp (car value)))
    ;; alist
    (insert "\n")
    (dolist (pair value)
      (let ((key (format "%s" (car pair))))
        (insert (make-string indent ?\s)
                (propertize (concat key ": ") 'font-lock-face 'docker-section-heading))
        (docker--describe-value (cdr pair) (+ indent 2)))))
   (t (insert (format "%S\n" value)))))

;;; ---------------------------------------------------------------------------
;;; Delete resource

(defun docker-delete-at-point ()
  "Delete (or disconnect) the Docker object at point after confirmation.
Context-aware: containers/images/networks remove; a network-member row
disconnects the member from its network."
  (interactive)
  (let ((section (magit-current-section)))
    (unless section
      (user-error "Not on a resource"))
    (let* ((value (oref section value))
           (cfg (docker--ensure-config)))
      (cond
       ((docker-container-p value)
        (let ((name (docker-container-name value)))
          (when (yes-or-no-p (format "Remove container %s? " name))
            (docker-remove-container cfg name)
            (message "eldocker: removed container %s" name)
            (revert-buffer))))
       ((docker-image-p value)
        (let ((name (docker-image-repository value)))
          (when (yes-or-no-p (format "Remove image %s? " name))
            (docker-remove-image cfg name)
            (message "eldocker: removed image %s" name)
            (revert-buffer))))
       ((docker-network-p value)
        (let ((name (docker-network-name value)))
          (when (yes-or-no-p (format "Remove network %s? " name))
            (if (docker-remove-network cfg name)
                (progn (message "eldocker: removed network %s" name)
                       (revert-buffer))
              (message "eldocker: removing %s failed (containers still attached?)"
                       name)))))
       ((docker-network-member-p value)
        (let ((net (docker-network-member-network-name value))
              (cname (docker-network-member-container-name value)))
          (when (yes-or-no-p (format "Disconnect %s from %s? " cname net))
            (if (docker-network-disconnect cfg net cname)
                (progn (message "eldocker: disconnected %s from %s" cname net)
                       (revert-buffer))
              (message "eldocker: disconnect failed")))))
       (t (user-error "Unknown resource type"))))))

;;; ---------------------------------------------------------------------------
;;; Container action helpers

(defun docker--container-at-point ()
  "Return the `docker-container' struct at point, or signal `user-error'."
  (let ((section (magit-current-section)))
    (unless section (user-error "Not on a resource"))
    (let ((value (oref section value)))
      (unless (docker-container-p value)
        (user-error "Not on a container"))
      value)))

(defmacro docker--define-container-action (verb api-fn ok-message)
  "Define an interactive lifecycle command for the container at point.
VERB is the lowercase action word; the generated function is named
`docker-VERB-at-point'.  API-FN is the docker-ps function
`(cfg name) → success-p'.  OK-MESSAGE is the format string with one
%s slot for the container name."
  (let ((fn-name (intern (format "docker-%s-at-point" verb))))
    `(defun ,fn-name ()
       ,(format "%s the container at point." (capitalize verb))
       (interactive)
       (let* ((c (docker--container-at-point))
              (name (docker-container-name c))
              (cfg (docker--ensure-config)))
         (if (,api-fn cfg name)
             (progn (message ,ok-message name) (revert-buffer))
           (message "eldocker: %s failed for %s" ,verb name))))))

(docker--define-container-action "stop"    docker-stop-container    "eldocker: stopped %s")
(docker--define-container-action "start"   docker-start-container   "eldocker: started %s")
(docker--define-container-action "restart" docker-restart-container "eldocker: restarted %s")
(docker--define-container-action "kill"    docker-kill-container    "eldocker: killed %s")

;;; ---------------------------------------------------------------------------
;;; Logs

(defun docker-logs-at-point ()
  "Open the log buffer for the container at point."
  (interactive)
  (docker-logs (docker--ensure-config)
               (docker-container-name (docker--container-at-point))))

;;; ---------------------------------------------------------------------------
;;; Smart RET

(defun docker-dwim-ret ()
  "Smart RET: toggle section collapse/expand."
  (interactive)
  (call-interactively #'magit-section-toggle))

;;; ---------------------------------------------------------------------------
;;; Cleanup

(defun docker--cleanup ()
  "Cleanup hook: release resources when a docker buffer is killed."
  (docker-events-unsubscribe (current-buffer)))

(defun docker--subscribe-events (cfg match-fn refresh-fn)
  "Hook the current buffer up to /events for auto-refresh on matching events."
  (docker-events-start cfg)
  (docker-events-subscribe (current-buffer) match-fn refresh-fn))

(provide 'docker)
;;; docker.el ends here
