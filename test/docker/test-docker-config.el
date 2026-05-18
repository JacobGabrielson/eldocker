;;; test-docker-config.el --- Tests for docker-config -*- lexical-binding: t -*-

(require 'ert)
(require 'docker-config)

(ert-deftest docker-config-detect-socket ()
  "Detect Docker socket path (default or env)."
  (let ((cfg (docker-config-detect)))
    (should (docker-config-socket-path cfg))
    (should (stringp (docker-config-socket-path cfg)))))

(ert-deftest docker-config-dockerfile-detection ()
  "Detect Dockerfile filenames."
  (should (docker-config-dockerfile-p "Dockerfile"))
  (should (docker-config-dockerfile-p "dockerfile"))
  (should (docker-config-dockerfile-p "My.Dockerfile"))
  (should (docker-config-dockerfile-p "nginx.dockerfile"))
  (should-not (docker-config-dockerfile-p "nginx.conf"))
  (should-not (docker-config-dockerfile-p "package.json")))

(ert-deftest docker-config-struct-accessors ()
  "Test docker-config struct creation and accessors."
  (let ((cfg (docker-config--new
              :socket-path "/var/run/docker.sock"
              :host nil :port nil
              :tls-verify nil)))
    (should (docker-config-p cfg))
    (should (string= (docker-config-socket-path cfg) "/var/run/docker.sock"))
    (should-not (docker-config-host cfg))))

(provide 'test-docker-config)
;;; test-docker-config.el ends here
