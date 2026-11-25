(in-package :cl-tpg)

(defun assert-factored-action-test (condition format-control &rest arguments)
  (unless condition
    (error (apply #'format nil format-control arguments))))

(defun run-factored-action-tests ()
  "Exercise categorical initialization, mutation, and checkpoint syntax."
  (let ((*factored-actions-enabled* t)
        (*num-actions* +num-semantic-targets+))
    (dotimes (i 200)
      (let ((payload (make-random-atomic-action-value)))
        (assert-factored-action-test
         (and (factored-action-p payload)
              (<= 0 (factored-action-primary payload) 10)
              (<= 0 (factored-action-secondary payload) 3))
         "Invalid random factored payload: ~S" payload)))

    (let* ((payload (make-factored-action :primary 7 :secondary 3))
           (encoded (serialize-atomic-action-value payload))
           (decoded (deserialize-factored-action encoded)))
      (assert-factored-action-test
       (equal encoded '(:factored-action :primary 7 :secondary 3))
       "Unexpected factored serialization: ~S" encoded)
      (assert-factored-action-test
       (and (= (factored-action-primary decoded) 7)
            (= (factored-action-secondary decoded) 3))
       "Factored round trip failed: ~S" decoded))

    (let* ((action (make-action
                    :type :atomic
                    :action (make-factored-action :primary 2 :secondary 0)))
           (serialized (serialize-action action (make-hash-table)))
           (restored (deserialize-action serialized (make-hash-table)))
           (payload (action-action restored)))
      (assert-factored-action-test
       (and (factored-action-p payload)
            (= (factored-action-primary payload) 2)
            (= (factored-action-secondary payload) 0))
       "Atomic action serialization failed: ~S" serialized))

    (let* ((serialized '(:type :atomic :action 9))
           (restored (deserialize-action serialized (make-hash-table))))
      (assert-factored-action-test
       (= (action-action restored) 9)
       "Legacy integer action no longer deserializes: ~S" restored))

    (let* ((original (make-factored-action :primary 5 :secondary 2))
           (mutated (mutate-factored-atomic-value original)))
      (assert-factored-action-test
       (and (or (/= (factored-action-primary original)
                    (factored-action-primary mutated))
                (/= (factored-action-secondary original)
                    (factored-action-secondary mutated)))
            (<= 0 (factored-action-primary mutated) 10)
            (<= 0 (factored-action-secondary mutated) 3))
       "Factored mutation did not change one valid category: ~S" mutated))

    (let* ((registers (make-array +num-registers+
                                  :element-type 'double-float
                                  :initial-element 0.0d0))
           (semantic
             (make-semantic-action-from-terminal
              (make-factored-action :primary 4 :secondary 1)
              registers)))
      (assert-factored-action-test
       (and (= (semantic-action-target semantic) 4)
            (eq (semantic-action-response semantic) :remove)
            (null (semantic-action-option semantic)))
       "Categorical semantic decoding failed: ~S" semantic))

    (let* ((registers (make-array +num-registers+
                                  :element-type 'double-float
                                  :initial-element 7.0d0))
           (semantic
             (make-semantic-action-from-terminal
              (make-factored-action :primary 8 :secondary 3)
              registers)))
      (assert-factored-action-test
       (and (= (semantic-action-target semantic) 8)
            (eq (semantic-action-response semantic) :decoy)
            (null (semantic-action-option semantic)))
       "Factored Decoy should defer option selection: ~S" semantic))

    ;; Numeric payloads retain the old register decoder for historical files.
    (let ((registers (make-array +num-registers+
                                 :element-type 'double-float
                                 :initial-element 0.0d0)))
      (setf (aref registers +response-register+) 3.0d0
            (aref registers +decoy-option-register+) 6.0d0)
      (let ((semantic (make-semantic-action-from-terminal 8 registers)))
        (assert-factored-action-test
         (and (= (semantic-action-target semantic) 8)
              (eq (semantic-action-response semantic) :decoy)
              (= (semantic-action-option semantic) 6))
         "Legacy numeric decoding changed: ~S" semantic)))

    t))
