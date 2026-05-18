;;; test-docker-logs.el --- Tests for docker-logs -*- lexical-binding: t -*-

(require 'ert)
(require 'docker-config)
(require 'docker-api)
(require 'docker-logs)

(ert-deftest docker-logs-stream-captures-output ()
  "Tailing a running container's logs collects its stdout.
Test-only scaffolding uses `call-process' to spawn the sentinel —
production code never shells out for container lifecycle."
  (let* ((cfg (docker-config-detect))
         (name (format "eldocker-logs-test-%d" (random 100000))))
    (unless (zerop (call-process "docker" nil nil nil "run" "-d" "--name" name
                                 "alpine:3.20" "sh" "-c"
                                 "echo eldocker-test-marker && sleep 30"))
      (ert-skip "could not start sentinel container"))
    (unwind-protect
        (let ((kill-buffer-query-functions nil)
              (buf (docker-logs-start cfg name :tail 100 :follow nil)))
          (with-current-buffer buf
            (let ((deadline (+ (float-time) 5.0)))
              (while (and (< (float-time) deadline)
                          (not (string-match-p "eldocker-test-marker"
                                               (buffer-string))))
                (accept-process-output docker-logs--process 0.1)))
            (should (string-match-p "eldocker-test-marker" (buffer-string))))
          (kill-buffer buf))
      (call-process "docker" nil nil nil "rm" "-f" name))))

(provide 'test-docker-logs)
;;; test-docker-logs.el ends here
