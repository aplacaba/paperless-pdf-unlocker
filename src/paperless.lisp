(in-package :unlocker.paperless)

(defstruct (client (:constructor make-client-raw))
  (url "" :type string)
  (token "" :type string)
  (http-timeout 30 :type (integer 1 3600))
  (http-fn (constantly (values 200 "")) :type function))

(defun join-url (base path)
  (if (and (>= (length path) 7)
           (or (string= path "http://" :end1 7)
               (string= path "https://" :end1 8)))
      path
      (let ((b (string-right-trim '(#\/) base))
            (p (string-left-trim '(#\/) path)))
        (concatenate 'string b "/" p))))

(defun make-real-http-fn (url token)
  (lambda (method path &key params content content-type want-bytes timeout multipart
           &allow-other-keys)
    (declare (ignore content-type timeout))
    (let* ((full-url (join-url url (concatenate 'string path
                                                (or (params-to-query params) ""))))
           (headers (list (cons "Authorization"
                                (format nil "Token ~A" token))
                          (cons "Accept" "application/json"))))
      (dexador:request full-url
                       :method method
                       :content (or multipart content)
                       :headers headers
                       :force-binary want-bytes
                       :use-connection-pool nil))))

(defun make-client (&key url token (http-timeout 30) (http-fn nil http-fn-supplied))
  (make-client-raw :url url
                   :token token
                   :http-timeout http-timeout
                   :http-fn (if http-fn-supplied http-fn (make-real-http-fn url token))))

(defun jget (plist key)
  (getf plist (intern key :keyword)))

(defun jobj (&rest key-values)
  (loop for (key value) on key-values by #'cddr
        append (list (intern key :keyword) value)))

(defun make-keyword (string)
  (intern string :keyword))

(defun results-of (data)
  (jget data "results"))

(defun next-page-of (data)
  (jget data "next"))

(defun params-to-query (params)
  (when params
    (format nil "?~{~A=~A~^&~}"
            (loop for (k . v) in params collect (list k v)))))

(defun call-json (client method path &key params content &allow-other-keys)
  (multiple-value-bind (status body)
      (funcall (client-http-fn client) method path
               :params params
               :content (when content (jonathan:to-json content))
               :content-type "application/json"
               :want-bytes nil
               :timeout (client-http-timeout client))
    (declare (ignore status))
    (if (or (null body) (string= body ""))
        nil
        (jonathan:parse body))))

(defun call-bytes (client method path &key params &allow-other-keys)
  (funcall (client-http-fn client) method path
           :params params
           :want-bytes t
           :timeout (client-http-timeout client)))

(defun resolve-tag-by-name (client name)
  (let* ((data (call-json client :get "/api/tags/"
                          :params `(("name__exact" . ,name)
                                    ("page_size" . "1"))))
         (hits (results-of data)))
    (when hits
      (jget (first hits) "id"))))

(defun ensure-tag (client name)
  (or (resolve-tag-by-name client name)
      (let ((data (call-json client :post "/api/tags/"
                             :content (jobj "name" name))))
        (jget data "id"))))

(defun list-docs-by-tag (client tag-id)
  (let ((all nil)
        (next (format nil "/api/documents/?tags__id__=~A&page_size=100" tag-id)))
    (loop while next
          do (let ((data (call-json client :get next)))
               (setf all (append all (mapcar (lambda (d) (jget d "id"))
                                             (results-of data))))
               (setf next (next-page-of data))))
    all))

(defun get-document (client doc-id)
  (call-json client :get (format nil "/api/documents/~A/" doc-id)))

(defun download-document (client doc-id)
  (nth-value 1 (call-bytes client :get
                           (format nil "/api/documents/~A/download/" doc-id))))

(defun delete-document (client doc-id)
  (nth-value 0
             (funcall (client-http-fn client)
                      :delete
                      (format nil "/api/documents/~A/" doc-id)
                      :timeout (client-http-timeout client))))

(defun patch-document-tags (client doc-id new-tags)
  (call-json client :patch (format nil "/api/documents/~A/" doc-id)
             :content (jobj "tags" new-tags)))

(defun patch-document-custom-field (client doc-id field-id value)
  (call-json client :patch (format nil "/api/documents/~A/" doc-id)
             :content (jobj "custom_fields"
                            (list (jobj "field" field-id "value" value)))))

(defun custom-field-id-by-name (client name)
  (let* ((params `(("name__exact" . ,name) ("page_size" . "100")))
         (data (call-json client :get "/api/custom_fields/" :params params)))
    (loop for entry in (results-of data)
          when (string= (jget entry "name") name)
            return (jget entry "id"))))

(defun ensure-custom-field (client name data-type)
  (or (custom-field-id-by-name client name)
      (let ((data (call-json client :post "/api/custom_fields/"
                             :content (jobj "name" name
                                            "data_type" data-type))))
        (jget data "id"))))

(defun replacement-for (client field-id source-id)
  (let* ((param (cons (format nil "custom_field_~A" field-id)
                      (princ-to-string source-id)))
         (data (call-json client :get "/api/documents/"
                          :params (list param (cons "page_size" "1"))))
         (hits (results-of data)))
    (when hits
      (jget (first hits) "id"))))

(defun build-lineage-index (client field-id source-ids)
  (let ((table (make-hash-table :test #'eql)))
    (dolist (source-id source-ids table)
      (let ((rep (replacement-for client field-id source-id)))
        (when rep
          (setf (gethash source-id table) rep))))))

(defun document-tags (doc)
  (let ((tags (jget doc "tags")))
    (if (listp tags) tags (list tags))))

(defun document-title (doc) (jget doc "title"))
(defun document-correspondent (doc) (jget doc "correspondent"))
(defun document-type (doc) (jget doc "document_type"))
(defun document-created (doc) (jget doc "created"))
(defun document-filename (doc)
  (or (jget doc "original_filename") "document.pdf"))

(defun build-upload-parts (bytes filename metadata-plist field-id source-id)
  (let ((parts nil))
    (push `("document" ,bytes :filename ,filename :content-type "application/pdf")
          parts)
    (push `("title" ,(getf metadata-plist :title)) parts)
    (let ((created (getf metadata-plist :created)))
      (when created (push `("created" ,created) parts)))
    (let ((corr (getf metadata-plist :correspondent)))
      (when corr (push `("correspondent" ,(princ-to-string corr)) parts)))
    (let ((dtype (getf metadata-plist :document-type)))
      (when dtype (push `("document_type" ,(princ-to-string dtype)) parts)))
    (dolist (tag (getf metadata-plist :tags))
      (push `("tags" ,(princ-to-string tag)) parts))
    (when (and field-id source-id)
      (push `("custom_fields"
              ,(jonathan:to-json
                (list (jobj "field" field-id "value" source-id))))
            parts))
    (nreverse parts)))

(defun upload-document (client bytes filename metadata-plist
                        &key field-id source-id)
  "Upload via post_document (async consumption). Returns the parsed response.

Open Q1/Q3 (verified against the real instance in task group 8): whether metadata
+ the custom field are applied during consumption or require a follow-up PATCH,
and the exact multipart field names. The caller is responsible for confirming the
new document's id and patching the lineage field if needed."
  (let ((parts (build-upload-parts bytes filename metadata-plist
                                   field-id source-id)))
    (multiple-value-bind (status body)
        (funcall (client-http-fn client)
                 :post "/api/documents/post_document/"
                 :multipart parts
                 :want-bytes nil
                 :timeout (client-http-timeout client))
      (declare (ignore status))
      (if (or (null body) (string= body ""))
          nil
          (jonathan:parse body)))))

(defun task-result-document-id (task-data)
  (or (jget task-data "result")
      (jget task-data "related_document")
      (jget task-data "document")))

(defun get-task (client task-id)
  (call-json client :get (format nil "/api/tasks/~A/" task-id)))
