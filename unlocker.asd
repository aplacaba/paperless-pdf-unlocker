(asdf:defsystem "unlocker"
  :version "0.1.0"
  :description "Poll Paperless-ngx for encrypted PDFs, decrypt with qpdf, replace."
  :license "MIT"
  :depends-on ("dexador"
               "jonathan"
               "uiop")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "logging")
                             (:file "config")
                             (:file "qpdf")
                             (:file "paperless")
                             (:file "main"))))
  :in-order-to ((test-op (test-op "unlocker/tests"))))

(asdf:defsystem "unlocker/tests"
  :description "Tests for unlocker (Rove)."
  :depends-on ("unlocker" "rove")
  :serial t
  :components ((:module "unlocker-tests"
                :serial t
                :components ((:file "packages")
                             (:file "config")
                             (:file "logging")
                             (:file "qpdf")
                             (:file "paperless")
                             (:file "main"))))
  :perform (test-op (o c)
             (uiop:symbol-call :rove :run :unlocker/tests)))
