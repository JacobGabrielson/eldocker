;;; docker-stream.el --- Frame parsers for streaming docker endpoints -*- lexical-binding: t -*-
;;
;; Two parsers consumed by `docker-http-stream' callbacks:
;;
;; - `docker-stream-make-demux'    8-byte multiplex frames the daemon uses
;;                                 for non-TTY logs / attach / exec output.
;;                                 Each frame: [type:1][0:3][size:4 BE][payload].
;;                                 type 0=stdin, 1=stdout, 2=stderr.
;;
;; - `docker-stream-make-ndjson'   line-oriented JSON-per-line, used by
;;                                 /events and image-pull progress streams.
;;
;; Each constructor returns a closure that you feed raw bytes; the
;; closure invokes per-frame callbacks and remembers partial input.

(require 'cl-lib)

;;; ---------------------------------------------------------------------------
;;; Multiplex stream demuxer

(defun docker-stream-make-demux (on-frame)
  "Return a function that feeds bytes through the 8-byte multiplex framer.
ON-FRAME is `(lambda (STREAM-TYPE PAYLOAD-BYTES))', STREAM-TYPE one of
`stdin' / `stdout' / `stderr' / `unknown'."
  (let ((buf ""))
    (lambda (bytes)
      (setq buf (concat buf bytes))
      (let ((pos 0)
            (len (length buf)))
        (catch 'done
          (while (>= (- len pos) 8)
            (let* ((typ (aref buf pos))
                   (size (logior (ash (aref buf (+ pos 4)) 24)
                                 (ash (aref buf (+ pos 5)) 16)
                                 (ash (aref buf (+ pos 6)) 8)
                                 (aref buf (+ pos 7))))
                   (payload-end (+ pos 8 size)))
              (if (> payload-end len)
                  (throw 'done nil)
                (funcall on-frame
                         (pcase typ
                           (0 'stdin)
                           (1 'stdout)
                           (2 'stderr)
                           (_ 'unknown))
                         (substring buf (+ pos 8) payload-end))
                (setq pos payload-end)))))
        (setq buf (substring buf pos))))))

;;; ---------------------------------------------------------------------------
;;; NDJSON splitter

(defun docker-stream-make-ndjson (on-object &optional on-malformed)
  "Return a function that splits bytes into newline-terminated JSON objects.
ON-OBJECT is `(lambda (OBJECT))' invoked with each decoded alist/list.
ON-MALFORMED is `(lambda (LINE ERR-STRING))' for parse failures (optional)."
  (let ((buf ""))
    (lambda (bytes)
      (setq buf (concat buf bytes))
      (let ((lines (split-string buf "\n")))
        ;; Last element is the partial (may be empty) — stash it back.
        (setq buf (car (last lines)))
        (dolist (line (butlast lines))
          (when (> (length (string-trim line)) 0)
            (condition-case err
                (funcall on-object
                         (json-parse-string
                          line
                          :object-type 'alist
                          :array-type 'list
                          :null-object nil
                          :false-object :false))
              (error
               (when on-malformed
                 (funcall on-malformed line (error-message-string err)))))))))))

(provide 'docker-stream)
;;; docker-stream.el ends here
