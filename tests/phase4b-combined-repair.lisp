;;; Focused non-simulator checks for Phase-4b-C case-directed repair.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *phase4b-combined-checks* 0)

(defun check-phase4b-combined (condition description)
  (incf *phase4b-combined-checks*)
  (unless condition
    (error "Phase-4b-C combined-repair check failed: ~A" description)))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*phase4b-combined-repair-enabled* t)
      (cl-tpg::*phase4b-routing-repair-enabled* t)
      (cl-tpg::*phase4b-specialist-composition-enabled* t)
      (cl-tpg::*phase4b-disagreement-audit-enabled* t)
      (cl-tpg::*phase4-selection-enabled* t)
      (cl-tpg::*semantic-locality-control-enabled* t)
      (cl-tpg::*behavioral-locality-enabled* t)
      (cl-tpg::*terminal-action-format* :target-response-36))
  (check-phase4b-combined
   (cl-tpg::phase4b-combined-repair-active-p)
   "combined repair requires both operators and the full Phase-4 contract")
  (check-phase4b-combined
   (and (eq (cl-tpg::phase4b-combined-repair-kind
             '(:case :case-a-routing))
            :routing)
        (eq (cl-tpg::phase4b-combined-repair-kind
             '(:case :case-b1-reachable-support))
            :composition)
        (null (cl-tpg::phase4b-combined-repair-kind
               '(:case :case-b2-missing-support))))
   "Case A and Case B1 dispatch separately while Case B2 stays deferred"))

;; Phase 4b-C has one ten-percent schedule, not two independent quotas.
(cl-tpg::initialize-phase4b-routing-repair-state 153)
(cl-tpg::initialize-phase4b-specialist-composition-state 153)
(dotimes (index 1000)
  (cl-tpg::phase4b-combined-repair-slot-p))
(check-phase4b-combined
 (= cl-tpg::*phase4b-routing-repair-rng-cursor* 1000)
 "one combined scheduling decision consumes exactly one shared draw")
(check-phase4b-combined
 (zerop cl-tpg::*phase4b-specialist-composition-rng-cursor*)
 "the composition stream is untouched until a Case-B1 operator runs")

(let* ((team (cl-tpg::%make-team :id "combined-checkpoint" :learners nil))
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*phase4b-combined-repair-enabled* t)
       (cl-tpg::*phase4b-routing-repair-enabled* t)
       (cl-tpg::*phase4b-specialist-composition-enabled* t)
       (cl-tpg::*checkpoint-directory* nil))
  (cl-tpg::initialize-phase4b-routing-repair-state 2026)
  (cl-tpg::initialize-phase4b-specialist-composition-state 2026)
  (let ((data (cl-tpg::make-best-team-checkpoint-data team 0.5d0)))
    (check-phase4b-combined
     (and (equal (getf data :phase4b-routing-repair-state)
                 (cl-tpg::phase4b-routing-repair-state-copy))
          (equal (getf data :phase4b-specialist-composition-state)
                 (cl-tpg::phase4b-specialist-composition-state-copy)))
     "checkpoints persist both independent operator streams")
    (check-phase4b-combined
     (search "official-guided-combined-repair"
             (cl-tpg::best-team-checkpoint-filename))
     "combined treatment uses a distinct protected checkpoint filename")))

(format t "Phase-4b-C combined repair checks passed (~D checks).~%"
        *phase4b-combined-checks*)
