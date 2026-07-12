(in-package :unlocker.main)

(defvar *stopping* nil)

(defun install-signal-handlers ()
  "Install SIGTERM/SIGINT handlers that request a graceful stop."
  #+sbcl
  (flet ((handler (signal)
           (declare (ignore signal))
           (setf *stopping* t)
           (unlocker.logging:log-info nil "stop requested; finishing current document.")))
    (let ((sigterm (ignore-errors sb-unix:sigterm))
          (sigint (ignore-errors sb-unix:sigint)))
      (when sigterm
        (sb-sys:enable-interrupt sigterm #'handler))
      (when sigint
        (sb-sys:enable-interrupt sigint #'handler)))))

(defun interruptible-sleep (seconds)
  (let ((end (+ (get-universal-time) seconds)))
    (loop until (or *stopping* (>= (get-universal-time) end))
          do (sleep 1))))

(defun metadata-plist (doc locked-tag-id)
  `(:title ,(unlocker.paperless:document-title doc)
    :correspondent ,(unlocker.paperless:document-correspondent doc)
    :document-type ,(unlocker.paperless:document-type doc)
    :created ,(unlocker.paperless:document-created doc)
    :tags ,(remove locked-tag-id (unlocker.paperless:document-tags doc))))

(defun handle-existing-replacement (client doc-id replacement)
  (unlocker.logging:log-info
   doc-id "replacement ~A already exists; deleting original only." replacement)
  (unlocker.paperless:delete-document client doc-id))

(defun handle-unlock-failed (client doc-id locked-tag-id failed-tag-id doc)
  (let ((new-tags (cons failed-tag-id
                        (remove locked-tag-id
                                (unlocker.paperless:document-tags doc)))))
    (unlocker.paperless:patch-document-tags client doc-id new-tags))
  (unlocker.logging:log-warn
   doc-id "could not unlock with any candidate; marked unlock-failed."))

(defun handle-unlock-ok (client doc-id locked-tag-id field-id doc unlocked)
  (let ((meta (metadata-plist doc locked-tag-id)))
    (unlocker.paperless:upload-document
     client unlocked (unlocker.paperless:document-filename doc)
     meta :field-id field-id :source-id doc-id)
    (unlocker.paperless:delete-document client doc-id)
    (unlocker.logging:log-info
     doc-id "unlocked, uploaded replacement, deleted original.")))

(defun process-locked-document (client doc-id locked-tag-id failed-tag-id
                                 field-id candidates)
  (let* ((doc (unlocker.paperless:get-document client doc-id))
         (bytes (unlocker.paperless:download-document client doc-id))
         (unlocked (unlocker.qpdf:unlock bytes candidates)))
    (cond
      ((null unlocked)
       (handle-unlock-failed client doc-id locked-tag-id failed-tag-id doc))
      (t
       (handle-unlock-ok client doc-id locked-tag-id field-id doc unlocked)))))

(defun handle-document (client doc-id locked-tag-id failed-tag-id
                        field-id index candidates)
  (handler-case
      (let ((replacement (gethash doc-id index)))
        (cond
          (replacement
           (handle-existing-replacement client doc-id replacement))
          (t
           (process-locked-document client doc-id locked-tag-id failed-tag-id
                                    field-id candidates))))
    (error (e)
      (unlocker.logging:log-error
       doc-id "transient error processing document, skipping: ~A" e))))

(defun run-cycle (client config)
  (handler-case
      (let* ((locked-tag-id (unlocker.paperless:ensure-tag
                             client (unlocker.config:config-locked-tag config)))
             (failed-tag-id (unlocker.paperless:ensure-tag
                             client (unlocker.config:config-unlock-failed-tag config)))
             (field-id (unlocker.paperless:ensure-custom-field
                        client "unlock-source-id" "integer"))
             (doc-ids (unlocker.paperless:list-docs-by-tag client locked-tag-id))
             (index (unlocker.paperless:build-lineage-index
                     client field-id doc-ids)))
        (unlocker.logging:log-info nil "cycle: ~A locked document(s)." (length doc-ids))
        (dolist (doc-id doc-ids)
          (unless *stopping*
            (handle-document client doc-id locked-tag-id failed-tag-id field-id
                             index (unlocker.config:config-candidates config)))))
    (error (e)
      (unlocker.logging:log-error
       nil "cycle-level error, will retry next cycle: [~A] ~A" (type-of e) e))))

(defun start ()
  (setf *stopping* nil)
  (install-signal-handlers)
  (let ((config (handler-case (unlocker.config:make-config-from-env)
                  (unlocker.config:config-error (e)
                    (format *error-output* "configuration error: ~A~%"
                            (unlocker.config:config-error-message e))
                    (sb-ext:exit :code 1)))))
    (setf unlocker.logging:*log-level* (unlocker.config:config-log-level config))
    (let ((client (unlocker.paperless:make-client
                   :url (unlocker.config:config-url config)
                   :token (unlocker.config:config-token config)
                   :http-timeout (unlocker.config:config-http-timeout config)
                   :skip-ssl (not (equal "" (or (uiop:getenv "SKIP_SSL_VERIFY") ""))))))
      (unlocker.logging:log-info nil "starting poll loop (interval ~As)."
                                 (unlocker.config:config-poll-interval config))
      (loop until *stopping*
            do (run-cycle client config)
               (unless *stopping*
                 (interruptible-sleep (unlocker.config:config-poll-interval config))))
      (unlocker.logging:log-info nil "stopping; exit 0.")
      (sb-ext:exit :code 0))))
