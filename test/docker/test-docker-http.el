;;; test-docker-http.el --- Tests for docker-http -*- lexical-binding: t -*-
;;
;; Unit tests (no daemon) cover the parsers: status line, headers,
;; chunked transfer-encoding decode, query encoding.  Integration tests
;; hit the live local daemon for GET /version and GET /containers/json
;; to assert end-to-end correctness.

(require 'ert)
(require 'docker-config)
(require 'docker-http)

;;; ---------------------------------------------------------------------------
;;; Unit tests: parsers

(ert-deftest docker-http-status-line-ok ()
  "Status line parses HTTP/1.x VERSION CODE REASON correctly."
  (let ((r (docker-http--parse-status-line "HTTP/1.1 200 OK")))
    (should (equal (car r) 200))
    (should (equal (cdr r) "OK"))))

(ert-deftest docker-http-status-line-no-reason ()
  "Status line without a reason phrase still parses."
  (let ((r (docker-http--parse-status-line "HTTP/1.1 204 ")))
    (should (equal (car r) 204))
    (should (equal (cdr r) ""))))

(ert-deftest docker-http-status-line-malformed ()
  "Malformed status line signals docker-http-error."
  (should-error (docker-http--parse-status-line "OK 200")
                :type 'docker-http-error))

(ert-deftest docker-http-headers-basic ()
  "Header block parses into a lower-cased trimmed alist."
  (let ((h (docker-http--parse-headers
            "Content-Type: application/json\r\nX-Foo:  bar  ")))
    (should (equal (alist-get "content-type" h nil nil #'string=) "application/json"))
    (should (equal (alist-get "x-foo" h nil nil #'string=) "bar"))))

(ert-deftest docker-http-headers-malformed ()
  "A line without a colon signals docker-http-error."
  (should-error (docker-http--parse-headers "garbage no-colon here")
                :type 'docker-http-error))

(ert-deftest docker-http-chunked-decode-roundtrip ()
  "Chunked-encoded body decodes back to the original payload."
  ;; "Hello world" split into "Hello " + "world"
  (let* ((raw "6\r\nHello \r\n5\r\nworld\r\n0\r\n\r\n"))
    (should (equal (docker-http--decode-chunked raw) "Hello world"))))

(ert-deftest docker-http-chunked-with-trailing-extension ()
  "Chunked decoder ignores chunk extensions after `;'."
  (let* ((raw "5;ext=foo\r\nhello\r\n0\r\n\r\n"))
    (should (equal (docker-http--decode-chunked raw) "hello"))))

(ert-deftest docker-http-split-response-roundtrip ()
  "`docker-http--split-response' rejoins to the original 3-tuple."
  (let* ((raw (concat "HTTP/1.1 200 OK\r\n"
                      "Content-Type: text/plain\r\n"
                      "Content-Length: 5\r\n"
                      "\r\n"
                      "hello"))
         (parts (docker-http--split-response raw)))
    (should (equal (nth 0 parts) "HTTP/1.1 200 OK"))
    (should (equal (nth 2 parts) "hello"))
    (let ((hdrs (docker-http--parse-headers (nth 1 parts))))
      (should (equal (alist-get "content-length" hdrs nil nil #'string=) "5")))))

(ert-deftest docker-http-encode-query ()
  "Query encoding escapes special characters."
  (should (equal (docker-http--encode-query
                  '(("all" . "1") ("filters" . "{\"status\":[\"running\"]}")))
                 "all=1&filters=%7B%22status%22%3A%5B%22running%22%5D%7D")))

;;; ---------------------------------------------------------------------------
;;; Integration tests: live daemon

(ert-deftest docker-http-live-version ()
  "GET /version against the live daemon returns 200 + a server version."
  (let* ((cfg (docker-config-detect))
         (resp (docker-http-request cfg "GET" "/version")))
    (should (docker-http-ok-p resp))
    (let ((j (docker-http-json resp)))
      (should j)
      (should (stringp (alist-get 'Version j))))))

(ert-deftest docker-http-live-containers-json ()
  "GET /containers/json returns 200 and a list (possibly empty)."
  (let* ((cfg (docker-config-detect))
         (resp (docker-http-request cfg "GET" "/containers/json"
                                    :query '(("all" . "1")))))
    (should (docker-http-ok-p resp))
    (let ((cs (docker-http-json resp)))
      (should (listp cs)))))

(ert-deftest docker-http-live-404 ()
  "Hitting a bogus path returns a 4xx and parses cleanly."
  (let* ((cfg (docker-config-detect))
         (resp (docker-http-request cfg "GET" "/no-such-endpoint")))
    (should-not (docker-http-ok-p resp))
    (should (>= (docker-http-response-status resp) 400))
    (should (< (docker-http-response-status resp) 500))))

(provide 'test-docker-http)
;;; test-docker-http.el ends here
