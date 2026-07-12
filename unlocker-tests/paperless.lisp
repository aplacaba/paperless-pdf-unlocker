(defpackage unlocker-tests/paperless
  (:use :cl :rove :unlocker.paperless))
(in-package :unlocker-tests/paperless)

(defstruct fake-state
  (tag-table (make-hash-table :test #'equal))   ; name -> id
  (next-tag-id 100)
  (field-table (make-hash-table :test #'equal)) ; name -> id
  (next-field-id 200)
  (replacement-table (make-hash-table :test #'eql)) ; source-id -> replacement-id
  (seen-timeouts nil))

(defun make-fake-http-fn (state)
  (lambda (method path &key params content content-type want-bytes timeout multipart)
    (declare (ignore content content-type want-bytes multipart))
    (when timeout (push timeout (fake-state-seen-timeouts state)))
    (cond
      ((and (eq method :get) (search "/api/tags/" path))
       (let* ((name (cdr (assoc "name__exact" params :test #'string=)))
              (id (and name (gethash name (fake-state-tag-table state)))))
         (values 200
                 (jonathan:to-json
                  (if id
                      (unlocker.paperless::jobj "results"
                        (list (unlocker.paperless::jobj "id" id "name" name)))
                      (unlocker.paperless::jobj "results" nil))))))
      ((and (eq method :post) (string= path "/api/tags/"))
       (let* ((plist (jonathan:parse content))
              (name (getf plist (intern "name" :keyword)))
              (id (incf (fake-state-next-tag-id state))))
         (setf (gethash name (fake-state-tag-table state)) id)
         (values 201 (jonathan:to-json
                      (unlocker.paperless::jobj "id" id "name" name)))))
      ((and (eq method :get) (search "/api/custom_fields/" path))
       (let* ((name (cdr (assoc "name__exact" params :test #'string=)))
              (id (and name (gethash name (fake-state-field-table state)))))
         (values 200
                 (jonathan:to-json
                  (if id
                      (unlocker.paperless::jobj "results"
                        (list (unlocker.paperless::jobj "id" id "name" name)))
                      (unlocker.paperless::jobj "results" nil))))))
      ((and (eq method :post) (string= path "/api/custom_fields/"))
       (let* ((plist (jonathan:parse content))
              (name (getf plist (intern "name" :keyword)))
              (id (incf (fake-state-next-field-id state))))
         (setf (gethash name (fake-state-field-table state)) id)
         (values 201 (jonathan:to-json
                      (unlocker.paperless::jobj "id" id "name" name)))))
      ((and (eq method :get) (search "/api/documents/" path)
             (find-if (lambda (c) (search "custom_field_" (car c))) params))
       ;; replacement-for lookup: extract source-id from params
       (let* ((pair (find-if (lambda (c) (search "custom_field_" (car c))) params))
              (source-id (parse-integer (cdr pair))))
         (multiple-value-bind (rep foundp)
             (gethash source-id (fake-state-replacement-table state))
           (values 200
                   (jonathan:to-json
                    (if foundp
                        (unlocker.paperless::jobj "results"
                          (list (unlocker.paperless::jobj "id" rep)))
                        (unlocker.paperless::jobj "results" nil)))))))
      (t
       (values 200 "{}")))))

(deftest ensure-tag
  (testing "creates a missing tag, then reuses it"
    (let* ((state (make-fake-state))
           (fn (make-fake-http-fn state))
           (client (make-client :url "https://x" :token "t"
                                :http-timeout 7 :http-fn fn)))
      (let ((id1 (ensure-tag client "locked")))
        (ok id1)
        ;; second call should resolve the existing one (no new create)
        (let ((id2 (ensure-tag client "locked")))
          (ok (eql id1 id2))
          (ok (eql (fake-state-next-tag-id state) 101)))))))

(deftest ensure-custom-field
  (testing "creates a missing field, then reuses it"
    (let* ((state (make-fake-state))
           (fn (make-fake-http-fn state))
           (client (make-client :url "https://x" :token "t" :http-fn fn)))
      (let ((id1 (ensure-custom-field client "unlock-source-id" "integer")))
        (ok id1)
        (ok (eql (ensure-custom-field client "unlock-source-id" "integer") id1))))))

(deftest lineage-index
  (testing "maps source-ids that have a replacement"
    (let* ((state (make-fake-state))
           (fn (make-fake-http-fn state))
           (client (make-client :url "https://x" :token "t" :http-fn fn)))
      (setf (gethash 11 (fake-state-replacement-table state)) 99)
      (let ((index (build-lineage-index client 5 (list 10 11 12))))
        (ok (null (gethash 10 index)))
        (ok (eql (gethash 11 index) 99))
        (ok (null (gethash 12 index)))))))

(deftest http-timeout-forwarded
  (testing "the configured timeout is forwarded to each call"
    (let* ((state (make-fake-state))
           (fn (make-fake-http-fn state))
           (client (make-client :url "https://x" :token "t"
                                :http-timeout 42 :http-fn fn)))
      (ensure-tag client "locked")
      (ok (member 42 (fake-state-seen-timeouts state))))))
