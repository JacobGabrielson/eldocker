;;; docker-images.el --- Docker image management -*- lexical-binding: t -*-
;;
;; List, pull, remove Docker images.  Uses the Docker CLI via
;; docker-api.el.
;;
;; Usage:
;;   (docker-list-images cfg)
;;   (docker-pull-image cfg "ubuntu:latest")
;;   (docker-remove-image cfg "ubuntu:latest")

(require 'cl-lib)
(require 'docker-api)

;;; ---------------------------------------------------------------------------
;;; Data model

(cl-defstruct (docker-image (:constructor docker-image--new) (:copier nil))
  "A Docker image summary."
  id                ; string, short image ID
  repository        ; string, repository (tag)
  tag               ; string, image tag
  created           ; string, creation timestamp
  size)             ; string, human-readable size

;;; ---------------------------------------------------------------------------
;;; Image listing

(defun docker-list-images (cfg)
  "List Docker images via GET /images/json.
Daemon returns one entry per image with a list of RepoTags; we explode
that to one `docker-image' struct per (repository, tag) pair so the
existing UI keeps showing one row per tag."
  (let ((data (docker-engine-get cfg "/images/json")))
    (vconcat
     (cl-loop
      for img in data
      for tags = (or (alist-get 'RepoTags img) '("<none>:<none>"))
      append
      (mapcar
       (lambda (tag)
         (let* ((colon (string-search ":" (or tag "")))
                (repo (if colon (substring tag 0 colon) tag))
                (tagv (if colon (substring tag (1+ colon)) "")))
           (docker-image--new
            :id (alist-get 'Id img)
            :repository repo
            :tag tagv
            :created (docker--epoch-to-iso (alist-get 'Created img))
            :size (file-size-human-readable (or (alist-get 'Size img) 0)))))
       tags)))))

;;; ---------------------------------------------------------------------------
;;; Image lifecycle

;; `docker-pull-image' lands in Phase 5 (needs the streaming progress
;; endpoint and registry-auth headers).  Removed from this module for
;; now to avoid leaving a half-CLI implementation behind; the user-
;; visible UI doesn't expose pull yet.

(defun docker-remove-image (cfg name &optional force)
  "Remove image NAME via DELETE /images/NAME.  FORCE adds force=1."
  (condition-case _err
      (progn (docker-engine-delete cfg (format "/images/%s" name)
                                   :query (when force '(("force" . "1"))))
             t)
    (docker-api-error nil)))

(defun docker-tag-image (cfg image new-tag)
  "Tag IMAGE as NEW-TAG (\"repo:tag\") via POST /images/IMAGE/tag."
  (let* ((colon (string-search ":" new-tag))
         (repo (if colon (substring new-tag 0 colon) new-tag))
         (tag (and colon (substring new-tag (1+ colon)))))
    (condition-case _err
        (progn (docker-engine-post cfg (format "/images/%s/tag" image)
                                   :query `(("repo" . ,repo)
                                            ,@(when tag `(("tag" . ,tag)))))
               t)
      (docker-api-error nil))))

;;; ---------------------------------------------------------------------------
;;; Inspect

(defun docker-inspect-image (cfg name)
  "Inspect image NAME via GET /images/NAME/json.  Returns the alist or nil."
  (condition-case nil
      (docker-engine-get cfg (format "/images/%s/json" name))
    (docker-api-error nil)))

(defalias 'docker-inspect-image-json #'docker-inspect-image)

(provide 'docker-images)
;;; docker-images.el ends here
