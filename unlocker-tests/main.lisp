(defpackage unlocker-tests/main
  (:use :cl :rove)
  (:import-from :unlocker.main #:run-cycle #:*stopping*))
(in-package :unlocker-tests/main)

(defstruct recorder
  uploads deletions patches)

(defmacro with-stubs (bindings &body body)
  (let ((saves (loop for (fn) in bindings collect (gensym (symbol-name fn)))))
    `(let ,(loop for sv in saves collect sv)
       (unwind-protect
            (progn
              ,@(loop for (fn repl) in bindings for sv in saves
                      collect `(setf ,sv (fdefinition ',fn))
                      collect `(setf (fdefinition ',fn) ,repl))
              ,@body)
         ,@(loop for (fn) in bindings for sv in saves
                 collect `(setf (fdefinition ',fn) ,sv))))))

(defun dummy-config (&key (candidates (list "pw")))
  (unlocker.config:make-config
   :url "https://x" :token "t" :candidates candidates
   :locked-tag "locked" :unlock-failed-tag "unlock-failed"
   :poll-interval 1 :http-timeout 5 :log-level :error))

(defun dummy-client ()
  (unlocker.paperless:make-client :url "https://x" :token "t" :http-timeout 5))

(deftest cycle-success-path
  (testing "unlock ok -> upload + delete; no patch"
    (let ((rec (make-recorder))
          (*stopping* nil))
      (with-stubs
          ((unlocker.paperless:ensure-tag
            (lambda (client name) (declare (ignore client))
             (cond ((string= name "locked") 1)
                   ((string= name "unlock-failed") 2))))
           (unlocker.paperless:list-docs-by-tag
            (lambda (client tag-id) (declare (ignore client tag-id)) (list 100)))
           (unlocker.paperless:get-document
            (lambda (client id) (declare (ignore client id))
             (unlocker.paperless::jobj "id" 100 "title" "T" "tags" (list 1 9)
                                       "original_filename" "f.pdf")))
           (unlocker.paperless:download-document
            (lambda (client id) (declare (ignore client id))
             (make-array 4 :element-type '(unsigned-byte 8) :initial-contents #(1 2 3 4))))
           (unlocker.qpdf:unlock
            (lambda (bytes candidates) (declare (ignore bytes candidates))
             (make-array 2 :element-type '(unsigned-byte 8) :initial-contents #(9 9))))
           (unlocker.paperless:patch-document-tags
            (lambda (client id tags) (declare (ignore client id tags))
             (push :called (recorder-patches rec))))
           (unlocker.paperless:upload-document
            (lambda (client bytes filename meta) (declare (ignore client bytes filename meta))
             (push :called (recorder-uploads rec))))
           (unlocker.paperless:delete-document
            (lambda (client id) (declare (ignore client id))
             (push :called (recorder-deletions rec)))))
        (run-cycle (dummy-client) (dummy-config)))
      (ok (member :called (recorder-uploads rec)))
      (ok (member :called (recorder-deletions rec)))
      (ok (not (recorder-patches rec))))))

(deftest cycle-all-candidates-fail
  (testing "unlock nil -> patch (swap tags); no upload, no delete"
    (let ((rec (make-recorder))
          (*stopping* nil))
      (with-stubs
          ((unlocker.paperless:ensure-tag
            (lambda (client name) (declare (ignore client))
             (cond ((string= name "locked") 1)
                   ((string= name "unlock-failed") 2))))
           (unlocker.paperless:list-docs-by-tag
            (lambda (client tag-id) (declare (ignore client tag-id)) (list 100)))
           (unlocker.paperless:get-document
            (lambda (client id) (declare (ignore client id))
             (unlocker.paperless::jobj "id" 100 "title" "T" "tags" (list 1 9))))
           (unlocker.paperless:download-document
            (lambda (client id) (declare (ignore client id))
             (make-array 1 :element-type '(unsigned-byte 8) :initial-contents #(1))))
           (unlocker.qpdf:unlock
            (lambda (bytes candidates) (declare (ignore bytes candidates)) nil))
           (unlocker.paperless:patch-document-tags
            (lambda (client id tags) (declare (ignore client id tags))
             (push :called (recorder-patches rec))))
           (unlocker.paperless:upload-document
            (lambda (client bytes filename meta) (declare (ignore client bytes filename meta))
             (push :called (recorder-uploads rec))))
           (unlocker.paperless:delete-document
            (lambda (client id) (declare (ignore client id))
             (push :called (recorder-deletions rec)))))
        (run-cycle (dummy-client) (dummy-config)))
      (ok (member :called (recorder-patches rec)))
      (ok (not (recorder-uploads rec)))
      (ok (not (recorder-deletions rec))))))

(deftest cycle-per-document-transient-error
  (testing "an error on one document is contained; others still processed"
    (let ((processed nil)
          (*stopping* nil))
      (with-stubs
          ((unlocker.paperless:ensure-tag
            (lambda (client name) (declare (ignore client))
             (cond ((string= name "locked") 1)
                   ((string= name "unlock-failed") 2))))
           (unlocker.paperless:list-docs-by-tag
            (lambda (client tag-id) (declare (ignore client tag-id)) (list 100 101)))
           (unlocker.paperless:get-document
            (lambda (client id) (declare (ignore client id))
             (push id processed)
             (if (= id 100)
                 (error "boom on 100")
                 (unlocker.paperless::jobj "id" 101 "title" "T" "tags" (list 1 9)))))
           (unlocker.paperless:download-document
            (lambda (client id) (declare (ignore client id))
             (make-array 1 :element-type '(unsigned-byte 8) :initial-contents #(1))))
           (unlocker.qpdf:unlock
            (lambda (bytes candidates) (declare (ignore bytes candidates))
             (make-array 1 :element-type '(unsigned-byte 8) :initial-contents #(9))))
           (unlocker.paperless:patch-document-tags
            (lambda (client id tags) (declare (ignore client id tags))))
           (unlocker.paperless:upload-document
            (lambda (client bytes filename meta) (declare (ignore client bytes filename meta))))
           (unlocker.paperless:delete-document
            (lambda (client id) (declare (ignore client id)))))
        (run-cycle (dummy-client) (dummy-config)))
      (ok (member 100 processed))
      (ok (member 101 processed)))))

(deftest cycle-level-error-contained
  (testing "a cycle-level error does not crash run-cycle"
    (let ((*stopping* nil))
      (with-stubs
          ((unlocker.paperless:ensure-tag
            (lambda (client name) (declare (ignore client name))
             (error "instance down"))))
        (ok (not (nth-value 1 (ignore-errors (run-cycle (dummy-client) (dummy-config))))))))))

(deftest stop-between-documents
  (testing "a stop requested after the first document skips the rest"
    (let ((processed nil)
          (*stopping* nil))
      (with-stubs
          ((unlocker.paperless:ensure-tag
            (lambda (client name) (declare (ignore client name))
             (cond ((string= name "locked") 1)
                   ((string= name "unlock-failed") 2))))
           (unlocker.paperless:list-docs-by-tag
            (lambda (client tag-id) (declare (ignore client tag-id)) (list 100 101)))
           (unlocker.paperless:get-document
            (lambda (client id) (declare (ignore client id))
             (push id processed)
             (when (= id 100) (setf *stopping* t))
             (unlocker.paperless::jobj "id" id "title" "T" "tags" (list 1 9))))
           (unlocker.paperless:download-document
            (lambda (client id) (declare (ignore client id))
             (make-array 1 :element-type '(unsigned-byte 8) :initial-contents #(1))))
           (unlocker.qpdf:unlock
            (lambda (bytes candidates) (declare (ignore bytes candidates))
             (make-array 1 :element-type '(unsigned-byte 8) :initial-contents #(9))))
           (unlocker.paperless:patch-document-tags
            (lambda (client id tags) (declare (ignore client id tags))))
           (unlocker.paperless:upload-document
            (lambda (client bytes filename meta) (declare (ignore client bytes filename meta))))
           (unlocker.paperless:delete-document
            (lambda (client id) (declare (ignore client id)))))
        (run-cycle (dummy-client) (dummy-config)))
      (ok (member 100 processed))
      (ok (not (member 101 processed))))))
