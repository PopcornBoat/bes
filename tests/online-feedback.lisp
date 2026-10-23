;;; Read-only checks for online signed probes and seed/evaluation rules.
;;; Load :CL-TPG before this file.
(in-package :cl-user)

(defvar *online-feedback-checks* 0)

(defun check-online-feedback (condition description)
  (incf *online-feedback-checks*)
  (unless condition
    (error "Online feedback check failed: ~A" description)))

(let ((cl-tpg::*current-search-mode* :online)
      (cl-tpg::*current-gym-environment-name* "Cage2-meander-100-v0")
      (cl-tpg::*online-feedback-racing-enabled* t)
      (cl-tpg::*current-search-seed* 153))
  (cl-tpg::reset-online-feedback-state)
  (let* ((racing (cl-tpg::online-feedback-take-seeds :racing 30))
         (promotion (cl-tpg::online-feedback-take-seeds :promotion 100))
         (saved (cl-tpg::online-feedback-state-copy))
         (next-racing (cl-tpg::online-feedback-take-seeds :racing 3)))
    (check-online-feedback
     (and (= (length racing) 30)
          (= (length promotion) 100)
          (null (intersection racing promotion)))
     "racing and promotion streams are separate")
    (cl-tpg::reset-online-feedback-state)
    (cl-tpg::restore-online-feedback-state saved)
    (check-online-feedback
     (equal next-racing (cl-tpg::online-feedback-take-seeds :racing 3))
     "seed cursor resumes exactly")))

(let* ((instruction
         (cl-tpg::%make-instruction
          :dest 0 :op :add :arity 2
          :src1-type :obs :src1-val 0.0d0
          :src2-type :const :src2-val 1.0d0))
       (program
         (cl-tpg::make-program
          :instructions
            (make-array 1 :fill-pointer t :adjustable t
                        :initial-contents (list instruction))))
       (learner
         (cl-tpg::make-learner
          :program program
          :action
            (cl-tpg::make-action
             :type :atomic
             :action
               (cl-tpg::make-target-response-36-action
                :target 8 :response 2))))
       (parent
         (cl-tpg::%make-team :id "feedback-parent"
                              :learners (list learner)))
       (cl-tpg::*teams* nil)
       (sites (cl-tpg::online-feedback-constant-sites parent))
       (plus
         (cl-tpg::online-feedback-perturb-child
          parent (first sites) 0.1d0))
       (minus
         (cl-tpg::online-feedback-perturb-child
          parent (first sites) -0.1d0))
       (observation
         (make-array 62 :element-type 'double-float
                        :initial-element 0.0d0)))
  (check-online-feedback
   (equal sites '((0 0 :src2)))
   "only effective bid constants are probed")
  (check-online-feedback
   (and (= (cl-tpg::bid (first (cl-tpg::team-learners parent)) observation)
           1.0d0)
        (< (abs (- (cl-tpg::bid
                    (first (cl-tpg::team-learners plus)) observation)
                   1.1d0))
           1.0d-9)
        (< (abs (- (cl-tpg::bid
                    (first (cl-tpg::team-learners minus)) observation)
                   0.9d0))
           1.0d-9))
   "both signs are exact and the parent is unchanged")
  (let ((cl-tpg::*best-team* parent)
        (cl-tpg::*online-feedback-nominations* nil))
    (cl-tpg::online-feedback-offer-nomination
     (cons parent -20.0d0) 0.0d0 :generation-best)
    (check-online-feedback
     (null cl-tpg::*online-feedback-nominations*)
     "the incumbent cannot nominate itself")))

(check-online-feedback
 (cl-tpg::online-feedback-continue-p
  '(-2.0d0 -2.0d0 -2.0d0)
  '(0.0d0 0.0d0 0.0d0))
 "small negative evidence does not reject")
(check-online-feedback
 (not (cl-tpg::online-feedback-continue-p
       '(-6.0d0 -6.0d0 -6.0d0)
       '(0.0d0 0.0d0 0.0d0)))
 "clearly futile candidate is rejected")
(check-online-feedback
 (cl-tpg::online-feedback-promotion-p
  '(1.0d0 1.0d0 1.0d0)
  '(0.0d0 0.0d0 0.0d0))
 "positive fresh paired evidence promotes")
(check-online-feedback
 (not (cl-tpg::online-feedback-promotion-p
       '(0.0d0 0.0d0 0.0d0)
       '(0.0d0 0.0d0 0.0d0)))
 "ties cannot promote")

(format t "Online feedback checks passed: ~D.~%" *online-feedback-checks*)
