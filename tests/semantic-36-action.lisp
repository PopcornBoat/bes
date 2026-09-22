;;; Focused regression checks for the versioned Semantic-36 terminal head.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(let ((expected
        #((2 2) (3 2) (4 2) (5 2)
          (2 0) (3 0) (4 0) (5 0)
          (2 1) (3 1) (4 1) (5 1)
          (7 0) (8 0) (9 0) (10 0)
          (7 2) (8 2) (9 2) (10 2)
          (1 2) (1 0) (1 1)
          (7 1) (8 1) (9 1) (10 1)
          (2 3) (3 3) (4 3) (7 3) (8 3) (9 3) (10 3) (1 3) (5 3))))
  (assert (equalp cl-tpg::*semantic-36-catalogue* expected))
  (assert (= (length cl-tpg::*semantic-36-catalogue*)
             cl-tpg::+num-semantic-36-actions+))
  (assert (= (length (remove-duplicates
                      (coerce cl-tpg::*semantic-36-catalogue* 'list)
                      :test #'equal))
             cl-tpg::+num-semantic-36-actions+)))

;; The catalogue is exactly nine hosts by four responses, with no learned
;; GLOBAL/Monitor or User0 action.
(loop for target across cl-tpg::*semantic-36-targets*
      do (dotimes (response cl-tpg::+num-semantic-responses+)
           (let ((index (cl-tpg::semantic-36-pair-index target response)))
             (assert (integerp index))
             (assert (equal (cl-tpg::semantic-36-index-pair index)
                            (list target response))))))
(assert (null (cl-tpg::semantic-36-pair-index 0 0)))
(assert (null (cl-tpg::semantic-36-pair-index 6 0)))

(let ((cl-tpg::*factored-actions-enabled* t)
      (cl-tpg::*terminal-action-format* :semantic-36)
      (cl-tpg::*num-actions* cl-tpg::+num-semantic-36-actions+))
  (loop repeat 200 do
    (let ((payload (cl-tpg::make-random-atomic-action-value)))
      (assert (cl-tpg::semantic-36-action-p payload))
      (assert (<= 0 (cl-tpg::semantic-36-action-index payload) 35))))

  ;; Every category decodes to its explicit semantic target and response.
  (let ((registers
          (make-array cl-tpg::+num-registers+
                      :element-type 'double-float
                      :initial-element 99.0d0)))
    (dotimes (index cl-tpg::+num-semantic-36-actions+)
      (let* ((pair (cl-tpg::semantic-36-index-pair index))
             (semantic
               (cl-tpg::make-semantic-action-from-terminal
                (cl-tpg::make-semantic-36-action :index index)
                registers)))
        (assert (= (cl-tpg:semantic-action-target semantic) (first pair)))
        (assert (eq (cl-tpg:semantic-action-response semantic)
                    (aref cl-tpg::*semantic-response-types* (second pair))))
        (assert (null (cl-tpg:semantic-action-option semantic))))))

  (let* ((payload (cl-tpg::make-semantic-36-action :index 34))
         (encoded (cl-tpg::serialize-atomic-action-value payload))
         (action (cl-tpg::make-action :type :atomic :action payload))
         (restored
           (cl-tpg::deserialize-action
            (cl-tpg::serialize-action action (make-hash-table))
            (make-hash-table)))
         (clone (cl-tpg::clone-action action)))
    (assert (equal encoded
                   '(:semantic-36-action
                     :version :cage2-semantic-36-v1
                     :index 34)))
    (assert (= (cl-tpg::semantic-36-action-index
                (cl-tpg::action-action restored))
               34))
    (setf (cl-tpg::semantic-36-action-index
           (cl-tpg::action-action clone))
          0)
    (assert (= (cl-tpg::semantic-36-action-index payload) 34)))

  ;; Basic mutation remains categorical and changes exactly one component.
  (loop repeat 200 do
    (let* ((source (cl-tpg::make-semantic-36-action :index 0))
           (mutated (cl-tpg::mutate-semantic-36-atomic-value source))
           (before (cl-tpg::semantic-36-index-pair 0))
           (after
             (cl-tpg::semantic-36-index-pair
              (cl-tpg::semantic-36-action-index mutated))))
      (assert after)
      (assert (not (equal before after)))
      (assert (= (count t
                        (mapcar (lambda (left right) (/= left right))
                                before after))
                 1))))

  ;; Compatibility APIs return a target, not the flat catalogue index.
  (assert (= (cl-tpg::atomic-action-primary
              (cl-tpg::make-semantic-36-action :index 0))
             2))

  ;; Switching formats does not alter historical factored or numeric payloads.
  (let ((cl-tpg::*terminal-action-format* :factored))
    (assert (cl-tpg::factored-action-p
             (cl-tpg::make-random-atomic-action-value))))
  (let ((cl-tpg::*factored-actions-enabled* nil))
    (assert (integerp (cl-tpg::make-random-atomic-action-value)))))

(format t "Semantic-36 action checks passed.~%")
