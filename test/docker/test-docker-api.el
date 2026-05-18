;;; test-docker-api.el --- Tests for docker-api engine helpers -*- lexical-binding: t -*-

(require 'ert)
(require 'docker-api)
(require 'docker-config)

(ert-deftest docker-api-engine-get-version ()
  "docker-engine-get /version returns an alist with a Version field."
  (let* ((cfg (docker-config-detect))
         (data (docker-engine-get cfg "/version")))
    (should data)
    (should (stringp (alist-get 'Version data)))
    (should (stringp (alist-get 'ApiVersion data)))))

(ert-deftest docker-api-engine-get-containers ()
  "GET /containers/json returns a list (possibly empty)."
  (let* ((cfg (docker-config-detect))
         (data (docker-engine-get cfg "/containers/json")))
    (should (listp data))))

(ert-deftest docker-api-engine-get-error ()
  "A 404 from the engine signals docker-api-error with :status."
  (let* ((cfg (docker-config-detect)))
    (condition-case err
        (progn (docker-engine-get cfg "/no-such-endpoint")
               (should nil))
      (docker-api-error
       (should (equal 404 (plist-get (cdr err) :status)))))))

(ert-deftest docker-api-version-prefix-cached ()
  "docker--api-prefix caches and returns either an empty string or /vX.Y."
  (docker-engine-reset-version-cache)
  (let* ((cfg (docker-config-detect))
         (p1 (docker--api-prefix cfg))
         (p2 (docker--api-prefix cfg)))
    (should (eq p1 p2))
    (should (or (string= p1 "")
                (string-match-p "\\`/v[0-9]+\\.[0-9]+\\'" p1)))))

(provide 'test-docker-api)
;;; test-docker-api.el ends here
