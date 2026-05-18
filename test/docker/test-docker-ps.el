;;; test-docker-ps.el --- Tests for docker-ps -*- lexical-binding: t -*-

(require 'ert)
(require 'docker-ps)
(require 'docker-config)

(ert-deftest docker-ps-list-containers ()
  "List running containers (at least one should exist: ourselves)."
  (let* ((cfg (docker-config-detect))
         (containers (docker-list-containers cfg)))
    (should containers)
    (should (vectorp containers))))

(ert-deftest docker-ps-list-all-containers ()
  "List all containers (including stopped)."
  (let* ((cfg (docker-config-detect))
         (all (docker-list-containers cfg :all t)))
    (should all)
    (should (vectorp all))))

(ert-deftest docker-ps-container-struct ()
  "Verify container struct accessors."
  (let* ((cfg (docker-config-detect))
         (containers (docker-list-containers cfg)))
    (when (> (length containers) 0)
      (let ((c (aref containers 0)))
        (should (docker-container-p c))
        (should (docker-container-name c))
        (should (docker-container-state c))))))

(ert-deftest docker-ps-inspect-container ()
  "Inspect a running container."
  (let* ((cfg (docker-config-detect))
         (containers (docker-list-containers cfg)))
    (when (> (length containers) 0)
      (let* ((name (docker-container-name (aref containers 0)))
             (detail (docker-inspect-container cfg name)))
        (should detail)
        (should (docker-container-detail-p detail))))))

(provide 'test-docker-ps)
;;; test-docker-ps.el ends here
