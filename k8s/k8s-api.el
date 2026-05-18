;;; k8s-api.el --- Pure Elisp Kubernetes API client -*- lexical-binding: t -*-
;;
;; Talks to the Kubernetes API server over HTTPS via the shared
;; `docker-http' transport (Phase B of the merge).  Kubeconfig parsing
;; and resource helpers are k8s-specific; the wire is the same as the
;; Docker engine path.
;;
;; Usage:
;;   (setq conn (k8s-connection-open "/path/to/kubeconfig"))
;;   (k8s-get conn "/api/v1/namespaces")

(require 'cl-lib)
(require 'docker-config)
(require 'docker-http)
(require 'eltainer-shell-helper)
(require 'k8s-config)

;;; ---------------------------------------------------------------------------
;;; Connection struct

(cl-defstruct (k8s-connection (:constructor k8s-connection--new) (:copier nil))
  "Connection parameters for a Kubernetes API server."
  config            ; k8s-config
  cluster           ; k8s-cluster
  user              ; k8s-user
  server            ; string "https://host:port"
  host              ; string
  port              ; integer
  ca-file            ; temp file path for the CA cert, or nil
  client-cert-file   ; temp file path for client cert PEM, or nil
  client-key-file    ; temp file path for client key PEM, or nil
  docker-cfg)        ; a `docker-config' built from the above, used as
                     ; the transport handle for docker-http-request

(defvar k8s-tls-priority "NORMAL:-VERS-TLS1.3"
  "GnuTLS priority string used for K8s API connections.
TLS 1.3 is disabled because Emacs's GnuTLS does not reliably present
client certificates during a 1.3 handshake — the server then sees the
request as `system:anonymous'.  TLS 1.2 with cert auth works.")

;;; ---------------------------------------------------------------------------
;;; Connection open

(defun k8s-connection-open (kubeconfig-path)
  "Open a connection to the K8s cluster defined in KUBECONFIG-PATH.
Returns a `k8s-connection' struct.  The struct carries a `docker-config'
in its `docker-cfg' slot — all subsequent requests go through
`docker-http-request' against that config."
  (let* ((config (k8s-config-load kubeconfig-path))
         (cluster (k8s-config-resolve-cluster config))
         (user (k8s-config-resolve-user config))
         (server (k8s-cluster-server cluster))
         (host-port (k8s--parse-url server))
         (host (car host-port))
         (port (cdr host-port))
         (ca-pem (k8s-cluster-ca-cert-pem cluster))
         (ca-file (k8s-api--temp-pem "k8s-ca-" ca-pem))
         (cert-pem (k8s-user-client-cert-pem user))
         (key-pem (k8s-user-client-key-pem user))
         (client-cert-file (k8s-api--temp-pem "k8s-cert-" cert-pem t))
         (client-key-file (k8s-api--temp-pem "k8s-key-" key-pem t))
         (token (or (k8s-user-token user)
                    (k8s-api--exec-token user)))
         (docker-cfg
          (docker-config--new
           :host host
           :port port
           :tls t
           :tls-verify nil          ; k8s clusters routinely use self-
                                    ; signed certs with no matching SAN
           :tls-ca-cert ca-file
           :tls-cert client-cert-file
           :tls-key client-key-file
           :tls-priority k8s-tls-priority
           :default-headers
           (append
            (when token
              `(("Authorization" . ,(format "Bearer %s" token))))
            '(("Accept" . "application/json")
              ("User-Agent" . "emak8s/0.1"))))))
    (message "emak8s: connecting to %s:%d ..." host port)
    (k8s-connection--new
     :config config
     :cluster cluster
     :user user
     :server server
     :host host
     :port port
     :ca-file ca-file
     :client-cert-file client-cert-file
     :client-key-file client-key-file
     :docker-cfg docker-cfg)))

(defun k8s-api--exec-token (user)
  "Run USER's `exec' plugin, if any, and return the bearer token it emits.

Plugins like `aws eks get-token' or `gke-gcloud-auth-plugin' implement
the client-go ExecCredential protocol: stdout is a JSON
`{ \"kind\": \"ExecCredential\", \"status\": { \"token\": \"…\" } }'.
Returns nil if no exec section is present, the binary isn't on PATH,
the helper exits non-zero, or the JSON is malformed."
  (when-let* ((exec (k8s-user-exec user))
              (command (cdr (assoc "command" exec))))
    (let* ((args (cdr (assoc "args" exec)))
           (env-list (cdr (assoc "env" exec)))
           (env (mapcar (lambda (e)
                          (cons (cdr (assoc "name" e))
                                (cdr (assoc "value" e))))
                        env-list))
           (result (eltainer-shell-helper-json command args nil :env env)))
      (and result
           (cdr (assoc 'token (cdr (assoc 'status result))))))))

(defun k8s-api--temp-pem (prefix pem &optional restrict-mode)
  "Write PEM (a string) to a temp file with PREFIX and return its path."
  (when pem
    (let ((f (make-temp-file prefix nil ".pem")))
      (with-temp-file f
        (set-buffer-multibyte nil)
        (insert pem))
      (when restrict-mode (set-file-modes f #o600))
      f)))

;;; ---------------------------------------------------------------------------
;;; K8s API requests (routed through docker-http-request)

(defun k8s--http-json (conn method path)
  "Send METHOD PATH against CONN.  Return decoded JSON or signal."
  (let* ((cfg (k8s-connection-docker-cfg conn))
         (resp (docker-http-request cfg method path)))
    (unless (docker-http-ok-p resp)
      (error "K8s API request failed: %s %s [%d]"
             method path (docker-http-response-status resp)))
    ;; Native JSON returns alists/lists per docker-http-json; k8s code
    ;; downstream reads `.items' as a vector (the old json-read default
    ;; for arrays).  `:array-type 'array' on json-parse-string preserves
    ;; that — keep it for now and revisit when the k8s readers move to
    ;; lists.
    (let ((body (docker-http-response-body resp)))
      (when (and body (> (length body) 0))
        (json-parse-string body
                           :object-type 'alist
                           :array-type 'array
                           :null-object nil
                           :false-object :false)))))

(defun k8s-get (conn path)
  "Perform a GET request to PATH on the K8s API via CONN."
  (k8s--http-json conn "GET" path))

(defun k8s-delete (conn path)
  "Perform a DELETE request to PATH on the K8s API via CONN."
  (k8s--http-json conn "DELETE" path))

(defvar k8s--list-api-paths
  '((pods         "/api/v1/pods"
                  "/api/v1/namespaces/%s/pods")
    (deployments  "/apis/apps/v1/deployments"
                  "/apis/apps/v1/namespaces/%s/deployments")
    (services     "/api/v1/services"
                  "/api/v1/namespaces/%s/services")
    (statefulsets "/apis/apps/v1/statefulsets"
                  "/apis/apps/v1/namespaces/%s/statefulsets")
    (daemonsets   "/apis/apps/v1/daemonsets"
                  "/apis/apps/v1/namespaces/%s/daemonsets")
    (jobs         "/apis/batch/v1/jobs"
                  "/apis/batch/v1/namespaces/%s/jobs")
    (cronjobs     "/apis/batch/v1/cronjobs"
                  "/apis/batch/v1/namespaces/%s/cronjobs")
    (configmaps   "/api/v1/configmaps"
                  "/api/v1/namespaces/%s/configmaps")
    (secrets      "/api/v1/secrets"
                  "/api/v1/namespaces/%s/secrets")
    (ingresses    "/apis/networking.k8s.io/v1/ingresses"
                  "/apis/networking.k8s.io/v1/namespaces/%s/ingresses"))
  "Alist mapping resource types (plural) to (ALL-PATH NAMESPACED-PATH-TEMPLATE).
Keys are plural to match `k8s--define-view's macro name convention.")

(defun k8s--list-path (type &optional namespace)
  "Return the API list path for resource TYPE, optionally in NAMESPACE."
  (let ((entry (cdr (assq type k8s--list-api-paths))))
    (if namespace
        (format (cadr entry) namespace)
      (car entry))))

(defvar k8s--resource-api-paths
  '((pod         . "/api/v1/namespaces/%s/pods/%s")
    (deployment  . "/apis/apps/v1/namespaces/%s/deployments/%s")
    (service     . "/api/v1/namespaces/%s/services/%s")
    (statefulset . "/apis/apps/v1/namespaces/%s/statefulsets/%s")
    (daemonset   . "/apis/apps/v1/namespaces/%s/daemonsets/%s")
    (job         . "/apis/batch/v1/namespaces/%s/jobs/%s")
    (cronjob     . "/apis/batch/v1/namespaces/%s/cronjobs/%s")
    (configmap   . "/api/v1/namespaces/%s/configmaps/%s")
    (secret      . "/api/v1/namespaces/%s/secrets/%s")
    (ingress     . "/apis/networking.k8s.io/v1/namespaces/%s/ingresses/%s"))
  "Alist mapping section types to API path templates (namespace, name).")

(defun k8s-delete-resource (conn type namespace name)
  "Delete resource of TYPE named NAME in NAMESPACE via CONN."
  (let ((template (cdr (assq type k8s--resource-api-paths))))
    (unless template
      (error "Don't know how to delete %s" type))
    (k8s-delete conn (format template namespace name))))

(defun k8s-get-text (conn path)
  "Perform a GET request to PATH on the K8s API via CONN.
Returns the raw response body as a string (for non-JSON endpoints like logs)."
  (let* ((cfg (k8s-connection-docker-cfg conn))
         (resp (docker-http-request
                cfg "GET" path
                :headers '(("Accept" . "text/plain")))))
    (when (docker-http-ok-p resp)
      (docker-http-response-body resp))))

(defun k8s-pod-logs (conn namespace name &optional tail-lines container)
  "Fetch logs for pod NAME in NAMESPACE via CONN.
Returns log text as a string.  TAIL-LINES limits to last N lines.
CONTAINER specifies which container (required for multi-container pods)."
  (let* ((params (list (format "tailLines=%d" (or tail-lines 100))))
         (_ (when container
              (push (format "container=%s" container) params)))
         (query (mapconcat #'identity params "&"))
         (path (format "/api/v1/namespaces/%s/pods/%s/log?%s"
                       namespace name query)))
    (or (k8s-get-text conn path) "")))

;;; ---------------------------------------------------------------------------
;;; Convenience functions

(defun k8s-list-namespaces (conn)
  "List all namespaces via CONN.  Returns a vector of namespace alists."
  (cdr (assq 'items (k8s-get conn "/api/v1/namespaces"))))

(defun k8s-list-pods (conn &optional namespace)
  "List pods via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/pods" namespace)
                "/api/v1/pods")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-deployments (conn &optional namespace)
  "List deployments via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/apps/v1/namespaces/%s/deployments" namespace)
                "/apis/apps/v1/deployments")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-services (conn &optional namespace)
  "List services via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/services" namespace)
                "/api/v1/services")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-statefulsets (conn &optional namespace)
  "List statefulsets via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/apps/v1/namespaces/%s/statefulsets" namespace)
                "/apis/apps/v1/statefulsets")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-daemonsets (conn &optional namespace)
  "List daemonsets via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/apps/v1/namespaces/%s/daemonsets" namespace)
                "/apis/apps/v1/daemonsets")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-jobs (conn &optional namespace)
  "List jobs via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/batch/v1/namespaces/%s/jobs" namespace)
                "/apis/batch/v1/jobs")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-cronjobs (conn &optional namespace)
  "List cronjobs via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/batch/v1/namespaces/%s/cronjobs" namespace)
                "/apis/batch/v1/cronjobs")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-configmaps (conn &optional namespace)
  "List configmaps via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/configmaps" namespace)
                "/api/v1/configmaps")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-secrets (conn &optional namespace)
  "List secrets via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/api/v1/namespaces/%s/secrets" namespace)
                "/api/v1/secrets")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-list-ingresses (conn &optional namespace)
  "List ingresses via CONN, optionally in NAMESPACE."
  (let ((path (if namespace
                  (format "/apis/networking.k8s.io/v1/namespaces/%s/ingresses"
                          namespace)
                "/apis/networking.k8s.io/v1/ingresses")))
    (cdr (assq 'items (k8s-get conn path)))))

(defun k8s-get-resource (conn path)
  "GET a single resource at PATH via CONN."
  (k8s-get conn path))

(defun k8s--extract-resource-version (response)
  "Return metadata.resourceVersion from a list RESPONSE."
  (cdr (assq 'resourceVersion (cdr (assq 'metadata response)))))

(defun k8s-list-events (conn namespace &optional field-selector)
  "List events in NAMESPACE via CONN, optionally filtered by FIELD-SELECTOR."
  (let* ((query (if field-selector
                    (format "?fieldSelector=%s"
                            (url-hexify-string field-selector))
                  ""))
         (path (format "/api/v1/namespaces/%s/events%s" namespace query)))
    (cdr (assq 'items (k8s-get conn path)))))

;;; ---------------------------------------------------------------------------
;;; Error condition

(define-error 'k8s-api-error "Kubernetes API error")

(provide 'k8s-api)
;;; k8s-api.el ends here
