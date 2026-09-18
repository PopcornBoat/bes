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
      (cl-tpg::*cage2-opening-mode* :fixed)
      (cl-tpg::*teacher-forcing-rollout-mode* :dagger)
      (cl-tpg::*hamming-space-enabled* nil))
  (check-teacher-forcing
   (string= (cl-tpg::best-team-checkpoint-filename)
            "bline-62-11-teacher-forcing-dagger-order-fixed-opening-fixed-hamming-off-memory-stateless.lisp")
   "checkpoint name distinguishes DAgger teacher forcing")
  (let ((cl-tpg::*teacher-forcing-rollout-mode* :teacher))
    (check-teacher-forcing
     (string= (cl-tpg::best-team-checkpoint-filename)
              "bline-62-11-teacher-forcing-order-fixed-opening-fixed-hamming-off-memory-stateless.lisp")
     "pure teacher rollout retains its explicit checkpoint name")))

(let ((cl-tpg::*current-search-mode* :online)
      (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0")
      (cl-tpg::*mixed-training-lineage* t)
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*num-actions* 11)
      (cl-tpg::*decoy-order-mode* :fixed)
      (cl-tpg::*cage2-opening-mode* :fixed)
      (cl-tpg::*hamming-space-enabled* nil))
  (check-teacher-forcing
   (string= (cl-tpg::best-team-checkpoint-filename)
            "bline-62-11-mix-order-fixed-opening-fixed-hamming-off-memory-stateless.lisp")
   "online continuation of an offline lineage uses the mix checkpoint name"))

(let ((cl-tpg::*configured-online-fitness-episodes* 5))
  (check-teacher-forcing
   (equal (mapcar #'cl-tpg::online-fitness-episodes-for-generation
                  '(1 200 201 500 501 1000))
          '(5 5 10 10 20 20))
   "online five-episode launch follows the staged curriculum"))

(let ((cl-tpg::*configured-online-fitness-episodes* 7))
  (check-teacher-forcing
   (= (cl-tpg::online-fitness-episodes-for-generation 1000) 7)
   "non-five online episode settings remain fixed"))

(multiple-value-bind (accepted delta margin)
    (cl-tpg::online-reference-promotion-p
     '(2.0d0 2.0d0 2.0d0)
     '(1.0d0 1.0d0 1.0d0))
  (check-teacher-forcing
   (and accepted (= delta 1.0d0) (= margin 0.0d0))
   "consistent paired improvement passes the online promotion guard"))

(multiple-value-bind (accepted delta margin)
    (cl-tpg::online-reference-promotion-p
     '(2.0d0 0.0d0)
     '(0.0d0 0.0d0))
  (check-teacher-forcing
   (and (not accepted) (= delta margin))
   "mean improvement equal to its standard error is rejected as noise"))

(multiple-value-bind (continued delta uncertainty)
    (cl-tpg::online-candidate-screen-worthy-p
     '(0.0d0 1.0d0 0.0d0 1.0d0)
     '(1.0d0 1.0d0 1.0d0 1.0d0))
  (declare (ignore delta uncertainty))
  (check-teacher-forcing
   (not continued)
   "staged evaluator rejects a clearly futile reference prefix"))

(multiple-value-bind (continued delta uncertainty)
    (cl-tpg::online-candidate-screen-worthy-p
     '(2.0d0 0.0d0)
     '(0.0d0 0.0d0))
  (check-teacher-forcing
   (and continued (= delta uncertainty))
   "uncertain first-stage candidates continue to the full reference bank"))

(check-teacher-forcing
 (= cl-tpg::+online-candidate-evaluation-interval+ 10)
 "online candidate evaluation is periodic instead of generation-blocking")

(check-teacher-forcing
 (= cl-tpg::+teacher-trace-chunk-size+ 5)
 "teacher generation has bounded bridge-call chunks")

(check-teacher-forcing
 (and (cl-tpg::valid-cage2-opening-mode-p :fixed)
      (cl-tpg::valid-cage2-opening-mode-p :policy)
      (not (cl-tpg::valid-cage2-opening-mode-p :evolved)))
 "only fixed-controller and full-policy opening modes are accepted")

(check-teacher-forcing
 (and (cl-tpg::valid-teacher-forcing-rollout-mode-p :dagger)
      (cl-tpg::valid-teacher-forcing-rollout-mode-p :teacher)
      (not (cl-tpg::valid-teacher-forcing-rollout-mode-p :online)))
 "only DAgger and pure-teacher rollout modes are accepted")

(let* ((all-target-one-decoys-used (1- (ash 1 8)))
       (ranking '((1 3) (2 2) (2 0))))
  (check-teacher-forcing
   (equal (cl-tpg::resolve-teacher-pair-ranking
           ranking all-target-one-decoys-used)
          '(2 0))
   "teacher resolver skips exhausted Decoy and fallback Restore")
  (check-teacher-forcing
   (equal (cl-tpg::resolve-teacher-pair-ranking '((0 0) (1 0)) 0)
          '(0 0))
   "teacher resolver accepts GLOBAL immediately"))

(let ((cl-tpg::*teacher-dagger-replay-rows* nil)
      (cl-tpg::*teacher-dagger-random-state*
        (sb-ext:seed-random-state 153)))
  (let ((observation (loop repeat 142 collect 0.0d0)))
    (cl-tpg::append-teacher-dagger-replay
     (list (list observation '(8 3) '((8 3) (0 0)) 0)
           (list observation '(2 0) '((2 0) (0 0)) 0)
           (list observation '(0 0) '((0 0)) 0))))
  (check-teacher-forcing
   (every
    (lambda (row)
      (typep (first row) '(simple-array double-float (*))))
    cl-tpg::*teacher-dagger-replay-rows*)
   "DAgger replay stores compact double-float observation arrays")
  (let ((sample (cl-tpg::sample-teacher-dagger-replay 2)))
    (check-teacher-forcing
     (and (= (length sample) 2)
          (= (length (remove-duplicates sample :test #'eq)) 2))
     "DAgger replay samples without replacement")))

(let ((cl-tpg::*cage2-opening-mode* :fixed))
  (check-teacher-forcing
   (equal (loop for step below 3
                collect
                (cl-gym::cage2-fixed-opening-action
                 "Cage2-b_line-100-v0" step))
          '(((8 3)) ((8 3)) ((2 3))))
   "fixed opening returns the three main-agent probe actions")
  (check-teacher-forcing
   (null (cl-gym::cage2-fixed-opening-action
          "Cage2-b_line-100-v0" 3))
   "TPG begins acting at step three"))

(let ((cl-tpg::*cage2-opening-mode* :policy))
  (check-teacher-forcing
   (null (cl-gym::cage2-fixed-opening-action
          "Cage2-b_line-100-v0" 0))
   "policy opening leaves step zero under TPG control"))

(format t "~D teacher-forcing checks passed.~%" *teacher-forcing-checks*)
