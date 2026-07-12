(in-package :unlocker.logging)

(defvar *log-level* :info)

(defparameter +level-ranks+
  '((:debug . 0) (:info . 1) (:warn . 2) (:error . 3)))

(defun log-level-keyword-p (x)
  (and (keywordp x) (assoc x +level-ranks+)))

(defun parse-log-level (string &optional (default :info))
  (if (null string)
      default
      (let ((kw (intern (string-upcase string) :keyword)))
        (if (log-level-keyword-p kw) kw default))))

(defun level-rank (level)
  (or (cdr (assoc level +level-ranks+))
      (error "Unknown log level ~A" level)))

(defmacro with-log-level (level &body body)
  `(let ((*log-level* ,level))
     ,@body))

(defun iso-timestamp ()
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour min sec)))

(defun format-message (level doc-id control args)
  (let ((body (apply #'format nil control args)))
    (if doc-id
        (format nil "~A [~A] doc=~A ~A" (iso-timestamp) level doc-id body)
        (format nil "~A [~A] ~A" (iso-timestamp) level body))))

(defun log-message (level doc-id format-string &rest args)
  (when (>= (level-rank level) (level-rank *log-level*))
    (fresh-line *standard-output*)
    (princ (format-message level doc-id format-string args) *standard-output*)
    (terpri *standard-output*)
    (finish-output *standard-output*))
  (values))

(defun log-debug (doc-id format-string &rest args)
  (apply #'log-message :debug doc-id format-string args))

(defun log-info (doc-id format-string &rest args)
  (apply #'log-message :info doc-id format-string args))

(defun log-warn (doc-id format-string &rest args)
  (apply #'log-message :warn doc-id format-string args))

(defun log-error (doc-id format-string &rest args)
  (apply #'log-message :error doc-id format-string args))
