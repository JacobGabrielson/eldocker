;;; docker-events.el --- Subscribe to /events for view auto-refresh -*- lexical-binding: t -*-
;;
;; Open a single long-lived `GET /events' stream and run a small
;; publish/subscribe layer on top.  View buffers subscribe with a
;; matcher predicate and a refresh callback; matching events trigger
;; a debounced refresh so a burst of activity (e.g. `docker compose
;; up') doesn't repaint the buffer 30 times in 200ms.

(require 'cl-lib)
(require 'docker-api)
(require 'docker-http)
(require 'docker-stream)

(defcustom docker-events-debounce-seconds 0.25
  "Minimum seconds between subscriber refreshes for the same buffer."
  :type 'number
  :group 'docker)

;; (BUFFER MATCH-FN REFRESH-FN LAST-FIRED-TIME TIMER)
(defvar docker-events--subscribers nil
  "List of subscribers; entries are mutated in place.")

(defvar docker-events--process nil
  "Active /events stream process, or nil.")

(defvar docker-events--config nil
  "Config used to start the active /events stream.")

(defun docker-events--running-p ()
  (and docker-events--process (process-live-p docker-events--process)))

(defun docker-events--prune-dead-subscribers ()
  (setq docker-events--subscribers
        (cl-remove-if-not
         (lambda (s) (buffer-live-p (car s)))
         docker-events--subscribers)))

(defun docker-events--dispatch (event)
  "Route EVENT (a decoded alist) to every matching subscriber."
  (docker-events--prune-dead-subscribers)
  (dolist (s docker-events--subscribers)
    (let ((buf (nth 0 s))
          (match (nth 1 s))
          (refresh (nth 2 s)))
      (when (and (buffer-live-p buf) (funcall match event))
        (docker-events--schedule s refresh)))))

(defun docker-events--schedule (sub refresh)
  "Debounced fire of REFRESH against SUB's buffer."
  (let ((buf (nth 0 sub))
        (last (nth 3 sub))
        (timer (nth 4 sub))
        (now (float-time)))
    (when (timerp timer) (cancel-timer timer))
    (if (or (null last) (> (- now last) docker-events-debounce-seconds))
        (progn
          (setf (nth 3 sub) now)
          (when (buffer-live-p buf)
            (with-current-buffer buf (funcall refresh))))
      (let ((delay (max 0.05
                        (- docker-events-debounce-seconds (- now last)))))
        (setf (nth 4 sub)
              (run-at-time delay nil
                           (lambda ()
                             (when (buffer-live-p buf)
                               (setf (nth 3 sub) (float-time))
                               (with-current-buffer buf (funcall refresh))))))))))

(defun docker-events--ensure-stream (cfg)
  "Make sure a /events stream is running against CFG."
  (when (and docker-events--process
             (not (process-live-p docker-events--process)))
    (setq docker-events--process nil))
  (unless docker-events--process
    (setq docker-events--config cfg)
    (let ((ndjson
           (docker-stream-make-ndjson #'docker-events--dispatch)))
      (setq docker-events--process
            (docker-http-stream
             cfg "GET" "/events"
             :on-chunk (lambda (bytes) (funcall ndjson bytes))
             :on-close (lambda () (setq docker-events--process nil)))))))

(defun docker-events-subscribe (buffer match-fn refresh-fn)
  "Register BUFFER to refresh via REFRESH-FN when MATCH-FN matches an event.
MATCH-FN takes the parsed event alist and returns non-nil to fire."
  (push (list buffer match-fn refresh-fn nil nil) docker-events--subscribers))

(defun docker-events-unsubscribe (buffer)
  "Drop any subscriptions for BUFFER."
  (setq docker-events--subscribers
        (cl-remove-if (lambda (s) (eq (car s) buffer))
                      docker-events--subscribers)))

(defun docker-events-start (cfg)
  "Ensure the /events stream is running against CFG.  Safe to call repeatedly."
  (docker-events--ensure-stream cfg))

(defun docker-events-stop ()
  "Tear down the active /events stream and forget all subscribers."
  (interactive)
  (when (process-live-p docker-events--process)
    (delete-process docker-events--process))
  (setq docker-events--process nil
        docker-events--subscribers nil))

;;; ---------------------------------------------------------------------------
;;; Convenience: common matchers

(defun docker-events-match-types (&rest types)
  "Return a matcher that fires when the event's Type is in TYPES.
Use like (docker-events-subscribe BUF (docker-events-match-types \"container\" \"network\") REFRESH)."
  (lambda (event)
    (member (alist-get 'Type event) types)))

(provide 'docker-events)
;;; docker-events.el ends here
