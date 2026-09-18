;;; Focused checks for conservative CAGE2 digital-twin integration.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *digital-twin-checks* 0)

(defun check-digital-twin (condition description)
  (incf *digital-twin-checks*)
  (unless condition
    (error "Digital-twin check failed: ~A" description)))

(check-digital-twin
 (cl-tpg::digital-twin-environment-p "Cage2Twin-b_line-100-v0")
 "aggregate twin ID is recognized")

(check-digital-twin
 (string= (cl-tpg::digital-twin-member-environment-name
           "Cage2Twin-b_line-100-v0" 3)
          "Cage2Twin-b_line-100-m3-v0")
 "aggregate twin ID maps to a fixed member")

(check-digital-twin
 (< (abs (- (cl-tpg::population-standard-deviation '(1.0d0 3.0d0))
            1.0d0))
    1.0d-12)
 "ensemble disagreement uses population standard deviation")

(let ((cl-tpg::*current-search-mode* :online)
      (cl-tpg::*current-gym-environment-name* "Cage2Twin-b_line-100-v0")
      (cl-tpg::*mixed-training-lineage* t)
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*num-actions* 11)
      (cl-tpg::*decoy-order-mode* :fixed)
      (cl-tpg::*cage2-opening-mode* :fixed)
      (cl-tpg::*hamming-space-enabled* nil))
  (check-digital-twin
   (string= (cl-tpg::best-team-checkpoint-filename)
            "bline-62-11-digital-twin-order-fixed-opening-fixed-hamming-off.lisp")
   "digital-twin checkpoints have an independent stable name"))

(format t "~D digital-twin checks passed.~%" *digital-twin-checks*)
