;;; eltainer-shell-helper.el --- Invoke external auth helpers -*- lexical-binding: t -*-
;;
;; A small wrapper around `call-process-region' / `call-process' for the
;; one place we genuinely shell out to a non-docker / non-kubectl
;; binary: external auth helpers (`docker-credential-osxkeychain' for
;; the Docker side, `aws-iam-authenticator' / `gke-gcloud-auth-plugin'
;; for the K8s side).  These are stand-alone tools that take optional
;; stdin and emit JSON on stdout — same shape on both sides.
;;
;; Public API:
;;   (eltainer-shell-helper-run  BINARY ARGS [STDIN] [&key ENV])
;;     → output string on success, nil on any failure
;;
;;   (eltainer-shell-helper-json BINARY ARGS [STDIN] [&key ENV])
;;     → decoded alist on success, nil on failure (JSON or binary)

(require 'cl-lib)

(cl-defun eltainer-shell-helper-run (binary &optional args stdin &key env)
  "Run BINARY with ARGS, feeding STDIN (string or nil) on stdin.
ARGS is a list of strings.  ENV is an alist of (NAME . VALUE) pairs
merged into `process-environment' for this call.  Returns the captured
stdout as a string on a zero exit code; returns nil otherwise (binary
missing, non-zero exit, etc.)."
  (when (or (executable-find binary) (file-executable-p binary))
    (let ((process-environment
           (append
            (mapcar (lambda (p) (format "%s=%s" (car p) (cdr p))) env)
            process-environment)))
      (with-temp-buffer
        (let* ((stdout (current-buffer))
               (exit
                (if stdin
                    (with-temp-buffer
                      (insert stdin)
                      (apply #'call-process-region
                             (point-min) (point-max) binary nil stdout nil args))
                  (apply #'call-process binary nil stdout nil args))))
          (when (eql exit 0)
            (buffer-string)))))))

(cl-defun eltainer-shell-helper-json (binary &optional args stdin &key env)
  "Like `eltainer-shell-helper-run' but parse stdout as JSON.
Returns the decoded alist on success, nil on any failure (binary
missing, non-zero exit, malformed JSON)."
  (when-let ((out (eltainer-shell-helper-run binary args stdin :env env)))
    (let ((trimmed (string-trim out)))
      (when (and (> (length trimmed) 0)
                 (memq (aref trimmed 0) '(?\{ ?\[)))
        (condition-case nil
            (json-parse-string trimmed
                               :object-type 'alist
                               :array-type 'list
                               :null-object nil
                               :false-object :false)
          (error nil))))))

(provide 'eltainer-shell-helper)
;;; eltainer-shell-helper.el ends here
