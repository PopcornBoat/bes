;;; Focused non-simulator checks for combined targeted repair case-directed repair.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *targeted-combined-checks* 0)

(defun check-targeted-combined (condition description)
  (incf *targeted-combined-checks*)
  (unless condition
    (error "combined targeted repair combined-repair check failed: ~A" description)))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*targeted-combined-repair-enabled* t)
      (cl-tpg::*targeted-routing-repair-enabled* t)
      (cl-tpg::*targeted-specialist-composition-enabled* t)
      (cl-tpg::*targeted-disagreement-audit-enabled* t)
      (cl-tpg::*grouped-selection-enabled* t)
      (cl-tpg::*semantic-locality-control-enabled* t)
      (cl-tpg::*behavioral-locality-enabled* t)
      (cl-tpg::*terminal-action-format* :target-response-36))
  (check-targeted-combined
   (cl-tpg::targeted-combined-repair-active-p)
   "combined repair requires both operators and the full grouped selection contract")
  (check-targeted-combined
   (and (eq (cl-tpg::targeted-combined-repair-kind
             '(:case :case-a-routing))
            :routing)
        (eq (cl-tpg::targeted-combined-repair-kind
             '(:case :case-b1-reachable-support))
            :composition)
        (null (cl-tpg::targeted-combined-repair-kind
               '(:case :case-b2-missing-support))))
   "Case A and Case B1 dispatch separately while Case B2 stays deferred"))

;; combined targeted repair has one ten-percent schedule, not two independent quotas.
(cl-tpg::initialize-targeted-routing-repair-state 153)
(cl-tpg::initialize-targeted-specialist-composition-state 153)
(dotimes (index 1000)
  (cl-tpg::targeted-combined-repair-slot-p))
(check-targeted-combined
 (= cl-tpg::*targeted-routing-repair-rng-cursor* 1000)
 "one combined scheduling decision consumes exactly one shared draw")
(check-targeted-combined
 (zerop cl-tpg::*targeted-specialist-composition-rng-cursor*)
 "the composition stream is untouched until a Case-B1 operator runs")

(let* ((team (cl-tpg::%make-team :id "combined-checkpoint" :learners nil))
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*targeted-combined-repair-enabled* t)
       (cl-tpg::*targeted-routing-repair-enabled* t)
       (cl-tpg::*targeted-specialist-composition-enabled* t)
       (cl-tpg::*checkpoint-directory* nil))
  (cl-tpg::initialize-targeted-routing-repair-state 2026)
  (cl-tpg::initialize-targeted-specialist-composition-state 2026)
  (let ((data (cl-tpg::make-best-team-checkpoint-data team 0.5d0)))
    (check-targeted-combined
     (and (equal (getf data :targeted-routing-repair-state)
                 (cl-tpg::targeted-routing-repair-state-copy))
          (equal (getf data :targeted-specialist-composition-state)
                 (cl-tpg::targeted-specialist-composition-state-copy)))
     "checkpoints persist both independent operator streams")
    (check-targeted-combined
     (search "official-guided-combined-repair"
             (cl-tpg::best-team-checkpoint-filename))
     "combined treatment uses a distinct protected checkpoint filename")))

(format t "combined targeted repair combined repair checks passed (~D checks).~%"
        *targeted-combined-checks*)
