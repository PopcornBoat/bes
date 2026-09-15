;;; Focused checks for teacher-trace conversion and mode-specific naming.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *teacher-forcing-checks* 0)

(defun check-teacher-forcing (condition description)
  (incf *teacher-forcing-checks*)
  (unless condition
    (error "Teacher-forcing check failed: ~A" description)))

(let* ((observation (loop repeat 142 collect 0.0d0))
       (dataset
         (cl-tpg::teacher-trace-to-dataset
          (list (list observation '(8 3) '((8 3) (0 0) (8 0)) 17)))))
  (check-teacher-forcing
   (= (cl-tpg::dataset-size dataset) 1)
   "one bridge row becomes one dataset row")
  (check-teacher-forcing
   (eq (cl-tpg::dataset-action-format dataset) :semantic-ranked)
   "teacher rows use ranked semantic fitness")
  (check-teacher-forcing
   (equal (aref (cl-tpg::actions dataset) 0) '(8 3 0))
   "selected target/response becomes a compatible semantic triple")
  (check-teacher-forcing
   (equal (aref (cl-tpg::dataset-semantic-rankings dataset) 0)
          '((8 3) (0 0) (8 0)))
   "teacher preference order is preserved")
  (check-teacher-forcing
   (= (aref (cl-tpg::dataset-decoy-masks dataset) 0) 17)
   "pre-action Decoy mask is preserved"))

(let ((cl-tpg::*current-search-mode* :teacher-forcing)
      (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0")
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*num-actions* 11)
      (cl-tpg::*decoy-order-mode* :fixed)
      (cl-tpg::*hamming-space-enabled* nil))
  (check-teacher-forcing
   (string= (cl-tpg::best-team-checkpoint-filename)
            "bline-62-11-teacher-forcing-order-fixed-hamming-off.lisp")
   "checkpoint name identifies teacher forcing without a dataset fingerprint"))

(check-teacher-forcing
 (= cl-tpg::+teacher-trace-chunk-size+ 5)
 "teacher generation has bounded bridge-call chunks")

(format t "~D teacher-forcing checks passed.~%" *teacher-forcing-checks*)
