(defpackage unlocker-tests/qpdf
  (:use :cl :rove :unlocker.qpdf))
(in-package :unlocker-tests/qpdf)

(defparameter +fixture+
  (merge-pathnames "unlocker-tests/fixtures/sample.pdf"
                   (asdf:system-source-directory :unlocker)))

(defun read-file-bytes (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((buf (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence buf s)
      buf)))

(defun write-file-bytes (path bytes)
  (with-open-file (s path :direction :output :if-exists :supersede
                     :element-type '(unsigned-byte 8))
    (write-sequence bytes s)))

(defun temp-pdf (name)
  (merge-pathnames (make-pathname :name name :type "pdf")
                   (uiop:temporary-directory)))

(defun make-encrypted-copy (source-path user-password &optional (owner-password "owner"))
  (let ((enc-path (temp-pdf "enc-sample")))
    (uiop:run-program
     (list "qpdf" "--encrypt" user-password owner-password "256" "--"
           (namestring source-path) (namestring enc-path))
     :output :string :error-output :string)
    enc-path))

(defun qpdf-check-ok-p (bytes)
  (let ((probe (temp-pdf "probe")))
    (write-file-bytes probe bytes)
    (eql 0 (nth-value 2 (uiop:run-program
                         (list "qpdf" "--check" (namestring probe))
                         :output :string :error-output :string
                         :ignore-error-status t)))))

(deftest unlock
  (testing "correct candidate returns unlocked bytes"
    (let* ((enc (make-encrypted-copy +fixture+ "rightpw"))
           (bytes (read-file-bytes enc))
           (unlocked (unlock bytes (list "wrong" "rightpw") :qpdf-path "qpdf")))
      (ok unlocked)
      (ok (and unlocked (> (length unlocked) 0)))
      (ok (and unlocked (qpdf-check-ok-p unlocked)))))

  (testing "no matching candidate returns nil"
    (let ((bytes (read-file-bytes (make-encrypted-copy +fixture+ "rightpw"))))
      (ok (null (unlock bytes (list "wrong1" "wrong2") :qpdf-path "qpdf")))))

  (testing "order: returns first successful candidate"
    (let ((bytes (read-file-bytes (make-encrypted-copy +fixture+ "rightpw"))))
      (ok (unlock bytes (list "rightpw" "alsoright") :qpdf-path "qpdf"))))

  (testing "empty candidate list returns nil"
    (let ((bytes (read-file-bytes +fixture+)))
      (ok (null (unlock bytes nil :qpdf-path "qpdf")))))

  (testing "malformed input returns nil (no raise)"
    (let ((garbage (make-array 16 :element-type '(unsigned-byte 8)
                                 :initial-contents (loop for i below 16 collect i))))
      (ok (null (unlock garbage (list "any") :qpdf-path "qpdf")))))

  (testing "missing qpdf binary returns nil (no raise)"
    (let ((bytes (read-file-bytes +fixture+)))
      (ok (null (unlock bytes (list "any") :qpdf-path "qpdf-does-not-exist-xyz"))))))
