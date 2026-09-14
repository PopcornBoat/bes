;;; Focused checks for the hierarchical semantic offline fitness helpers.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *semantic-offline-checks* 0)

(defun check-semantic-offline (condition description)
  (incf *semantic-offline-checks*)
  (unless condition
    (error "Semantic offline check failed: ~A" description)))

(check-semantic-offline
 (= cl-tpg::+cage2-observation-size+ 142)
 "complete CAGE2 bridge observation includes availability")

(check-semantic-offline
 (cl-tpg::valid-cage2-policy-observation-size-p 62)
 "62-value policy prefix is supported")

(check-semantic-offline
 (cl-tpg::valid-cage2-policy-observation-size-p 142)
 "142-value policy input is supported")

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

(let* ((orders (make-array 11 :initial-element nil))
       (agreement
         (cl-tpg::make-action-agreement
          :decoy-names #(apache haraka tomcat vsftpd smss postfix femitter sshd)
          :decoy-orders orders)))
  (setf (aref orders 8) #(1 6 0 4 2 3 5 7))
  (let ((cl-tpg::*action-agreement* agreement))
    (check-semantic-offline
     (cl-tpg::semantic-action-label-matches-p
      (cl-tpg::make-semantic-action
       :target 8 :response :decoy :option nil)
      '(8 3 1)
      0)
     "factored Decoy resolves first available agreement option")
    (check-semantic-offline
     (cl-tpg::semantic-action-label-matches-p
      (cl-tpg::make-semantic-action
       :target 8 :response :decoy :option nil)
      '(8 3 6)
      (ash 1 (+ (* 7 8) 1)))
     "factored Decoy skips used agreement option")
    (let ((policy-orders (cl-tpg::copy-action-option-orders orders)))
      (setf (aref policy-orders 8) #(7 5 4 3 2 1 0 6))
      (check-semantic-offline
       (cl-tpg::semantic-action-label-matches-p
        (cl-tpg::make-semantic-action
         :target 8 :response :decoy :option nil)
        '(8 3 7)
        0
        policy-orders)
       "policy-owned Decoy order overrides agreement default"))))

(let* ((source (loop repeat 62 collect 0))
       (expanded (cl-tpg::append-decoy-availability source 1)))
  (check-semantic-offline (= (length expanded) 142)
                          "offline observations expand to 142")
  (check-semantic-offline (= (aref expanded 62) 0.0d0)
                          "used decoy is unavailable")
  (check-semantic-offline (= (aref expanded 63) 1.0d0)
                          "unused decoy is available"))

(let ((source (loop repeat 62 collect 0)))
  (let ((cl-tpg::*num-observations* 62))
    (check-semantic-offline
     (= (length (cl-tpg::make-cage2-policy-observation source 1)) 62)
     "62-input mode ignores availability"))
  (let ((cl-tpg::*num-observations* 142))
    (check-semantic-offline
     (= (length (cl-tpg::make-cage2-policy-observation source 1)) 142)
     "142-input mode appends availability")))

(check-semantic-offline
 (cl-tpg::valid-semantic-ranking-p '((8 3) (8 0) (1 1)))
 "v2 target/response ranking validation")

(check-semantic-offline
 (not (cl-tpg::valid-semantic-ranking-p '((8 3) (8 3))))
 "v2 rankings reject duplicate categories")

(let* ((predictions
         (list
          (cl-tpg::make-semantic-action :target 8 :response :decoy)
          (cl-tpg::make-semantic-action :target 8 :response :analyse)))
       (teacher '((8 3) (8 0))))
  (check-semantic-offline
   (= (cl-tpg::semantic-ranking-ndcg predictions teacher) 1.0d0)
   "matching semantic ranking has perfect NDCG")
  (check-semantic-offline
   (< (cl-tpg::semantic-ranking-ndcg (reverse predictions) teacher) 1.0d0)
   "reversed semantic ranking loses NDCG"))

(let* ((orders
         (cl-tpg::action-agreement-decoy-orders
          (cl-tpg::ensure-cage2-action-agreement)))
       (exhausted-mask (1- (ash 1 8)))
       (predictions
         (list
          (cl-tpg::make-semantic-action :target 1 :response :decoy)
          (cl-tpg::make-semantic-action :target 8 :response :restore)
          (cl-tpg::make-semantic-action :target 8 :response :analyse))))
  (check-semantic-offline
   (equal (cl-tpg::resolve-semantic-ranking
           predictions exhausted-mask orders)
          '(8 0))
   "ranked resolver skips exhausted Decoy and fallback Restore"))

(labels ((bid-program (value)
         (cl-tpg::make-program
          :instructions
          (make-array
           1 :adjustable t :fill-pointer t
           :initial-contents
           (list
            (cl-tpg::%make-instruction
             :dest 0 :op :add
             :src1-type :const :src1-val (coerce value 'double-float)
             :src2-type :const :src2-val 0.0d0 :arity 2)))))
       (terminal-learner (bid target response)
         (cl-tpg::make-learner
          :program (bid-program bid)
          :action
          (cl-tpg::make-action
           :type :atomic
           :action
           (cl-tpg::make-factored-action
            :primary target :secondary response)))))
  (let* ((inner
           (cl-tpg::%make-team
            :learners
            (list (terminal-learner 5 8 3)
                  (terminal-learner 3 8 0))))
         (reference
           (cl-tpg::make-learner
            :program (bid-program 10)
            :action (cl-tpg::make-action :type :reference :action inner)))
         (root
           (cl-tpg::%make-team
            :learners
            (list reference (terminal-learner 9 1 1))))
         (observation
           (make-array 1 :element-type 'double-float :initial-element 0.0d0))
         (single (cl-tpg::execute-team-semantic root observation))
         (ranked (cl-tpg::execute-team-semantic-ranked root observation)))
    (check-semantic-offline
     (equal (cl-tpg::semantic-action-category-pair single)
            (cl-tpg::semantic-action-category-pair (first ranked)))
     "ranked traversal preserves the existing first winner")
    (check-semantic-offline
     (equal (mapcar #'cl-tpg::semantic-action-category-pair ranked)
            '((8 3) (8 0) (1 1)))
     "ranked traversal follows hierarchical bid order")))

(let* ((cl-tpg::*num-observations* 62)
       (cl-tpg::*hamming-space-enabled* nil)
       (bridge-observation
         (make-array 142
                     :element-type 'double-float
                     :initial-element 1.0d0))
       (policy-observation
         (cl-tpg::policy-observation bridge-observation)))
  (check-semantic-offline (= (length policy-observation) 62)
                          "online policy reads only the configured prefix")
  (check-semantic-offline (= (aref policy-observation 61) 1.0d0)
                          "online prefix retains the scan-state boundary"))

(let* ((cl-tpg::*factored-actions-enabled* t)
       (agreement (cl-tpg::ensure-cage2-action-agreement))
       (team (cl-tpg::%make-team :learners nil))
       (evolved (cl-tpg::copy-action-option-orders
                 (cl-tpg::team-option-orders team))))
  (rotatef (aref (aref evolved 1) 0) (aref (aref evolved 1) 1))
  (setf (cl-tpg::team-option-orders team) evolved)
  (let ((cl-tpg::*decoy-order-mode* :evolved))
    (check-semantic-offline
     (eq (cl-tpg::effective-team-option-orders team) evolved)
     "evolved mode uses the team table"))
  (let ((cl-tpg::*decoy-order-mode* :fixed))
    (check-semantic-offline
     (equalp (cl-tpg::effective-team-option-orders team)
             (cl-tpg::action-agreement-decoy-orders agreement))
     "fixed mode uses the PPO-derived agreement table")))

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
       (cl-tpg::*num-observations* 142)
       (cl-tpg::*decoy-order-mode* :evolved)
       (agreement-signature
         (cl-tpg::action-agreement-signature))
       (metadata
         (list :fitness-evaluation-protocol
               cl-tpg::+semantic-offline-fitness-protocol+
               :dataset-fingerprint fingerprint
               :num-observations 142
               :decoy-order-mode :evolved
               :action-agreement-signature agreement-signature)))
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
