(in-package :cl-user)

(defpackage :unlocker.logging
  (:use :cl)
  (:export #:*log-level*
           #:parse-log-level
           #:log-level-keyword-p
           #:log-message
           #:log-debug
           #:log-info
           #:log-warn
           #:log-error
           #:with-log-level))

(defpackage :unlocker.config
  (:use :cl)
  (:export #:config
           #:config-error
           #:config-error-message
           #:make-config
           #:make-config-from-env
           #:config-url
           #:config-token
           #:config-candidates
           #:config-locked-tag
           #:config-unlock-failed-tag
           #:config-poll-interval
           #:config-http-timeout
           #:config-log-level
           #:parse-candidates))

(defpackage :unlocker.qpdf
  (:use :cl)
  (:export #:unlock
           #:qpdf-decrypt-error))

(defpackage :unlocker.paperless
  (:use :cl)
  (:export #:client
           #:make-client
           #:client-url
           #:client-token
           #:client-http-timeout
           #:client-http-fn
           #:ensure-tag
           #:resolve-tag-by-name
           #:list-docs-by-tag
           #:get-document
           #:download-document
           #:delete-document
           #:patch-document-tags
           #:patch-document-custom-field
           #:upload-document
           #:ensure-custom-field
           #:replacement-for
           #:build-lineage-index
           #:document-title
           #:document-correspondent
           #:document-type
           #:document-created
           #:document-tags
   #:document-filename
   #:get-task
   #:task-result-document-id
   #:wait-for-document-id))

(defpackage :unlocker.main
  (:use :cl)
  (:export #:start
           #:run-cycle
           #:*stopping*))
