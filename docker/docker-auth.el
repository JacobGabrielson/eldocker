;;; docker-auth.el --- Registry credentials for image pull/push -*- lexical-binding: t -*-
;;
;; Read ~/.docker/config.json, resolve credential helpers, and build
;; the `X-Registry-Auth' header value the engine expects for any
;; authenticated registry operation (image pull / push / search).
;;
;; The credential helpers (`docker-credential-osxkeychain', `-pass',
;; `-secretservice', `-wincred', …) are separate binaries that take a
;; registry hostname on stdin and emit a JSON `{"Username":"…",
;; "Secret":"…"}` blob on stdout.  We shell out to them — they're
;; their own product, not the docker CLI.
;;
;; If neither helpers nor inline `auths` give us credentials we return
;; nil; the daemon then attempts an anonymous pull, which is what the
;; CLI does too.

(require 'cl-lib)
(require 'json)
(require 'eltainer-shell-helper)

(defcustom docker-auth-config-path
  (expand-file-name "~/.docker/config.json")
  "Path to docker's CLI config (read-only; we never write here)."
  :type 'file
  :group 'docker)

(defun docker-auth--read-config ()
  "Return the parsed contents of `docker-auth-config-path', or nil."
  (when (file-exists-p docker-auth-config-path)
    (with-temp-buffer
      (insert-file-contents docker-auth-config-path)
      (condition-case nil
          (json-parse-buffer
           :object-type 'alist
           :array-type 'list
           :null-object nil
           :false-object :false)
        (error nil)))))

(defun docker-auth--canonical-host (registry)
  "Map REGISTRY to the form the docker CLI uses as the config key."
  (cond
   ((null registry) "https://index.docker.io/v1/")
   ((or (string= registry "docker.io")
        (string= registry "index.docker.io"))
    "https://index.docker.io/v1/")
   (t registry)))

(defun docker-auth--helper-for (cfg-alist registry)
  "Return the helper-binary basename for REGISTRY, per CFG-ALIST."
  (let* ((helpers (alist-get 'credHelpers cfg-alist))
         (specific (and helpers (alist-get (intern registry) helpers)))
         (default (alist-get 'credsStore cfg-alist)))
    (or specific default)))

(defun docker-auth--run-helper (helper registry)
  "Run docker-credential-HELPER `get' for REGISTRY.  Returns the parsed
JSON `((Username . …) (Secret . …) …)' alist, or nil on any failure."
  (eltainer-shell-helper-json
   (format "docker-credential-%s" helper) '("get") registry))

(defun docker-auth--inline-auth (cfg-alist registry)
  "Look up an inline `{auth: \"base64\"}` entry in CFG-ALIST for REGISTRY."
  (let ((auths (alist-get 'auths cfg-alist)))
    (alist-get (intern registry) auths)))

(defun docker-auth-credentials (registry)
  "Resolve credentials for REGISTRY (a hostname or nil for Docker Hub).
Returns an alist `((Username . …) (Password . …) (Serveraddress . …))'
suitable for `docker-auth-header', or nil for anonymous."
  (let* ((cfg-alist (docker-auth--read-config))
         (canon (docker-auth--canonical-host registry))
         (helper (and cfg-alist (docker-auth--helper-for cfg-alist canon)))
         (result
          (cond
           (helper
            (condition-case nil
                (let ((j (docker-auth--run-helper helper canon)))
                  (and j `((Username . ,(alist-get 'Username j))
                           (Password . ,(alist-get 'Secret j))
                           (Serveraddress . ,canon))))
              (error nil)))
           (cfg-alist
            (let ((inline (docker-auth--inline-auth cfg-alist canon)))
              (when inline
                (let* ((b64 (alist-get 'auth inline))
                       (decoded (and b64 (base64-decode-string b64)))
                       (colon (and decoded (string-search ":" decoded))))
                  (when colon
                    `((Username . ,(substring decoded 0 colon))
                      (Password . ,(substring decoded (1+ colon)))
                      (Serveraddress . ,canon))))))))))
    result))

(defun docker-auth-header (registry)
  "Return the `X-Registry-Auth' header value for REGISTRY, or nil if anonymous."
  (let ((creds (docker-auth-credentials registry)))
    (when creds
      (base64-encode-string
       (json-serialize creds :null-object nil :false-object :false)
       t))))

(provide 'docker-auth)
;;; docker-auth.el ends here
