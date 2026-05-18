;;; docker-ps.el --- Container listing and lifecycle -*- lexical-binding: t -*-
;;
;; List, start, stop, restart, and remove Docker containers.
;; Uses the Docker CLI via docker-api.el.
;;
;; Usage:
;;   (docker-list-containers cfg)
;;   (docker-list-containers cfg :all t)
;;   (docker-start-container cfg "my-container")

(require 'cl-lib)
(require 'docker-api)

;;; ---------------------------------------------------------------------------
;;; Data model

(cl-defstruct (docker-container (:constructor docker-container--new) (:copier nil))
  "A Docker container summary."
  id                ; string, short container ID
  image             ; string, image name
  command           ; string, entrypoint command
  created           ; string, creation timestamp
  ports             ; string, port mapping summary
  status            ; string, status line (e.g. "Up 2 hours")
  state             ; string, state (running, exited, etc.)
  name              ; string, container name
  size)             ; string, size or nil

(cl-defstruct (docker-container-detail (:constructor docker-container-detail--new) (:copier nil))
  "Detailed Docker container info (from docker inspect)."
  id                ; string, full ID
  name              ; string, container name
  image             ; string, image ID
  state             ; alist, container state details
  config            ; alist, container config
  network-settings  ; alist, network settings
  mount-settings)   ; vector, mount settings

;;; ---------------------------------------------------------------------------
;;; Container listing

(cl-defun docker-list-containers (cfg &key all)
  "List containers via the engine API (GET /containers/json).
Returns a vector of `docker-container' structs (empty vector when none).
When ALL is non-nil, include stopped containers."
  (let ((data (docker-engine-get cfg "/containers/json"
                                 :query (when all '(("all" . "1"))))))
    (vconcat
     (mapcar (lambda (j)
               (docker-container--new
                :id (alist-get 'Id j)
                :image (alist-get 'Image j)
                :command (alist-get 'Command j)
                :created (docker--epoch-to-iso (alist-get 'Created j))
                :ports (docker--format-ports (alist-get 'Ports j))
                :status (alist-get 'Status j)
                :state (alist-get 'State j)
                :name (docker--strip-leading-slash
                       (car (alist-get 'Names j)))
                :size nil))
             data))))

;;; ---------------------------------------------------------------------------
;;; Container lifecycle

(defun docker-start-container (cfg name)
  "Start container NAME via POST /containers/NAME/start."
  (condition-case _err
      (progn (docker-engine-post cfg (format "/containers/%s/start" name)) t)
    (docker-api-error nil)))

(defun docker-stop-container (cfg name)
  "Stop container NAME via POST /containers/NAME/stop."
  (condition-case _err
      (progn (docker-engine-post cfg (format "/containers/%s/stop" name)) t)
    (docker-api-error nil)))

(defun docker-restart-container (cfg name)
  "Restart container NAME via POST /containers/NAME/restart."
  (condition-case _err
      (progn (docker-engine-post cfg (format "/containers/%s/restart" name)) t)
    (docker-api-error nil)))

(defun docker-kill-container (cfg name)
  "Send SIGKILL to container NAME via POST /containers/NAME/kill."
  (condition-case _err
      (progn (docker-engine-post cfg (format "/containers/%s/kill" name)) t)
    (docker-api-error nil)))

(defun docker-remove-container (cfg name &optional force)
  "Remove container NAME via DELETE /containers/NAME.  FORCE adds force=1."
  (condition-case _err
      (progn (docker-engine-delete cfg (format "/containers/%s" name)
                                   :query (when force '(("force" . "1"))))
             t)
    (docker-api-error nil)))

;;; ---------------------------------------------------------------------------
;;; Container states

(defun docker-container-running-p (container)
  "Return t if CONTAINER is running."
  (string= (docker-container-state container) "running"))

;;; ---------------------------------------------------------------------------
;;; Inspect helpers

(defun docker-inspect-container (cfg name)
  "Inspect container NAME via GET /containers/NAME/json.
Returns a `docker-container-detail' struct, or nil on lookup failure."
  (let ((data (condition-case nil
                  (docker-engine-get cfg (format "/containers/%s/json" name))
                (docker-api-error nil))))
    (when data
      (docker-container-detail--new
       :id (alist-get 'Id data)
       :name (docker--strip-leading-slash (alist-get 'Name data))
       :image (alist-get 'Image data)
       :state (alist-get 'State data)
       :config (alist-get 'Config data)
       :network-settings (alist-get 'NetworkSettings data)
       :mount-settings (alist-get 'Mounts data)))))

(defun docker-inspect-container-json (cfg name)
  "Return the raw `/containers/NAME/json' alist (for the inspect view)."
  (condition-case nil
      (docker-engine-get cfg (format "/containers/%s/json" name))
    (docker-api-error nil)))

(provide 'docker-ps)
;;; docker-ps.el ends here
