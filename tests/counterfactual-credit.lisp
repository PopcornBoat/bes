;;; Focused checks for counterfactual repair exact-prefix counterfactual credit.

(in-package :cl-user)

(defvar *counterfactual-checks* 0)

(defun check-counterfactual (condition description)
  (incf *counterfactual-checks*)
  (unless condition
    (error "counterfactual repair counterfactual check failed: ~A" description)))

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
       (event (cl-tpg::counterfactual-find-event episode teacher behavior)))
  (check-counterfactual
   (= (getf event :step) 1)
   "the first eligible non-opening disagreement is selected")
  (check-counterfactual
   (equal (cl-tpg::counterfactual-concrete-prefix episode 2) '(0 23))
   "the exact concrete-action prefix excludes the intervention step")
  (check-counterfactual
   (= (cl-tpg::counterfactual-prefix-return episode 2) -3.0d0)
   "return-to-go excludes all rewards before the intervention step")
  (let ((spec (cl-tpg::counterfactual-make-intervention event)))
    (check-counterfactual
     (and (= (getf spec :step) 1)
          (eq (getf spec :source) :teacher)
          (equal (getf spec :pair) teacher)
          (equal (getf spec :expected-behavior-pair) behavior))
     "the intervention freezes baseline state and both semantic proposals")))

(let ((request
        (list :protocol :counterfactual-credit-request-v1
              :checkpoint "/tmp/best-team.lisp"
              :discovery-seeds '(1 2)
              :holdout-seeds '(3 4)
              :teacher-pair '(5 3)
              :behavior-pair '(2 0))))
  (check-counterfactual
   (eq request (cl-tpg::counterfactual-validate-request request))
   "disjoint frozen seed blocks are accepted"))

(check-counterfactual
 (handler-case
     (progn
       (cl-tpg::counterfactual-validate-request
        (list :protocol :counterfactual-credit-request-v1
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
         (cl-tpg::counterfactual-cohort-summary :holdout records 3)))
  (check-counterfactual
   (and (= (getf summary :eligible-events) 2)
        (= (getf summary :mean-delta) 2.0d0)
        (< (abs (- (getf summary :standard-error) 1.0d0)) 1.0d-12))
   "cohort statistics distinguish requested seeds from eligible events"))

(check-counterfactual
 (and (eq (cl-tpg::counterfactual-step-bucket 12) :early)
      (eq (cl-tpg::counterfactual-step-bucket 20) :middle)
      (eq (cl-tpg::counterfactual-step-bucket 50) :late))
 "episode phases use frozen non-overlapping boundaries")

(check-counterfactual
 (and (eq (cl-tpg::counterfactual-delta-class 1.0d0) :positive)
      (eq (cl-tpg::counterfactual-delta-class -1.0d0) :negative)
      (eq (cl-tpg::counterfactual-delta-class 1.0d-14) :zero))
 "floating-point noise is not counted as a causal effect")

(let* ((records
         (list (list :group :a :paired-delta 2.0d0)
               (list :group :a :paired-delta 0.0d0)
               (list :group :b :paired-delta -1.0d0)))
       (groups
         (cl-tpg::counterfactual-context-group-summaries
          records (lambda (x) (getf x :group)))))
  (check-counterfactual
   (and (equal (getf (first groups) :key) :a)
        (= (getf (getf (first groups) :statistics) :count) 2))
   "context groups are ordered by evidence count"))

(format t "~&counterfactual repair counterfactual checks passed: ~D~%"
        *counterfactual-checks*)
