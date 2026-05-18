;;; docker-config.el --- Docker environment configuration -*- lexical-binding: t -*-
;;
;; Detect Docker daemon connection parameters: socket path, host, TLS
;; settings.  Follows Docker CLI conventions (DOCKER_HOST, DOCKER_TLS,
;; etc.) and provides a structured config object.
;;
;; Usage:
;;   (setq cfg (docker-config-detect))
;;   (docker-config-socket-path cfg)  ; => "/var/run/docker.sock"

(require 'cl-lib)

;;; ---------------------------------------------------------------------------
;;; Data model

(cl-defstruct (docker-config (:constructor docker-config--new) (:copier nil))
  "Connection parameters for a Docker daemon."
  socket-path        ; string, Unix socket path
  host               ; string, TCP host (or nil for socket)
  port               ; integer, TCP port (or nil for socket)
  tls-verify         ; boolean, verify TLS certs
  tls-ca-cert        ; string, CA cert path or nil
  tls-cert           ; string, client cert path or nil
  tls-key            ; string, client key path or nil
  api-version)       ; string, API version or nil for latest

;;; ---------------------------------------------------------------------------
;;; Environment detection

(defun docker--detect-socket ()
  "Return the Docker Unix socket path from env or default."
  (or (getenv "DOCKER_HOST")
      (when (file-exists-p "/var/run/docker.sock")
        "/var/run/docker.sock")
      (when (file-exists-p (expand-file-name "~/.docker/docker.sock"))
        (expand-file-name "~/.docker/docker.sock"))))

(defun docker--detect-host ()
  "Return the Docker TCP host from DOCKER_HOST env var, or nil."
  (let ((dh (getenv "DOCKER_HOST")))
    (when (and dh (string-match "tcp://\\([^:]+\\).*" dh))
      (match-string 1 dh))))

(defun docker--detect-port ()
  "Return the Docker TCP port from DOCKER_HOST env var, or nil."
  (let ((dh (getenv "DOCKER_HOST")))
    (when (and dh (string-match "tcp://[^:]+:\\([0-9]+\\)" dh))
      (string-to-number (match-string 1 dh)))))

(defun docker--detect-tls-enable ()
  "Return t if TLS is enabled (DOCKER_TLS or --tlsverify)."
  (and (getenv "DOCKER_TLS") t))

(defun docker--detect-tls-ca-cert ()
  "Return TLS CA cert path from DOCKER_CERT_PATH or default."
  (let* ((path (or (getenv "DOCKER_CERT_PATH")
                   (expand-file-name "~/.docker")))
         (ca (expand-file-name "ca.pem" path)))
    (when (file-exists-p ca) ca)))

(defun docker--detect-tls-cert ()
  "Return TLS client cert path from DOCKER_CERT_PATH or default."
  (let* ((path (or (getenv "DOCKER_CERT_PATH")
                   (expand-file-name "~/.docker")))
         (cert (expand-file-name "cert.pem" path)))
    (when (file-exists-p cert) cert)))

(defun docker--detect-tls-key ()
  "Return TLS client key path from DOCKER_CERT_PATH or default."
  (let* ((path (or (getenv "DOCKER_CERT_PATH")
                   (expand-file-name "~/.docker")))
         (key (expand-file-name "key.pem" path)))
    (when (file-exists-p key) key)))

(defun docker--detect-api-version ()
  "Return API version from DOCKER_API_VERSION env var, or nil."
  (getenv "DOCKER_API_VERSION"))

;;; ---------------------------------------------------------------------------
;;; Public API

(defun docker-config-detect ()
  "Detect Docker daemon configuration from environment and defaults.
Returns a `docker-config' struct.
Priority: DOCKER_HOST env var, else Unix socket, else default socket."
  (let* ((socket-path (docker--detect-socket))
         (host (docker--detect-host))
         (port (docker--detect-port)))
    (docker-config--new
     :socket-path (if host nil socket-path)
     :host host
     :port port
     :tls-verify (docker--detect-tls-enable)
     :tls-ca-cert (docker--detect-tls-ca-cert)
     :tls-cert (docker--detect-tls-cert)
     :tls-key (docker--detect-tls-key)
     :api-version (docker--detect-api-version))))

(defun docker-config-dockerfile-p (filename)
  "Return t if FILENAME looks like a Dockerfile (Dockerfile or *.dockerfile)."
  (or (string= (downcase (file-name-base filename)) "dockerfile")
      (string-suffix-p ".dockerfile" filename t)))

(provide 'docker-config)
;;; docker-config.el ends here
