;;; Focused non-simulator checks for passive targeted repair disagreement auditing.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *targeted-audit-checks* 0)

(defun check-targeted-audit (condition description)
  (incf *targeted-audit-checks*)
  (unless condition
    (error "targeted repair audit check failed: ~A" description)))

(defun targeted-audit-program ()
  (cl-tpg::make-program
   :instructions (make-array 0 :adjustable t :fill-pointer t)))

(defun targeted-audit-terminal (id target response)
  (cl-tpg::%make-team
   :id id
   :learners
   (list
    (cl-tpg::make-learner
     :program (targeted-audit-program)
     :action
     (cl-tpg::make-action
      :type :atomic
      :action
      (cl-tpg::make-target-response-36-action
       :target target :response response))))))

(let* ((inner (targeted-audit-terminal "inner" 8 1))
       (reference
         (cl-tpg::make-learner
          :program (targeted-audit-program)
          :action (cl-tpg::make-action :type :reference :action inner)))
       (root (cl-tpg::%make-team :id "root" :learners (list reference)))
       (support (cl-tpg::targeted-behavior-terminal-support root)))
  (check-targeted-audit (gethash '(8 1) support)
                       "reachable atomic pair is genotype support")
  (check-targeted-audit
   (eq (cl-tpg::targeted-disagreement-case 2 '(8 1) support)
       :case-a-routing)
   "a teacher action in Top-k is Case A regardless of terminal support")
  (check-targeted-audit
   (eq (cl-tpg::targeted-disagreement-case nil '(8 1) support)
       :case-b1-reachable-support)
   "a supported teacher action below Top-k is Case B1")
  (check-targeted-audit
   (eq (cl-tpg::targeted-disagreement-case nil '(9 3) support)
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
           (cl-tpg::targeted-make-disagreement-audit
            4 support case-counts phase-counts pair-counts rank-counts
            issue-counts issue-episodes))
         (systematic (getf audit :systematic-issues)))
    (check-targeted-audit
     (eq (getf audit :protocol)
         cl-tpg::+targeted-disagreement-audit-protocol+)
     "audit includes its versioned protocol")
    (check-targeted-audit
     (= (cdr (assoc :case-a-routing (getf audit :case-counts))) 3)
     "audit retains deterministic case counts")
    (check-targeted-audit
     (= (cdr (assoc :case-a-routing (getf audit :case-rates))) 0.75d0)
     "case rates use all Top-1 disagreements as denominator")
    (check-targeted-audit
     (and (= (length systematic) 1)
          (equal (getf (first systematic) :episode-seeds) '(153 154)))
     "systematic errors must repeat across rows and distinct episodes")))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*grouped-selection-enabled* t)
      (cl-tpg::*targeted-disagreement-audit-enabled* t)
      (cl-tpg::*terminal-action-format* :target-response-36))
  (check-targeted-audit (cl-tpg::targeted-disagreement-audit-active-p)
                       "audit activates only for the targeted repair contract"))

(format t "targeted repair disagreement audit checks passed (~D checks).~%"
        *targeted-audit-checks*)
