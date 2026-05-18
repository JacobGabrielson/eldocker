;;; demo-init.el --- Scripted demo of `e' in eldocker -*- lexical-binding: t -*-
;;
;; Drives a single asciinema-recordable scenario:
;;   1. open the containers view
;;   2. move point to eldocker-ticker
;;   3. press `e' to run /bin/sh inside it
;;   4. type a few commands into the embedded shell
;;   5. exit cleanly so asciinema's `rec --command' terminates
;;
;; Invoked by docs/record-demo.sh.  Not autoloaded; the file is
;; consumed only inside the recording subshell.

(setq package-load-list '(all))
(package-initialize)

;; Locate the repo root and pick up the docker/ subdir.
(let* ((this-dir (file-name-directory (or load-file-name buffer-file-name)))
       (repo-root (file-name-directory (directory-file-name this-dir))))
  (add-to-list 'load-path (expand-file-name "docker" repo-root)))
(require 'docker)

;; Minimal cosmetic setup so the recording is uncluttered.
(setq inhibit-startup-screen t
      ring-bell-function 'ignore
      use-dialog-box nil
      docker-terminal-backend 'auto)
(when (fboundp 'menu-bar-mode) (menu-bar-mode -1))
(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
(when (fboundp 'blink-cursor-mode) (blink-cursor-mode -1))

(defun demo--type (proc str)
  "Send STR to PROC one character at a time, mimicking human typing."
  (dolist (ch (string-to-list str))
    (process-send-string proc (char-to-string ch))
    (sit-for 0.04)))

(defun demo--run ()
  "The whole scripted demo."
  (docker)                              ; *docker:containers*
  (sit-for 1.5)
  (with-current-buffer "*docker:containers*"
    (goto-char (point-min))
    (when (re-search-forward "eldocker-ticker" nil t)
      (beginning-of-line)
      (forward-char 2))
    (sit-for 1.0)
    ;; The `e' key: do it as a real keypress so the recording shows
    ;; the binding firing.
    (execute-kbd-macro (kbd "e"))
    ;; docker-exec-at-point's interactive form prompts for the command.
    ;; Accept the "/bin/sh" default.
    (sit-for 0.4)
    (execute-kbd-macro (kbd "RET")))
  (let ((deadline (+ (float-time) 5.0))
        (buf nil))
    (while (and (< (float-time) deadline)
                (not (setq buf (get-buffer
                                "*docker:exec:eldocker-ticker*"))))
      (sit-for 0.1))
    (when buf
      (pop-to-buffer buf)
      (sit-for 1.5)
      (let ((proc (get-buffer-process buf)))
        (when proc
          (demo--type proc "whoami\n")        (sit-for 0.6)
          (demo--type proc "hostname\n")      (sit-for 0.6)
          (demo--type proc "uname -a\n")      (sit-for 0.8)
          (demo--type proc "echo hello from eldocker\n")
          (sit-for 2.0)                       ; final state visible
          (demo--type proc "exit\n")))
      (sit-for 1.5)))
  (kill-emacs 0))

(run-at-time 0.3 nil #'demo--run)

;;; demo-init.el ends here
