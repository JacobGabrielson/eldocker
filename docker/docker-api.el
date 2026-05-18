;;; docker-api.el --- Engine API helpers -*- lexical-binding: t -*-
;;
;; Thin wrappers over `docker-http' that handle:
;;   - version-pinning the path (one /version probe, cached)
;;   - JSON serialization on POST bodies
;;   - JSON deserialization on responses
;;   - mapping daemon error bodies to a typed `docker-api-error'
;;
;; Public API:
;;   (docker-engine-get    CFG PATH &key query)
;;   (docker-engine-post   CFG PATH &key query body json accept-statuses)
;;   (docker-engine-delete CFG PATH &key query accept-statuses)
;;
;; Plus a few helpers used by the from-JSON struct constructors in
;; docker-ps / docker-images / docker-networks:
;;   (docker--epoch-to-iso EPOCH)
;;   (docker--format-ports PORTS)
;;   (docker--strip-leading-slash STRING)

(require 'cl-lib)
(require 'docker-config)
(require 'docker-http)

;;; ---------------------------------------------------------------------------
;;; Error condition

(define-error 'docker-api-error "Docker API error")

;;; ---------------------------------------------------------------------------
;;; Version pinning

(defvar docker--engine-api-version nil
  "Cached `/vX.Y' path prefix.  First call queries /version and stores it.")

(defun docker-engine-reset-version-cache ()
  "Forget the cached engine API version (call after switching daemons)."
  (interactive)
  (setq docker--engine-api-version nil))

(defun docker--api-prefix (cfg)
  "Return the API version prefix for CFG (e.g. \"/v1.45\"), cached.
Falls back to the empty string if /version is unreachable; modern
daemons accept unversioned paths just fine."
  (or docker--engine-api-version
      (setq docker--engine-api-version
            (let ((resp (ignore-errors
                          (docker-http-request cfg "GET" "/version"))))
              (or (and resp
                       (docker-http-ok-p resp)
                       (let ((v (alist-get 'ApiVersion
                                           (docker-http-json resp))))
                         (and v (concat "/v" v))))
                  "")))))

;;; ---------------------------------------------------------------------------
;;; Engine helpers

(defun docker--engine-error (resp path)
  "Signal a `docker-api-error' built from RESP at PATH."
  (let* ((code (docker-http-response-status resp))
         (body (docker-http-response-body resp))
         (msg (or (ignore-errors
                    (alist-get 'message (docker-http-json resp)))
                  body)))
    (signal 'docker-api-error
            (list :status code :path path :message msg))))

(cl-defun docker-engine-get (cfg path &key query)
  "GET PATH from the engine API.  Returns decoded JSON or signals."
  (let* ((full (concat (docker--api-prefix cfg) path))
         (resp (docker-http-request cfg "GET" full :query query)))
    (if (docker-http-ok-p resp)
        (docker-http-json resp)
      (docker--engine-error resp full))))

(cl-defun docker-engine-post (cfg path &key query body json
                                       (accept-statuses '(200 201 204 304)))
  "POST PATH on the engine API.
BODY is a raw string; JSON is an alist/list that gets `json-serialize'd.
Returns parsed JSON (or nil for empty 204 bodies) or signals on error."
  (let* ((full (concat (docker--api-prefix cfg) path))
         (headers (when json '(("Content-Type" . "application/json"))))
         (body* (cond (json (json-serialize json
                                            :null-object nil
                                            :false-object :false))
                      (body body)))
         (resp (docker-http-request cfg "POST" full
                                    :query query :headers headers :body body*)))
    (if (memq (docker-http-response-status resp) accept-statuses)
        (and (> (length (docker-http-response-body resp)) 0)
             (ignore-errors (docker-http-json resp)))
      (docker--engine-error resp full))))

(cl-defun docker-engine-delete (cfg path &key query
                                          (accept-statuses '(200 204)))
  "DELETE PATH on the engine API.  Returns nil on success or signals."
  (let* ((full (concat (docker--api-prefix cfg) path))
         (resp (docker-http-request cfg "DELETE" full :query query)))
    (unless (memq (docker-http-response-status resp) accept-statuses)
      (docker--engine-error resp full))
    nil))

;;; ---------------------------------------------------------------------------
;;; Shared helpers used by from-JSON struct constructors

(defun docker--epoch-to-iso (epoch)
  "Convert EPOCH (integer Unix seconds) to an ISO-8601 timestamp string."
  (when (numberp epoch)
    (format-time-string "%FT%TZ" (seconds-to-time epoch) t)))

(defun docker--format-ports (ports)
  "Format daemon-style PORTS (list of port alists) into a CLI-ish string."
  (when (and ports (listp ports))
    (mapconcat
     (lambda (p)
       (let ((ip (alist-get 'IP p))
             (pub (alist-get 'PublicPort p))
             (priv (alist-get 'PrivatePort p))
             (typ (or (alist-get 'Type p) "tcp")))
         (cond
          ((and ip pub) (format "%s:%s->%s/%s" ip pub priv typ))
          (priv (format "%s/%s" priv typ))
          (t ""))))
     ports ", ")))

(defun docker--strip-leading-slash (s)
  "Drop a leading `/` from S (the daemon prefixes container Names with /)."
  (if (and (stringp s) (string-prefix-p "/" s)) (substring s 1) s))

(provide 'docker-api)
;;; docker-api.el ends here
