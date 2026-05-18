;;; k8s-fs-ui.el --- Dired-style browser for pod filesystems -*- lexical-binding: t -*-
;;
;; Read-only filesystem browser over `k8s-fs'.  Entry point is
;; `k8s-pod-browse', usually invoked with `b' from the pods view.
;;
;; Inside the browser buffer:
;;   RET   visit entry at point (directory: cd; file: cat; symlink: resolve)
;;   ^     go to parent directory
;;   g     refresh current listing
;;   i     pop full metadata for the entry at point
;;   n/p   next/previous entry
;;   q     quit-window
;;
;; Multi-container pods prompt for a container via `completing-read';
;; the choice is remembered per (namespace, pod) for the session.
;; Files larger than `k8s-fs-max-cat-bytes' (5MB default) prompt for
;; confirmation before reading.

(require 'cl-lib)
(require 'k8s-fs)

;;; ---------------------------------------------------------------------------
;;; Buffer-local state

(defvar-local k8s-fs--conn nil)
(defvar-local k8s-fs--ns nil)
(defvar-local k8s-fs--pod nil)
(defvar-local k8s-fs--container nil)        ; may be nil for single-container pods
(defvar-local k8s-fs--path nil)              ; absolute path in the pod
(defvar-local k8s-fs--entries nil)           ; list of `k8s-fs-entry'

;;; ---------------------------------------------------------------------------
;;; Container selection (memoized per pod)

(defvar k8s-fs--container-memo (make-hash-table :test 'equal)
  "Map (NS . POD) cons to the last-chosen container name for the session.")

(defun k8s-fs--pick-container (ns pod containers)
  "Choose a container in NS/POD from CONTAINERS (list of strings).
Returns nil for single-container pods; prompts otherwise, remembering
the choice across calls for this session."
  (cond
   ((<= (length containers) 1) nil)
   (t
    (let* ((key (cons ns pod))
           (last (gethash key k8s-fs--container-memo))
           (default (or last (car containers)))
           (choice (completing-read
                    (format "Container in %s/%s: " ns pod)
                    containers nil t nil nil default)))
      (puthash key choice k8s-fs--container-memo)
      choice))))

;;; ---------------------------------------------------------------------------
;;; Rendering

(defun k8s-fs--type-char (type)
  (cl-case type
    (file ?-)  (directory ?d)  (symlink ?l)
    (socket ?s)  (fifo ?p)  (block ?b)  (char ?c)
    (t ??)))

(defun k8s-fs--format-time (epoch)
  "Format EPOCH (unix seconds) as a compact local-time string."
  (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time epoch)))

(defun k8s-fs--insert-header ()
  (let ((inhibit-read-only t))
    (insert (propertize
             (format "Pod:  %s/%s%s\n"
                     k8s-fs--ns k8s-fs--pod
                     (if k8s-fs--container
                         (format " [%s]" k8s-fs--container)
                       ""))
             'face 'mode-line))
    (insert (propertize (format "Path: %s\n\n" k8s-fs--path)
                        'face 'mode-line))))

(defun k8s-fs--insert-entry (entry)
  "Insert one ENTRY line, attaching it as a text property for hit-testing."
  (let* ((type (k8s-fs-entry-type entry))
         (line (format "%c%s  %s/%s  %8d  %s  %s%s\n"
                       (k8s-fs--type-char type)
                       (k8s-fs-entry-mode-string entry)
                       (k8s-fs-entry-owner entry)
                       (k8s-fs-entry-group entry)
                       (k8s-fs-entry-size entry)
                       (k8s-fs--format-time (k8s-fs-entry-mtime entry))
                       (k8s-fs-entry-name entry)
                       (if (k8s-fs-entry-link-target entry)
                           (format " -> %s" (k8s-fs-entry-link-target entry))
                         ""))))
    (insert (propertize line 'k8s-fs-entry entry
                        'face (cl-case type
                                (directory 'dired-directory)
                                (symlink 'dired-symlink)
                                (t nil))))))

(defun k8s-fs--render ()
  "Render the current buffer from `k8s-fs--entries' and state."
  (let ((inhibit-read-only t)
        (saved-point (point)))
    (erase-buffer)
    (k8s-fs--insert-header)
    (dolist (e (sort (copy-sequence k8s-fs--entries)
                     (lambda (a b)
                       (let ((da (eq (k8s-fs-entry-type a) 'directory))
                             (db (eq (k8s-fs-entry-type b) 'directory)))
                         (cond
                          ((and da (not db)) t)
                          ((and (not da) db) nil)
                          (t (string< (k8s-fs-entry-name a)
                                      (k8s-fs-entry-name b))))))))
      (k8s-fs--insert-entry e))
    (goto-char (min saved-point (point-max)))
    (unless (get-text-property (point) 'k8s-fs-entry)
      (k8s-fs--goto-first-entry))))

(defun k8s-fs--goto-first-entry ()
  "Move point to the first entry line in the buffer."
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (not (eobp)))
      (if (get-text-property (point) 'k8s-fs-entry)
          (setq found t)
        (forward-line 1)))))

(defun k8s-fs--entry-at-point ()
  "Return the `k8s-fs-entry' on the current line, or nil."
  (get-text-property (line-beginning-position) 'k8s-fs-entry))

;;; ---------------------------------------------------------------------------
;;; Navigation

(defun k8s-fs--load (path)
  "List PATH in the pod and re-render the buffer."
  (message "k8s-fs: listing %s ..." path)
  (let ((entries (k8s-fs-list k8s-fs--conn k8s-fs--ns k8s-fs--pod
                              k8s-fs--container path)))
    (setq k8s-fs--path path
          k8s-fs--entries entries)
    (rename-buffer (k8s-fs--buffer-name k8s-fs--ns k8s-fs--pod
                                        k8s-fs--container path)
                   t)
    (k8s-fs--render)
    (message "k8s-fs: %s (%d entries)" path (length entries))))

(defun k8s-fs--resolve-symlink-target (entry)
  "Expand ENTRY's link-target against the current directory.
Returns nil if ENTRY is not a symlink."
  (let ((tgt (k8s-fs-entry-link-target entry)))
    (when tgt
      (if (string-prefix-p "/" tgt)
          tgt
        (expand-file-name tgt k8s-fs--path)))))

(defun k8s-fs--view-file (path size)
  "Open a read-only buffer with the contents of PATH (a file in the pod)."
  (when (> size k8s-fs-max-cat-bytes)
    (unless (yes-or-no-p
             (format "%s is %d bytes (cap %d). Open anyway? "
                     path size k8s-fs-max-cat-bytes))
      (user-error "Aborted")))
  (let* ((bytes (k8s-fs-cat k8s-fs--conn k8s-fs--ns k8s-fs--pod
                            k8s-fs--container path
                            (max size k8s-fs-max-cat-bytes)))
         (buf (get-buffer-create
               (format "*k8s:fs-file:%s/%s%s:%s*"
                       k8s-fs--ns k8s-fs--pod
                       (if k8s-fs--container
                           (format "[%s]" k8s-fs--container) "")
                       path))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (set-buffer-multibyte nil)
        (insert bytes)
        (set-buffer-multibyte t)
        (decode-coding-region (point-min) (point-max) 'utf-8))
      (goto-char (point-min))
      ;; Best-effort major mode from extension
      (let ((mode (assoc-default path auto-mode-alist 'string-match)))
        (when (and mode (symbolp mode) (fboundp mode))
          (funcall mode)))
      (setq buffer-read-only t)
      (setq-local header-line-format
                  (format " %s/%s%s:%s — read-only (q quits)"
                          k8s-fs--ns k8s-fs--pod
                          (if k8s-fs--container
                              (format "[%s]" k8s-fs--container) "")
                          path))
      (local-set-key "q" #'quit-window))
    (pop-to-buffer buf)))

(defun k8s-fs-visit ()
  "Visit the entry at point.
Directories are entered; regular files are cat'd into a read-only
buffer; symlinks are resolved one level and then visited."
  (interactive)
  (let ((entry (k8s-fs--entry-at-point)))
    (unless entry
      (user-error "No entry on this line"))
    (k8s-fs--visit-entry entry)))

(defun k8s-fs--visit-entry (entry)
  "Visit ENTRY based on its type."
  (let ((type (k8s-fs-entry-type entry))
        (name (k8s-fs-entry-name entry)))
    (cl-case type
      (directory
       (k8s-fs--load (expand-file-name name k8s-fs--path)))
      (file
       (k8s-fs--view-file (expand-file-name name k8s-fs--path)
                          (k8s-fs-entry-size entry)))
      (symlink
       (let ((target (k8s-fs--resolve-symlink-target entry)))
         (unless target
           (user-error "Symlink has no resolvable target"))
         (condition-case err
             (let ((tgt-entry (k8s-fs-stat k8s-fs--conn k8s-fs--ns
                                           k8s-fs--pod k8s-fs--container
                                           target)))
               (cl-case (k8s-fs-entry-type tgt-entry)
                 (directory (k8s-fs--load target))
                 (file (k8s-fs--view-file target (k8s-fs-entry-size tgt-entry)))
                 (t (message "Symlink target %s is a %s" target
                             (k8s-fs-entry-type tgt-entry)))))
           (error (message "Symlink target %s not reachable: %s"
                           target (error-message-string err))))))
      (t
       (user-error "Cannot visit %s of type %s" name type)))))

(defun k8s-fs-parent ()
  "Go to the parent directory."
  (interactive)
  (let ((parent (directory-file-name
                 (or (file-name-directory k8s-fs--path) "/"))))
    (when (string= parent "")
      (setq parent "/"))
    (if (string= parent k8s-fs--path)
        (message "Already at root")
      (k8s-fs--load parent))))

(defun k8s-fs-refresh ()
  "Reload the current directory."
  (interactive)
  (k8s-fs--load k8s-fs--path))

(defun k8s-fs-info ()
  "Pop a buffer with full metadata for the entry at point."
  (interactive)
  (let ((entry (k8s-fs--entry-at-point)))
    (unless entry (user-error "No entry on this line"))
    (with-help-window "*k8s:fs-info*"
      (princ (format "Name:    %s\n" (k8s-fs-entry-name entry)))
      (princ (format "Type:    %s\n" (k8s-fs-entry-type entry)))
      (princ (format "Mode:    %s\n" (k8s-fs-entry-mode-string entry)))
      (princ (format "Owner:   %s\n" (k8s-fs-entry-owner entry)))
      (princ (format "Group:   %s\n" (k8s-fs-entry-group entry)))
      (princ (format "Size:    %d bytes\n" (k8s-fs-entry-size entry)))
      (princ (format "NLinks:  %d\n" (k8s-fs-entry-nlink entry)))
      (princ (format "Mtime:   %s (epoch %d)\n"
                     (k8s-fs--format-time (k8s-fs-entry-mtime entry))
                     (k8s-fs-entry-mtime entry)))
      (when (k8s-fs-entry-link-target entry)
        (princ (format "Target:  %s\n" (k8s-fs-entry-link-target entry)))))))

;;; ---------------------------------------------------------------------------
;;; Major mode

(defvar-keymap k8s-fs-mode-map
  :parent special-mode-map
  "RET" #'k8s-fs-visit
  "^"   #'k8s-fs-parent
  "g"   #'k8s-fs-refresh
  "i"   #'k8s-fs-info
  "n"   #'next-line
  "p"   #'previous-line)

(define-derived-mode k8s-fs-mode special-mode "K8s:FS"
  "Read-only browser for a Kubernetes pod's filesystem.

\\{k8s-fs-mode-map}"
  :interactive nil
  :group 'k8s
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function
              (lambda (_ignore _noconfirm) (k8s-fs-refresh))))

;;; ---------------------------------------------------------------------------
;;; Entry point

(defun k8s-fs--buffer-name (ns pod container path)
  (format "*k8s:fs:%s/%s%s:%s*"
          ns pod
          (if container (format "[%s]" container) "")
          path))

;;;###autoload
(defun k8s-pod-browse (conn ns pod container &optional path)
  "Open a filesystem browser for POD in NS via CONN.
CONTAINER may be nil for single-container pods.  PATH defaults to \"/\"."
  (let* ((path (or path "/"))
         (buf (get-buffer-create (k8s-fs--buffer-name ns pod container path))))
    (with-current-buffer buf
      (k8s-fs-mode)
      (setq k8s-fs--conn conn
            k8s-fs--ns ns
            k8s-fs--pod pod
            k8s-fs--container container)
      (k8s-fs--load path))
    (pop-to-buffer buf)))

(provide 'k8s-fs-ui)
;;; k8s-fs-ui.el ends here
