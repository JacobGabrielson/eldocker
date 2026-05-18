;;; docker-terminal.el --- Screen-oriented terminal backend selector -*- lexical-binding: t -*-
;;
;; Hosts a hijacked Docker exec stream in a screen-oriented terminal
;; emulator buffer.  Three backends:
;;
;;   eat     pure-Elisp xterm emulator (preferred when present)
;;   vterm   `emacs-libvterm', a compiled module (best fidelity)
;;   term    built-in `term-mode'   (always-available floor)
;;
;; Each backend implements the same four operations:
;;
;;   docker-terminal-open     BUFNAME              → BUFFER
;;   docker-terminal-feed     BUFFER BYTES         → renders output
;;   docker-terminal-bind     BUFFER NET-PROCESS   → routes keystrokes
;;   docker-terminal-resize   BUFFER HEIGHT WIDTH  → SIGWINCH-equivalent
;;
;; The caller (`docker-exec') doesn't know which backend resolved.
;; `docker-terminal-backend' picks one; the default `auto' probes
;; eat → vterm → term and uses the first that's available.

(require 'cl-lib)

(defgroup docker-terminal nil
  "Terminal emulator selection for eldocker."
  :group 'docker)

(defcustom docker-terminal-backend 'auto
  "Which screen-oriented terminal emulator to host TTY streams in.
`auto' probes `eat' → `vterm' → `term' and picks the first that's
available.  The other values force a specific backend."
  :type '(choice (const auto) (const eat) (const vterm) (const term))
  :group 'docker-terminal)

(defun docker-terminal--resolve ()
  "Return the actual backend symbol to use, after auto-probing."
  (pcase docker-terminal-backend
    ('auto (cond ((require 'eat nil t) 'eat)
                 ((require 'vterm nil t) 'vterm)
                 (t 'term)))
    ('eat   (require 'eat) 'eat)
    ('vterm (require 'vterm) 'vterm)
    ('term  'term)
    (other  (error "docker-terminal: unknown backend %S" other))))

(defvar-local docker-terminal--backend nil
  "Resolved backend symbol for the current terminal buffer.")

;;; ---------------------------------------------------------------------------
;;; term backend (built-in)

(defun docker-terminal--open-term (bufname)
  (let ((buf (get-buffer-create bufname)))
    (with-current-buffer buf
      (require 'term)
      (unless (derived-mode-p 'term-mode) (term-mode))
      (let ((inhibit-read-only t)) (erase-buffer))
      (setq docker-terminal--backend 'term))
    buf))

(defun docker-terminal--feed-term (buffer bytes)
  (let ((proc (get-buffer-process buffer)))
    (when (and proc bytes)
      (term-emulate-terminal proc bytes))))

(defun docker-terminal--bind-term (buffer proc)
  (with-current-buffer buffer
    (set-process-buffer proc buffer)
    (set-marker (process-mark proc) (point-max))
    (term-char-mode)))

(defun docker-terminal--resize-term (buffer h w)
  (with-current-buffer buffer
    (when (fboundp 'term-set-size)
      (ignore-errors (term-set-size h w)))))

;;; ---------------------------------------------------------------------------
;;; eat backend

(defun docker-terminal--open-eat (bufname)
  (require 'eat)
  (let ((buf (get-buffer-create bufname)))
    (with-current-buffer buf
      (unless (derived-mode-p 'eat-mode) (eat-mode))
      (let ((inhibit-read-only t)) (erase-buffer))
      (setq-local eat-terminal (eat-term-make buf (point)))
      ;; Use eat's standard input wiring; we just plug our network
      ;; process in via the `eat--process' parameter below.
      (eat-term-set-parameter eat-terminal 'input-function
                              #'docker-terminal--eat-send-input)
      (setq docker-terminal--backend 'eat))
    buf))

(defun docker-terminal--eat-send-input (_term str)
  "input-function handler for eat: forward STR to the bound process."
  (when-let* ((proc (eat-term-parameter eat-terminal 'eat--process)))
    (process-send-string proc str)))

(defun docker-terminal--feed-eat (buffer bytes)
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (eat-term-process-output eat-terminal bytes)
      (eat-term-redisplay eat-terminal))))

(defun docker-terminal--bind-eat (buffer proc)
  (with-current-buffer buffer
    (eat-term-set-parameter eat-terminal 'eat--process proc)
    ;; Also expose the proc via `get-buffer-process' for callers (and
    ;; for demos) that don't know about eat's parameter slot.
    (set-process-buffer proc buffer)
    (eat-semi-char-mode)))

(defun docker-terminal--resize-eat (buffer h w)
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (eat-term-resize eat-terminal (max w 1) (max h 1))
      (eat-term-redisplay eat-terminal))))

;;; ---------------------------------------------------------------------------
;;; vterm backend

(defun docker-terminal--open-vterm (bufname)
  (require 'vterm)
  (let ((buf (get-buffer-create bufname)))
    (with-current-buffer buf
      (unless (derived-mode-p 'vterm-mode) (vterm-mode))
      (setq docker-terminal--backend 'vterm))
    buf))

(defun docker-terminal--feed-vterm (buffer bytes)
  (with-current-buffer buffer
    (when (fboundp 'vterm--write-input)
      (vterm--write-input bytes))))

(defun docker-terminal--bind-vterm (buffer proc)
  (with-current-buffer buffer
    (setq-local vterm--process proc)))

(defun docker-terminal--resize-vterm (buffer h w)
  (with-current-buffer buffer
    (when (fboundp 'vterm--set-size)
      (ignore-errors (vterm--set-size h w)))))

;;; ---------------------------------------------------------------------------
;;; Public surface

(defun docker-terminal-open (bufname)
  "Open BUFNAME in the resolved terminal backend.  Return the buffer."
  (pcase (docker-terminal--resolve)
    ('eat   (docker-terminal--open-eat   bufname))
    ('vterm (docker-terminal--open-vterm bufname))
    (_      (docker-terminal--open-term  bufname))))

(defun docker-terminal-feed (buffer bytes)
  "Feed BYTES into BUFFER's terminal, rendering output."
  (when (and (buffer-live-p buffer) bytes (> (length bytes) 0))
    (pcase (buffer-local-value 'docker-terminal--backend buffer)
      ('eat   (docker-terminal--feed-eat   buffer bytes))
      ('vterm (docker-terminal--feed-vterm buffer bytes))
      (_      (docker-terminal--feed-term  buffer bytes)))))

(defun docker-terminal-bind (buffer process)
  "Route BUFFER's keystrokes to PROCESS, and finalize the input mode."
  (pcase (buffer-local-value 'docker-terminal--backend buffer)
    ('eat   (docker-terminal--bind-eat   buffer process))
    ('vterm (docker-terminal--bind-vterm buffer process))
    (_      (docker-terminal--bind-term  buffer process))))

(defun docker-terminal-resize (buffer height width)
  "Inform BUFFER's terminal of a new (HEIGHT, WIDTH).  Idempotent."
  (when (buffer-live-p buffer)
    (pcase (buffer-local-value 'docker-terminal--backend buffer)
      ('eat   (docker-terminal--resize-eat   buffer height width))
      ('vterm (docker-terminal--resize-vterm buffer height width))
      (_      (docker-terminal--resize-term  buffer height width)))))

(defun docker-terminal-window-size (buffer)
  "Return (HEIGHT . WIDTH) for the window showing BUFFER, or sane defaults."
  (let ((win (get-buffer-window buffer t)))
    (if win
        (cons (window-body-height win) (window-body-width win))
      (cons 24 80))))

(provide 'docker-terminal)
;;; docker-terminal.el ends here
