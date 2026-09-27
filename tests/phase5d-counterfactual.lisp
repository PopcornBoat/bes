;;; Focused checks for Phase 5D exact-prefix counterfactual credit.

(in-package :cl-user)

(defvar *phase5d-counterfactual-checks* 0)

(defun check-phase5d-counterfactual (condition description)
  (incf *phase5d-counterfactual-checks*)
  (unless condition
    (error "Phase 5D counterfactual check failed: ~A" description)))

(let* ((teacher '(5 3))
       (behavior '(2 0))
       (steps
         (list
          (list :step 0 :opening-pairs '((0 0))
                :actual-concrete-action 0 :reward -1.0d0)
          (list :step 1 :opening-pairs nil
                :teacher-disagreement-p t
                :teacher-decision (list :pair teacher)
                :executed-decision (list :pair behavior)
                :actual-concrete-action 23 :reward -2.0d0
                :policy-observation #(1.0d0 2.0d0))
          (list :step 2 :opening-pairs nil
                :teacher-disagreement-p t
                :teacher-decision (list :pair teacher)
                :executed-decision (list :pair behavior)
                :actual-concrete-action 24 :reward -3.0d0)))
       (episode (list :return -6.0d0 :steps steps))
       (event (cl-tpg::phase5d-find-event episode teacher behavior)))
  (check-phase5d-counterfactual
   (= (getf event :step) 1)
   "the first eligible non-opening disagreement is selected")
  (check-phase5d-counterfactual
   (equal (cl-tpg::phase5d-concrete-prefix episode 2) '(0 23))
   "the exact concrete-action prefix excludes the intervention step")
  (check-phase5d-counterfactual
   (= (cl-tpg::phase5d-prefix-return episode 2) -3.0d0)
   "return-to-go excludes all rewards before the intervention step")
  (let ((spec (cl-tpg::phase5d-make-intervention event)))
    (check-phase5d-counterfactual
     (and (= (getf spec :step) 1)
          (eq (getf spec :source) :teacher)
          (equal (getf spec :pair) teacher)
          (equal (getf spec :expected-behavior-pair) behavior))
     "the intervention freezes baseline state and both semantic proposals")))

(let ((request
        (list :protocol :phase5d-counterfactual-credit-request-v1
              :checkpoint "/tmp/best-team.lisp"
              :discovery-seeds '(1 2)
              :holdout-seeds '(3 4)
              :teacher-pair '(5 3)
              :behavior-pair '(2 0))))
  (check-phase5d-counterfactual
   (eq request (cl-tpg::phase5d-validate-request request))
   "disjoint frozen seed blocks are accepted"))

(check-phase5d-counterfactual
 (handler-case
     (progn
       (cl-tpg::phase5d-validate-request
        (list :protocol :phase5d-counterfactual-credit-request-v1
              :checkpoint "/tmp/best-team.lisp"
              :discovery-seeds '(1 2)
              :holdout-seeds '(2 3)
              :teacher-pair '(5 3)
              :behavior-pair '(2 0)))
       nil)
   (error () t))
 "overlapping discovery and holdout streams are rejected")

(let* ((records
         (list (list :status :evaluated :paired-delta 1.0d0)
               (list :status :evaluated :paired-delta 3.0d0)
               (list :status :no-eligible-event)))
       (summary
         (cl-tpg::phase5d-cohort-summary :holdout records 3)))
  (check-phase5d-counterfactual
   (and (= (getf summary :eligible-events) 2)
        (= (getf summary :mean-delta) 2.0d0)
        (< (abs (- (getf summary :standard-error) 1.0d0)) 1.0d-12))
   "cohort statistics distinguish requested seeds from eligible events"))

(format t "~&Phase 5D counterfactual checks passed: ~D~%"
        *phase5d-counterfactual-checks*)
