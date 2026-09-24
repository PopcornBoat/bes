;;; Focused non-simulator checks for passive Phase-4b disagreement auditing.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *phase4b-audit-checks* 0)

(defun check-phase4b-audit (condition description)
  (incf *phase4b-audit-checks*)
  (unless condition
    (error "Phase-4b audit check failed: ~A" description)))

(defun phase4b-audit-program ()
  (cl-tpg::make-program
   :instructions (make-array 0 :adjustable t :fill-pointer t)))

(defun phase4b-audit-terminal (id target response)
  (cl-tpg::%make-team
   :id id
   :learners
   (list
    (cl-tpg::make-learner
     :program (phase4b-audit-program)
     :action
     (cl-tpg::make-action
      :type :atomic
      :action
      (cl-tpg::make-target-response-36-action
       :target target :response response))))))

(let* ((inner (phase4b-audit-terminal "inner" 8 1))
       (reference
         (cl-tpg::make-learner
          :program (phase4b-audit-program)
          :action (cl-tpg::make-action :type :reference :action inner)))
       (root (cl-tpg::%make-team :id "root" :learners (list reference)))
       (support (cl-tpg::phase4b-behavior-terminal-support root)))
  (check-phase4b-audit (gethash '(8 1) support)
                       "reachable atomic pair is genotype support")
  (check-phase4b-audit
   (eq (cl-tpg::phase4b-disagreement-case 2 '(8 1) support)
       :case-a-routing)
   "a teacher action in Top-k is Case A regardless of terminal support")
  (check-phase4b-audit
   (eq (cl-tpg::phase4b-disagreement-case nil '(8 1) support)
       :case-b1-reachable-support)
   "a supported teacher action below Top-k is Case B1")
  (check-phase4b-audit
   (eq (cl-tpg::phase4b-disagreement-case nil '(9 3) support)
       :case-b2-missing-support)
   "an absent and unsupported teacher action is Case B2"))

(let* ((support (make-hash-table :test #'equal))
       (case-counts (make-hash-table :test #'eq))
       (phase-counts (make-hash-table :test #'equal))
       (pair-counts (make-hash-table :test #'equal))
       (rank-counts (make-hash-table :test #'eql))
       (issue-counts (make-hash-table :test #'equal))
       (issue-episodes (make-hash-table :test #'equal))
       (issue-a
         '(:case-a-routing :steps-10-29 (8 1) (8 0) 3))
       (issue-b
         '(:case-b2-missing-support :steps-50-99 (9 3) (9 0) nil)))
  (setf (gethash '(8 1) support) t
        (gethash :case-a-routing case-counts) 3
        (gethash :case-b2-missing-support case-counts) 1
        (gethash '(:steps-10-29 :case-a-routing) phase-counts) 3
        (gethash '((8 1) :case-a-routing) pair-counts) 3
        (gethash 3 rank-counts) 3
        (gethash issue-a issue-counts) 3
        (gethash issue-b issue-counts) 1
        (gethash issue-a issue-episodes) '(154 153)
        (gethash issue-b issue-episodes) '(153))
  (let* ((audit
           (cl-tpg::phase4b-make-disagreement-audit
            4 support case-counts phase-counts pair-counts rank-counts
            issue-counts issue-episodes))
         (systematic (getf audit :systematic-issues)))
    (check-phase4b-audit
     (eq (getf audit :protocol)
         cl-tpg::+phase4b-disagreement-audit-protocol+)
     "audit includes its versioned protocol")
    (check-phase4b-audit
     (= (cdr (assoc :case-a-routing (getf audit :case-counts))) 3)
     "audit retains deterministic case counts")
    (check-phase4b-audit
     (= (cdr (assoc :case-a-routing (getf audit :case-rates))) 0.75d0)
     "case rates use all Top-1 disagreements as denominator")
    (check-phase4b-audit
     (and (= (length systematic) 1)
          (equal (getf (first systematic) :episode-seeds) '(153 154)))
     "systematic errors must repeat across rows and distinct episodes")))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*phase4-selection-enabled* t)
      (cl-tpg::*phase4b-disagreement-audit-enabled* t)
      (cl-tpg::*terminal-action-format* :target-response-36))
  (check-phase4b-audit (cl-tpg::phase4b-disagreement-audit-active-p)
                       "audit activates only for the Phase-4b contract"))

(format t "Phase-4b disagreement audit checks passed (~D checks).~%"
        *phase4b-audit-checks*)
