;;; test-docker-images.el --- Tests for docker-images -*- lexical-binding: t -*-

(require 'ert)
(require 'docker-images)
(require 'docker-config)

(ert-deftest docker-images-list ()
  "List Docker images (at least one image should exist)."
  (let* ((cfg (docker-config-detect))
         (images (docker-list-images cfg)))
    (should images)
    (should (vectorp images))))

(ert-deftest docker-images-struct ()
  "Verify image struct accessors."
  (let* ((cfg (docker-config-detect))
         (images (docker-list-images cfg)))
    (when (> (length images) 0)
      (let ((img (aref images 0)))
        (should (docker-image-p img))
        (should (docker-image-id img))))))

(ert-deftest docker-images-inspect ()
  "Inspect an image."
  (let* ((cfg (docker-config-detect))
         (images (docker-list-images cfg)))
    (when (> (length images) 0)
      (let* ((repo (docker-image-repository (aref images 0)))
             (json (docker-inspect-image cfg repo)))
        (should json)))))

(provide 'test-docker-images)
;;; test-docker-images.el ends here
