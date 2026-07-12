(in-package :unlocker.qpdf)

(define-condition qpdf-decrypt-error (error) ())

(defparameter +default-qpdf-path+ "qpdf")

(defun write-bytes (path bytes)
  (with-open-file (stream path
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create
                          :element-type '(unsigned-byte 8))
    (write-sequence bytes stream)))

(defun read-bytes (path)
  (with-open-file (stream path
                          :direction :input
                          :if-does-not-exist :error
                          :element-type '(unsigned-byte 8))
    (let* ((length (file-length stream))
           (buffer (make-array length :element-type '(unsigned-byte 8))))
      (read-sequence buffer stream)
      buffer)))

(defun temp-path (suffix)
  (let ((dir (or (uiop:getenv "TMPDIR") "/tmp")))
    (format nil "~A/unlocker-~A-~A-~A.pdf"
            (string-right-trim '(#\/) dir)
            (get-universal-time)
            (random 1000000)
            suffix)))

(defun run-qpdf (qpdf-path password in-path out-path)
  "Run qpdf once. Return (values ok-p stderr)."
  (handler-case
      (multiple-value-bind (stdout stderr code)
          (uiop:run-program
           (list qpdf-path
                 (format nil "--password=~A" password)
                 "--decrypt"
                 in-path
                 out-path)
           :output :string
           :error-output :string
           :ignore-error-status t)
        (declare (ignore stdout))
        (values (= code 0) stderr))
    (error ()
      (values nil "qpdf invocation raised an error"))))

(defun unlock (bytes candidates &key (qpdf-path +default-qpdf-path+))
  "Return unlocked BYTES using the first working candidate, or NIL."
  (when (null candidates)
    (return-from unlock nil))
  (let ((in-path (temp-path "in"))
        (out-path (temp-path "out"))
        (last-err nil))
    (unwind-protect
         (progn
           (write-bytes in-path bytes)
           (loop for candidate in candidates
                 do (multiple-value-bind (ok stderr) (run-qpdf qpdf-path
                                                               candidate
                                                               in-path
                                                               out-path)
                      (cond
                        (ok
                         (unlocker.logging:log-debug
                          nil "qpdf unlocked with a candidate.")
                         (return-from unlock (read-bytes out-path)))
                        (t
                         (setf last-err stderr)
                         (unlocker.logging:log-debug
                          nil "qpdf candidate failed: ~A" (string-trim
                                                           '(#\Newline #\Return)
                                                           (or stderr ""))))))
                 finally
                    (unlocker.logging:log-warn
                     nil "no candidate unlocked the document (last qpdf error: ~A)"
                     (string-trim '(#\Newline #\Return) (or last-err "")))
                    (return-from unlock nil)))
      (when (probe-file in-path) (delete-file in-path))
      (when (probe-file out-path) (delete-file out-path)))))
