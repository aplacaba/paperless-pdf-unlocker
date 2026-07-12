(defpackage unlocker-tests/config
  (:use :cl :rove :unlocker.config))
(in-package :unlocker-tests/config)

(defun restore-envs (saved)
  (loop for (var old-val) in saved
        do (sb-posix:putenv (format nil "~A=~A" var (or old-val "")))))

(defun set-envs (pairs)
  (let ((saved nil))
    (dotimes (i (length pairs) (nreverse saved))
      (let* ((pair (nth i pairs))
             (var (first pair))
             (val (second pair)))
        (push (list var (uiop:getenv var)) saved)
        (sb-posix:putenv (format nil "~A=~A" var val))))))

(defmacro with-env ((&rest bindings) &body body)
  `(let ((saved (set-envs (list ,@(mapcar (lambda (b)
                                            `(list ,(first b) ,(second b)))
                                          bindings)))))
     (unwind-protect (progn ,@body)
       (restore-envs saved))))

(deftest parse-candidates
  (testing "comma-separated values"
    (ok (equal (parse-candidates "alpha,beta,gamma")
               (list "alpha" "beta" "gamma"))))
  (testing "newline-separated values with blanks"
    (ok (equal (parse-candidates (format nil "alpha~%~%beta~%"))
               (list "alpha" "beta"))))
  (testing "mixed comma and newline"
    (ok (equal (parse-candidates (format nil "a,b~%c"))
               (list "a" "b" "c"))))
  (testing "trims whitespace"
    (ok (equal (parse-candidates " a , b ")
               (list "a" "b")))))

(deftest make-config-from-env
  (testing "applies defaults for optional variables"
    (with-env (("PAPERLESS_URL" "https://paperless.example.com")
               ("PAPERLESS_TOKEN" "tok")
               ("PASSWORD_CANDIDATES" "pw1,pw2"))
      (let ((cfg (make-config-from-env)))
        (ok (equal (config-locked-tag cfg) "locked"))
        (ok (equal (config-unlock-failed-tag cfg) "unlock-failed"))
        (ok (eql (config-poll-interval cfg) 60))
        (ok (eql (config-http-timeout cfg) 30))
        (ok (eq (config-log-level cfg) :info))
        (ok (equal (config-candidates cfg) (list "pw1" "pw2"))))))

  (testing "missing PAPERLESS_URL signals config-error"
    (with-env (("PAPERLESS_URL" "")
               ("PAPERLESS_TOKEN" "tok")
               ("PASSWORD_CANDIDATES" "pw"))
      (ok (signals (make-config-from-env) 'config-error))))

  (testing "missing PAPERLESS_TOKEN signals config-error"
    (with-env (("PAPERLESS_URL" "https://x")
               ("PAPERLESS_TOKEN" "")
               ("PASSWORD_CANDIDATES" "pw"))
      (ok (signals (make-config-from-env) 'config-error))))

  (testing "missing PASSWORD_CANDIDATES signals config-error"
    (with-env (("PAPERLESS_URL" "https://x")
               ("PAPERLESS_TOKEN" "tok")
               ("PASSWORD_CANDIDATES" ""))
      (ok (signals (make-config-from-env) 'config-error))))

  (testing "provided-but-empty candidate list does NOT signal"
    (with-env (("PAPERLESS_URL" "https://x")
               ("PAPERLESS_TOKEN" "tok")
               ("PASSWORD_CANDIDATES" ",,"))
      (let ((cfg (make-config-from-env)))
        (ok (null (config-candidates cfg)))))))
