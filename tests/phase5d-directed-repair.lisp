;;; Focused non-simulator checks for Phase-5D-2 teacher-directed repair.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *phase5d-directed-checks* 0)

(defun check-phase5d-directed (condition description)
  (incf *phase5d-directed-checks*)
  (unless condition
    (error "Phase-5D-2 directed repair check failed: ~A" description)))

(defun phase5d-test-bid-program (value)
  (cl-tpg::make-program
   :instructions
   (make-array
    1 :adjustable t :fill-pointer t
    :initial-contents
    (list
     (cl-tpg::%make-instruction
      :dest 0 :op :add :arity 2
      :src1-type :const :src1-val (coerce value 'double-float)
      :src2-type :const :src2-val 0.0d0)))))

(defun phase5d-test-terminal (bid pair)
  (cl-tpg::make-learner
   :program (phase5d-test-bid-program bid)
   :action
   (cl-tpg::make-action
    :type :atomic
    :action
    (cl-tpg::make-target-response-36-action
     :target (first pair) :response (second pair)))))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*phase5d-directed-repair-enabled* t)
      (cl-tpg::*phase4b-disagreement-audit-enabled* t)
      (cl-tpg::*phase4b-routing-repair-enabled* t)
      (cl-tpg::*phase4-selection-enabled* t)
      (cl-tpg::*semantic-locality-control-enabled* t)
      (cl-tpg::*behavioral-locality-enabled* t)
      (cl-tpg::*terminal-action-format* :target-response-36))
  (check-phase5d-directed
   (cl-tpg::phase5d-directed-repair-active-p)
   "the directed operator activates only under the frozen full contract"))

;; A synthesized gate adds a small margin on its exact state and suppresses
;; the copied bidder when the selected feature differs.
(let* ((source (phase5d-test-bid-program 10.0d0))
       (feature '(:index 0 :value 1.0d0 :collision-rate 0.0d0))
       (program (cl-tpg::phase5d-gated-bid-program source (list feature)))
       (matching
         (make-array 2 :element-type 'double-float
                       :initial-contents '(1.0d0 0.0d0)))
       (other
         (make-array 2 :element-type 'double-float
                       :initial-contents '(0.0d0 0.0d0))))
  (check-phase5d-directed
   (= (aref (cl-tpg::execute-program program matching) 0) 11.0d0)
   "an exact gate match receives only the configured positive margin")
  (check-phase5d-directed
   (< (aref (cl-tpg::execute-program program other) 0) 0.0d0)
   "a feature mismatch suppresses the correction bidder"))

;; The end-to-end constructor must fix the repeated teacher group while
;; retaining the prior action on a non-target probe.
(let* ((target-observation
         (make-array 2 :element-type 'double-float
                       :initial-contents '(1.0d0 0.0d0)))
       (other-observation
         (make-array 2 :element-type 'double-float
                       :initial-contents '(0.0d0 0.0d0)))
       (teacher-pair '(2 0))
       (wrong-pair '(3 0))
       (parent
         (cl-tpg::%make-team
          :id "phase5d-parent"
          :learners
          (list (phase5d-test-terminal 10.0d0 wrong-pair)
                (phase5d-test-terminal 1.0d0 teacher-pair))))
       (issue
         '(:case :case-a-routing
           :phase :steps-10-29
           :teacher-pair (2 0)
           :predicted-pair (3 0)
           :occurrences 3 :episode-count 3 :systematic-p t))
       (contexts
         (loop repeat 3
               collect
               (list :observation target-observation
                     :teacher-pair teacher-pair
                     :parent-ranking
                       (cl-tpg::behavioral-ranking-pairs
                        parent target-observation)
                     :parent-rank 1)))
       (probe
         (list :source :test :generation 1 :step 40
               :observation other-observation
               :teacher-pair wrong-pair
               :teacher-ranking (list wrong-pair teacher-pair)))
       (cl-tpg::*teams* (list parent))
       (cl-tpg::*num-observations* 2)
       (cl-tpg::*max-num-learners* 8)
       (cl-tpg::*factored-actions-enabled* t)
       (cl-tpg::*terminal-action-format* :target-response-36)
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*phase5d-directed-repair-enabled* t)
       (cl-tpg::*phase4b-disagreement-audit-enabled* t)
       (cl-tpg::*phase4b-routing-repair-enabled* t)
       (cl-tpg::*phase4-selection-enabled* t)
       (cl-tpg::*semantic-locality-control-enabled* t)
       (cl-tpg::*behavioral-locality-enabled* t)
       (cl-tpg::*behavioral-probe-archive* (list probe))
       (cl-tpg::*behavioral-signature-cache* (make-hash-table :test #'eq))
       (cl-tpg::*behavioral-teacher-action-support*
         (let ((table (make-hash-table :test #'equal)))
           (setf (gethash teacher-pair table) t
                 (gethash wrong-pair table) t)
           table))
       (cl-tpg::*behavioral-team-lineage* (make-hash-table :test #'eq))
       (cl-tpg::*behavioral-team-parents* (make-hash-table :test #'eq))
       (cl-tpg::*behavioral-generation-records* nil)
       (cl-tpg::*behavioral-locality-sampling-candidates* nil)
       (cl-tpg::*semantic-locality-control-generation-records* nil))
  (multiple-value-bind (child locality attempts source-id)
      (cl-tpg::phase5d-try-parent-issue parent issue contexts)
    (declare (ignore attempts source-id))
    (check-phase5d-directed child
                            "a valid directed correction child is built")
    (check-phase5d-directed
     (equal
      (first (cl-tpg::behavioral-ranking-pairs child target-observation))
      teacher-pair)
     "the teacher terminal wins on the diagnosed target rows")
    (check-phase5d-directed
     (equal
      (first (cl-tpg::behavioral-ranking-pairs child other-observation))
      wrong-pair)
     "the correction remains suppressed on the collateral probe")
    (check-phase5d-directed
     (and (eq (getf locality :control-stage)
              :phase5d-directed-repair)
          (equal (mapcar (lambda (entry) (getf entry :index))
                         (getf locality :phase5d-gate))
                 '(0)))
     "accepted lineage records the directed gate and control stage")))

(format t "Phase-5D-2 directed repair checks passed (~D checks).~%"
        *phase5d-directed-checks*)
