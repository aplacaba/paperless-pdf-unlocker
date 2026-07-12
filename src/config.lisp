(in-package :unlocker.config)

(define-condition config-error (error)
  ((message :initarg :message :reader config-error-message))
  (:report (lambda (c stream)
             (write-string (config-error-message c) stream))))

(defstruct config
  (url nil :type (or null string))
  (token nil :type (or null string))
  (candidates nil :type list)
  (locked-tag "locked" :type string)
  (unlock-failed-tag "unlock-failed" :type string)
  (poll-interval 60 :type (integer 1 86400))
  (http-timeout 30 :type (integer 1 3600))
  (log-level :info :type keyword))

(defun trim (string)
  (string-trim '(#\Space #\Tab #\Newline #\Return) string))

(defun parse-candidates (string)
  (let ((normalized (substitute-if #\,
                                   (lambda (c) (or (char= c #\Newline)
                                                   (char= c #\Return)))
                                   string)))
    (remove-if (lambda (s) (string= s ""))
               (mapcar #'trim (split-sequence-on-char normalized #\,)))))

(defun split-sequence-on-char (string char)
  (let ((parts nil)
        (start 0))
    (loop for i from 0 below (length string)
          when (char= (char string i) char)
            do (push (subseq string start i) parts)
               (setf start (1+ i))
          finally (push (subseq string start) parts))
    (nreverse parts)))

(defun env (name)
  (uiop:getenv name))

(defun env-or-default (name default)
  (let ((value (env name)))
    (if (or (null value) (string= value ""))
        default
        value)))

(defun parse-integer-env (name default)
  (let ((raw (env name)))
    (if (null raw)
        default
        (multiple-value-bind (n end) (parse-integer raw :junk-allowed t)
          (cond
            ((and n (= end (length raw)) (plusp n)) n)
            (t default))))))

(defun missing-required-p (raw)
  (or (null raw) (string= raw "")))

(defun make-config-from-env ()
  (let ((url (env "PAPERLESS_URL"))
        (token (env "PAPERLESS_TOKEN"))
        (raw-candidates (env "PASSWORD_CANDIDATES")))
    (cond
      ((missing-required-p url)
       (error 'config-error
              :message "PAPERLESS_URL is required and must be non-empty."))
      ((missing-required-p token)
       (error 'config-error
              :message "PAPERLESS_TOKEN is required and must be non-empty."))
      ((missing-required-p raw-candidates)
       (error 'config-error
              :message "PASSWORD_CANDIDATES is required and must be non-empty.")))
    (let ((candidates (parse-candidates raw-candidates)))
      (unless candidates
        (unlocker.logging:log-warn
         nil
         "PASSWORD_CANDIDATES parsed to an empty list; every locked document ~
          will be tagged ~A."
         (env-or-default "UNLOCK_FAILED_TAG" "unlock-failed")))
      (make-config
       :url url
       :token token
       :candidates candidates
       :locked-tag (env-or-default "LOCKED_TAG" "locked")
       :unlock-failed-tag (env-or-default "UNLOCK_FAILED_TAG" "unlock-failed")
       :poll-interval (parse-integer-env "POLL_INTERVAL_SECONDS" 60)
       :http-timeout (parse-integer-env "HTTP_TIMEOUT_SECONDS" 30)
       :log-level (unlocker.logging:parse-log-level (env "LOG_LEVEL") :info)))))
