;;; Focused checks for prioritized DAgger plus closed-loop DT fitness.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *hybrid-checks* 0)

(defun check-hybrid (condition description)
  (incf *hybrid-checks*)
  (unless condition
    (error "Hybrid check failed: ~A" description)))

(dolist (case '((1 0.8d0 0.2d0)
                (200 0.8d0 0.2d0)
                (201 0.5d0 0.5d0)
                (501 0.2d0 0.8d0)))
  (destructuring-bind (generation expected-imitation expected-return) case
    (multiple-value-bind (imitation return)
        (cl-tpg::hybrid-fitness-weights generation)
      (check-hybrid
       (and (= imitation expected-imitation) (= return expected-return))
       (format nil "generation ~D selects the configured stage" generation)))))

(check-hybrid
 (= (cl-tpg::normalized-cage2-return 0.0d0) 1.0d0)
 "zero reward maps to one")

(check-hybrid
 (< (cl-tpg::normalized-cage2-return -500.0d0)
    (cl-tpg::normalized-cage2-return -100.0d0))
 "less-negative reward receives a larger normalized score")

(let ((cl-tpg::*generation* 1))
  (check-hybrid
   (= (cl-tpg::hybrid-reference-combined-fitness 1.0d0 0.0d0)
      0.2d0)
   "historical reference always uses final-stage weights"))

(check-hybrid
 (= (length (cl-tpg::make-hybrid-reference-seeds))
    (* (length cl-tpg::+hybrid-reference-root-seeds+)
       cl-tpg::+digital-twin-reference-episodes+))
 "hybrid reference bank covers every protected root")

(let* ((observation (loop repeat 142 collect 0.0d0))
       (low (list observation '(0 0) '((0 0)) 0 1 3 1.0d0))
       (high (list observation '(8 3) '((8 3)) 0 1 4 16.0d0)))
  (check-hybrid
   (> (cl-tpg::teacher-dagger-row-priority high)
      (cl-tpg::teacher-dagger-row-priority low))
   "disagreement rows can outrank ordinary replay rows")
  (check-hybrid
   (= (cl-tpg::dataset-size
       (cl-tpg::teacher-trace-to-dataset (list high)))
      1)
   "priority-bearing seven-field rows remain valid ranked datasets"))

(let ((cl-tpg::*current-search-mode* :hybrid)
      (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0")
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*num-actions* 11)
      (cl-tpg::*decoy-order-mode* :fixed)
      (cl-tpg::*teacher-backend* :model)
      (cl-tpg::*cage2-opening-mode* :fixed)
      (cl-tpg::*recurrent-policy-enabled* nil)
      (cl-tpg::*hamming-space-enabled* nil))
  (check-hybrid
   (search "-hybrid-" (cl-tpg::best-team-checkpoint-filename))
   "hybrid checkpoints have an independent stable filename"))

(format t "~D hybrid checks passed.~%" *hybrid-checks*)
