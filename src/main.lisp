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

(defun handle-document (client doc-id locked-tag-id failed-tag-id candidates)
  (handler-case
      (let* ((doc (unlocker.paperless:get-document client doc-id))
             (bytes (unlocker.paperless:download-document client doc-id))
             (unlocked (unlocker.qpdf:unlock bytes candidates)))
        (if (null unlocked)
            (progn
              (let ((new-tags (cons failed-tag-id
                                    (remove locked-tag-id
                                            (unlocker.paperless:document-tags doc)))))
                (unlocker.paperless:patch-document-tags client doc-id new-tags))
              (unlocker.logging:log-warn
               doc-id "could not unlock; marked unlock-failed."))
             (progn
               (let* ((meta (metadata-plist doc locked-tag-id))
                      (resp (unlocker.paperless:upload-document
                             client unlocked (unlocker.paperless:document-filename doc) meta))
                      (new-id (unlocker.paperless:wait-for-document-id client resp 30))
                      (clean-tags (remove locked-tag-id (unlocker.paperless:document-tags doc))))
                 (when (and new-id clean-tags)
                   ;; Belt-and-suspenders: ensure the locked tag is not on the replacement
                   (unlocker.paperless:patch-document-tags client new-id clean-tags))
                 (unlocker.paperless:delete-document client doc-id)
                 (unlocker.logging:log-info
                  doc-id "unlocked, uploaded replacement~A, deleted original."
                   (if new-id (format nil " (id=~A)" new-id) ""))))))
    (error (e)
      (unlocker.logging:log-error
       doc-id "transient error processing document, skipping: ~A" e))))

(defun run-cycle (client config)
  (handler-case
      (let* ((locked-tag-id (unlocker.paperless:ensure-tag
                             client (unlocker.config:config-locked-tag config)))
             (failed-tag-id (unlocker.paperless:ensure-tag
                             client (unlocker.config:config-unlock-failed-tag config)))
             (doc-ids (unlocker.paperless:list-docs-by-tag client locked-tag-id)))
        (unlocker.logging:log-info nil "cycle: ~A locked document(s)." (length doc-ids))
        (dolist (doc-id doc-ids)
          (unless *stopping*
            (handle-document client doc-id locked-tag-id failed-tag-id
                             (unlocker.config:config-candidates config)))))
    (error (e)
      (unlocker.logging:log-error
       nil "cycle-level error, will retry next cycle: [~A] ~A" (type-of e) e))))

(defun hex-dump (bytes max-len)
  (let* ((len (min (length bytes) max-len))
         (s (make-string-output-stream)))
    (loop for i below len
          for b = (aref bytes i)
          when (zerop (mod i 16)) do (format s "~%  ~4,'0X  " i)
          do (format s "~2,'0X " b)
          when (and (> len 16) (= (mod (1+ i) 8) 0)) do (format s " "))
    (get-output-stream-string s)))

(defun diagnose-connection (url skip-ssl)
  (handler-case
      (let* ((https-p (or (and (>= (length url) 8)
                               (string= url "https://" :end1 8))
                          (and (>= (length url) 7)
                               (string= url "http://" :end1 7))))
             (after-scheme (cond
                             ((and (>= (length url) 8)
                                   (string= url "https://" :end1 8))
                              (subseq url 8))
                             ((and (>= (length url) 7)
                                   (string= url "http://" :end1 7))
                              (subseq url 7))
                             (t url)))
             (slash (position #\/ after-scheme))
             (host (string-right-trim '(#\:)
                                     (if slash
                                         (subseq after-scheme 0 slash)
                                         after-scheme)))
             (port (let ((colon (position #\: host)))
                     (if colon
                         (parse-integer (subseq host (1+ colon)))
                         (if https-p 443 80))))
             (hostname (let ((colon (position #\: host)))
                         (if colon (subseq host 0 colon) host)))
             (path (if slash (subseq after-scheme slash) "/"))
             (socket (usocket:socket-connect hostname port
                                              :element-type '(unsigned-byte 8)))
             (stream (if https-p
                         (cl+ssl:make-ssl-client-stream
                          (usocket:socket-stream socket)
                          :verify (not skip-ssl)
                          :hostname hostname)
                         (usocket:socket-stream socket)))
        (req (format nil "GET /api/ HTTP/1.1~C~CHost: ~A~C~CAccept: */*~C~CConnection: close~C~C~C~C"
                           #\Return #\Newline hostname #\Return #\Newline
                           #\Return #\Newline #\Return #\Newline
                           #\Return #\Newline)))
        (unlocker.logging:log-info nil "diagnostic: connecting to ~A:~A~A" hostname port path)
        (write-sequence (map 'vector #'char-code req) stream)
        (force-output stream)
        (let ((buf (make-array 512 :element-type '(unsigned-byte 8))))
          (let ((n (handler-case (read-sequence buf stream)
                     (end-of-file () 0)
                     (t () 0))))
            (unlocker.logging:log-info nil "diagnostic: read ~A bytes from server" n)
            (unlocker.logging:log-info nil "diagnostic raw bytes: ~A" (hex-dump buf n))
            (unlocker.logging:log-info nil "diagnostic ascii: ~A"
                                       (map 'string #'code-char (subseq buf 0 n)))))
        (usocket:socket-close socket)
        (unlocker.logging:log-info nil "diagnostic: complete."))
    (error (e)
      (unlocker.logging:log-error nil "diagnostic failed: ~A" e))))

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
      (diagnose-connection (unlocker.config:config-url config)
                           (not (equal "" (or (uiop:getenv "SKIP_SSL_VERIFY") ""))))
      (loop until *stopping*
            do (run-cycle client config)
               (unless *stopping*
                 (interruptible-sleep (unlocker.config:config-poll-interval config))))
      (unlocker.logging:log-info nil "stopping; exit 0.")
      (sb-ext:exit :code 0))))
