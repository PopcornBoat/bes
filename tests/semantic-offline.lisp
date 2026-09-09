;;; Focused checks for the hierarchical semantic offline fitness helpers.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *semantic-offline-checks* 0)

(defun check-semantic-offline (condition description)
  (incf *semantic-offline-checks*)
  (unless condition
    (error "Semantic offline check failed: ~A" description)))

(check-semantic-offline
 (= cl-tpg::+cage2-observation-size+ 62)
 "CAGE2 bridge observation size includes ten scan states")

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

(format t "~D semantic offline checks passed.~%" *semantic-offline-checks*)
