;;; Focused checks for the hierarchical semantic offline fitness helpers.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *semantic-offline-checks* 0)

(defun check-semantic-offline (condition description)
  (incf *semantic-offline-checks*)
  (unless condition
    (error "Semantic offline check failed: ~A" description)))

(flet ((matches (prediction label)
         (cl-tpg::semantic-action-label-matches-p prediction label)))
  (check-semantic-offline
   (matches (cl-tpg::make-semantic-action
             :target 0 :response :monitor :option nil)
            '(0 3 7))
   "GLOBAL ignores response and option labels")
  (check-semantic-offline
   (matches (cl-tpg::make-semantic-action
             :target 8 :response :analyse :option nil)
            '(8 0 7))
   "non-Decoy host action ignores option")
  (check-semantic-offline
   (not (matches (cl-tpg::make-semantic-action
                  :target 8 :response :remove :option nil)
                 '(8 0 0)))
   "host response mismatch")
  (check-semantic-offline
   (matches (cl-tpg::make-semantic-action
             :target 8 :response :decoy :option 4)
            '(8 3 4))
   "Decoy option match")
  (check-semantic-offline
   (not (matches (cl-tpg::make-semantic-action
                  :target 8 :response :decoy :option 5)
                 '(8 3 4)))
   "Decoy option mismatch"))

(check-semantic-offline
 (string=
  (namestring
   (cl-tpg::semantic-validation-dataset-path
    #p"/tmp/cage2_bline_semantic_train.lisp"))
  "/tmp/cage2_bline_semantic_val.lisp")
 "training path infers validation sibling")

(let* ((cl-tpg::*batch-size* 5)
       (cl-tpg::*random-state* (sb-ext:seed-random-state 153))
       (dataset (cl-tpg::%make-dataset
                 :observations (make-array 0)
                 :actions (make-array 0)
                 :rewards (make-array 0 :element-type 'double-float)
                 :terminations (make-array 0)
                 :truncations (make-array 0)
                 :size 20))
       (indices (cl-tpg::make-uniform-dataset-indices dataset)))
  (check-semantic-offline (= (length indices) 5)
                          "requested batch size")
  (check-semantic-offline
   (= (length (remove-duplicates (coerce indices 'list))) 5)
   "sampling without replacement")
  (check-semantic-offline
   (every (lambda (index) (<= 0 index 19)) indices)
   "sampled index range"))

(let* ((fingerprint
         '(:training (:name "train.lisp" :bytes 100)
           :reference (:name "val.lisp" :bytes 25)))
       (cl-tpg::*offline-reference-dataset* t)
       (cl-tpg::*current-dataset-fingerprint* fingerprint)
       (metadata
         (list :fitness-evaluation-protocol
               cl-tpg::+semantic-offline-fitness-protocol+
               :dataset-fingerprint fingerprint)))
  (check-semantic-offline
   (cl-tpg::checkpoint-fitness-comparable-p 0.75d0 metadata nil)
   "matching semantic checkpoint provenance")
  (check-semantic-offline
   (not (cl-tpg::checkpoint-fitness-comparable-p
         0.75d0
         (list :fitness-evaluation-protocol
               cl-tpg::+semantic-offline-fitness-protocol+
               :dataset-fingerprint '(:different t))
         nil))
   "changed semantic dataset forces re-baselining"))

(let* ((cl-tpg::*num-actions* 11)
       (cl-tpg::*num-observations* 54)
       (form
         (list :transition
               :observation (loop repeat 54 collect 0)
               :semantic-action '(8 3 4)
               :representable t
               :reward 0
               :terminated nil
               :truncated nil))
       (dataset
         (cl-tpg::convert-semantic-stream-to-dataset
          form
          (make-string-input-stream "")
          "/tmp/context.lisp")))
  (check-semantic-offline
   (= (length (aref (cl-tpg::observations dataset) 0)) 54)
   "semantic loader accepts configured 54-input observations"))

(let ((cl-tpg::*offline-reference-dataset* t)
      (cl-tpg::*current-dataset-fingerprint* '(:same t))
      (cl-tpg::*num-observations* 54))
  (check-semantic-offline
   (not (cl-tpg::checkpoint-fitness-comparable-p
         0.75d0
         (list :fitness-evaluation-protocol
               cl-tpg::+semantic-offline-fitness-protocol+
               :dataset-fingerprint '(:same t)
               :num-observations 52)
         nil))
   "observation-width mismatch forces checkpoint re-baselining"))

(let* ((base
         (make-array 52
                     :element-type 'double-float
                     :initial-contents
                     (loop for index below 52
                           collect (coerce index 'double-float))))
       (context
         (cl-gym::cage2-context-observation base 17 29)))
  (check-semantic-offline (= (length context) 54)
                          "validation context observation width")
  (check-semantic-offline
   (loop for index below 52
         always (= (aref base index) (aref context index)))
   "validation context preserves base observation")
  (check-semantic-offline
   (and (= (aref context 52) 17.0d0)
        (= (aref context 53) 29.0d0))
   "validation appends raw episode and step indices"))

(let ((original-rollout (symbol-function 'cl-gym:rollout))
      (seen-indices nil))
  (unwind-protect
       (progn
         (setf (symbol-function 'cl-gym:rollout)
               (lambda (team environment seed
                        &key video-path episode-index)
                 (declare (ignore team environment seed video-path))
                 (push episode-index seen-indices)
                 0.0d0))
         (cl-tpg::run-validation-rollouts
          nil "Cage2-b_line-30-v0" 3)
         (check-semantic-offline
          (equal (nreverse seen-indices) '(0 1 2))
          "CAGE2 validation propagates zero-based episode indices")
         (setf seen-indices nil)
         (cl-tpg::run-validation-rollouts nil "CartPole-v1" 2)
         (check-semantic-offline
          (equal seen-indices '(nil nil))
          "non-CAGE2 validation does not add episode context"))
    (setf (symbol-function 'cl-gym:rollout) original-rollout)))

(format t "~D semantic offline checks passed.~%" *semantic-offline-checks*)
