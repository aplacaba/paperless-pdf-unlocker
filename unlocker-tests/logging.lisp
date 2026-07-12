(defpackage unlocker-tests/logging
  (:use :cl :rove :unlocker.logging))
(in-package :unlocker-tests/logging)

(deftest parse-log-level
  (testing "known levels parse to keywords"
    (ok (eq (parse-log-level "debug") :debug))
    (ok (eq (parse-log-level "INFO") :info))
    (ok (eq (parse-log-level "warn") :warn))
    (ok (eq (parse-log-level "error") :error)))
  (testing "unknown falls back to default"
    (ok (eq (parse-log-level "nope" :info) :info))
    (ok (eq (parse-log-level nil :warn) :warn))))

(defun capture-log (level fn)
  (let ((unlocker.logging:*log-level* level)
        (*standard-output* (make-string-output-stream)))
    (funcall fn)
    (get-output-stream-string *standard-output*)))

(deftest level-filtering
  (testing "info suppresses debug; emits info/warn/error"
    (let ((out (capture-log :info
                            (lambda ()
                              (log-debug nil "d")
                              (log-info nil "i")
                              (log-warn nil "w")
                              (log-error nil "e")))))
      (ok (not (search "[DEBUG]" out)))
      (ok (search "[INFO]" out))
      (ok (search "[WARN]" out))
      (ok (search "[ERROR]" out))))
  (testing "debug level emits debug messages"
    (let ((out (capture-log :debug (lambda () (log-debug nil "dbg")))))
      (ok (search "[DEBUG]" out))))
  (testing "doc-id is included when provided"
    (let ((out (capture-log :info (lambda () (log-info 42 "hello")))))
      (ok (search "doc=42" out)))))
