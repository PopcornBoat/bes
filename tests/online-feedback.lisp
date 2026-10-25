;;; Focused checks for online path probes, nomination, and seed/evaluation rules.
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

(let ((survivor
        (cl-tpg::online-feedback-racing-record
         (list :path "survivor.lisp" :generation 11 :lane :directional
               :returns '(-10.0d0 -9.0d0 -8.0d0))
         '(-10.0d0 -10.0d0 -10.0d0) 3))
      (rejected
        (cl-tpg::online-feedback-racing-record
         (list :path "rejected.lisp" :generation 11 :lane :random
               :returns '(-20.0d0 -20.0d0 -20.0d0))
         '(-10.0d0 -10.0d0 -10.0d0) 3)))
  (check-online-feedback
   (and (eq (getf survivor :lane) :directional)
        (= (getf survivor :stage) 3)
        (= (getf survivor :paired-delta) 1.0d0)
        (getf survivor :continued)
        (not (getf rejected :continued))
        (= (getf rejected :paired-delta) -10.0d0))
   "per-lane audit records the unchanged paired racing decision"))

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
     "the incumbent cannot nominate itself")
    (let ((cl-tpg::*online-feedback-probes*
            (list :parent parent :plus plus :minus nil
                  :site (list :path nil))))
      (check-online-feedback
       (eq (car (cl-tpg::online-feedback-directional-result
                 (list (cons parent -20.0d0)
                       (cons plus -21.0d0))))
           plus)
       "a behavior-changing probe may reach racing despite one-seed loss"))
    (cl-tpg::online-feedback-offer-nomination
     (cons plus -21.0d0) -1.0d0 :directional)
    (dotimes (index 6)
      (cl-tpg::online-feedback-offer-nomination
       (cons (cl-tpg::clone-team parent)
             (- -20.0d0 index))
       (coerce index 'double-float)
       :generation-best))
    (check-online-feedback
     (and (<= (length cl-tpg::*online-feedback-nominations*) 4)
          (find :directional cl-tpg::*online-feedback-nominations*
                :key (lambda (record) (getf record :lane))))
     "directional candidate retains a reserved official racing lane")
    (setf cl-tpg::*online-feedback-nominations* nil)
    (dotimes (index 4)
      (cl-tpg::online-feedback-offer-nomination
       (cons (cl-tpg::clone-team parent) -20.0d0)
       (coerce index 'double-float)
       :generation-best))
    (cl-tpg::online-feedback-offer-nomination
     (cons plus -21.0d0) -1.0d0 :directional)
    (check-online-feedback
     (and (= (length cl-tpg::*online-feedback-nominations*) 4)
          (find :directional cl-tpg::*online-feedback-nominations*
                :key (lambda (record) (getf record :lane))))
     "late directional candidate displaces one generic nomination")))

(check-online-feedback
 (and (not (cl-tpg::online-feedback-local-behavior-p
            '(:top1 0 :ranking 0) 64))
      (cl-tpg::online-feedback-local-behavior-p
       '(:top1 1 :ranking 2) 64)
      (not (cl-tpg::online-feedback-local-behavior-p
            '(:top1 20 :ranking 20) 64)))
 "behavior gate excludes silent and broad changes")

(check-online-feedback
 (and (not (cl-tpg::online-feedback-local-behavior-p
            '(:top1 1 :ranking 1 :concrete 0) 72))
      (cl-tpg::online-feedback-local-behavior-p
       '(:top1 1 :ranking 1 :concrete 1) 72)
      (not (cl-tpg::online-feedback-local-behavior-p
            '(:top1 1 :ranking 1 :concrete 20) 72)))
 "controller-aligned gate requires bounded executed-action change")

(let* ((controller (cl-tpg:make-cage2-controller))
       (scan-state (cl-tpg::cage2-controller-scan-state controller)))
  (setf (aref scan-state 0) 2.0d0
        (cl-tpg::cage2-controller-decoy-mask controller) 17)
  (let ((snapshot
          (cl-tpg::online-feedback-controller-snapshot controller)))
    (setf (aref scan-state 0) 1.0d0
          (cl-tpg::cage2-controller-decoy-mask controller) 0)
    (check-online-feedback
     (and (= (aref (cl-tpg::cage2-controller-scan-state snapshot) 0)
             2.0d0)
          (= (cl-tpg::cage2-controller-decoy-mask snapshot) 17))
     "probe snapshot preserves pre-action controller state")))

(let* ((cl-tpg::*teams* nil)
       (observation
         (make-array 62 :element-type 'double-float
                        :initial-element 0.0d0))
       (first-instruction
         (cl-tpg::%make-instruction
          :dest 0 :op :add :arity 2
          :src1-type :obs :src1-val 0.0d0
          :src2-type :const :src2-val 0.0d0))
       (second-instruction
         (cl-tpg::%make-instruction
          :dest 0 :op :add :arity 2
          :src1-type :obs :src1-val 0.0d0
          :src2-type :const :src2-val 0.15d0))
       (first-learner
         (cl-tpg::make-learner
          :program
            (cl-tpg::make-program
             :instructions
               (make-array 1 :fill-pointer t :adjustable t
                           :initial-contents (list first-instruction)))
          :action
            (cl-tpg::make-action
             :type :atomic
             :action
               (cl-tpg::make-target-response-36-action
                :target 8 :response 2))))
       (second-learner
         (cl-tpg::make-learner
          :program
            (cl-tpg::make-program
             :instructions
               (make-array 1 :fill-pointer t :adjustable t
                           :initial-contents (list second-instruction)))
          :action
            (cl-tpg::make-action
             :type :atomic
             :action
               (cl-tpg::make-target-response-36-action
                :target 7 :response 0))))
       (internal
         (cl-tpg::make-team :id "probe-internal" :type :internal
                            :learners (list first-learner second-learner)))
       (root-learner
         (cl-tpg::make-learner
          :program
            (cl-tpg::make-program
             :instructions
               (make-array 1 :fill-pointer t :adjustable t
                           :initial-contents
                             (list (cl-tpg::%make-instruction
                                    :dest 0 :op :add :arity 2
                                    :src1-type :obs :src1-val 0.0d0
                                    :src2-type :const :src2-val 0.0d0))))
          :action
            (cl-tpg::make-action
             :type :reference :action internal)))
       (root
         (cl-tpg::make-team :id "probe-root"
                            :learners (list root-learner)))
       (site
         (list :path '(0) :learner 0 :instruction 0 :slot :src2))
       (before
         (cl-tpg::serialize-team root
                                 (make-hash-table :test #'equal))))
  (cl-tpg::add-reference internal)
  (check-online-feedback
   (= (length
       (cl-tpg::online-feedback-path-site-records
        root (list observation)))
      2)
   "visited internal team exposes effective bid constants")
  (multiple-value-bind (child created)
      (cl-tpg::online-feedback-perturb-path-child
       root site 0.2d0)
    (check-online-feedback
     (and (not (eq (second (cl-tpg::closure child)) internal))
          (equal
           (first
            (cl-tpg::online-feedback-ranking-pairs
             child observation))
           '(8 2))
          (equal
           (first
            (cl-tpg::online-feedback-ranking-pairs
             root observation))
           '(7 0))
          (equal before
                 (cl-tpg::serialize-team
                  root (make-hash-table :test #'equal))))
     "internal probe changes child routing without mutating parent graph")
    (cl-tpg::online-feedback-discard-path-child created)
    (check-online-feedback
     (and (= (length cl-tpg::*teams*) 2)
          (= (cl-tpg::team-references internal) 1))
     "rejected path copy restores population and references")))

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
