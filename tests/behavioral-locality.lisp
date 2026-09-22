;;; Focused non-simulator checks for Phase-2 behavioral locality.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *behavioral-locality-checks* 0)

(defun check-behavioral-locality (condition description)
  (incf *behavioral-locality-checks*)
  (unless condition
    (error "Behavioral-locality check failed: ~A" description)))

(let* ((parent-team
         (cl-tpg::%make-team :id "parent" :learners nil))
       (child-team
         (cl-tpg::%make-team :id "child" :learners nil))
       (parent
         '((:ranking ((1 0) (2 1))
            :top1 (1 0) :teacher-rank 0 :off-support nil)
           (:ranking ((3 2) (4 3))
            :top1 (3 2) :teacher-rank 1 :off-support nil)))
       (child
         '((:ranking ((2 1) (1 0))
            :top1 (2 1) :teacher-rank 1 :off-support nil)
           (:ranking ((3 2) (4 3))
            :top1 (3 2) :teacher-rank 1 :off-support t)))
       (cl-tpg::*generation* 7)
       (cl-tpg::*behavioral-probe-revision* 3)
       (record
         (cl-tpg::compare-behavioral-signatures
          parent child '(:instruction-add) parent-team child-team)))
  (check-behavioral-locality
   (= (getf record :top1-hamming) 0.5d0)
   "top-1 Hamming measures changed actions rather than genotype")
  (check-behavioral-locality
   (= (getf record :teacher-rank-changed-rate) 0.5d0)
   "teacher-rank change is retained separately from top-1 change")
  (check-behavioral-locality
   (= (getf record :child-off-support-rate) 0.5d0)
   "teacher support is reported at behavior level")
  (check-behavioral-locality
   (equal (getf record :mutation-events) '((:INSTRUCTION-ADD 1)))
   "mutation layer is attached to the same parent/child record"))

(let* ((observation
         (make-array 3 :element-type 'double-float
                       :initial-contents '(1.0d0 2.0d0 3.0d0)))
       (probe
         (list :source :reference :generation 1 :step 3
               :observation observation
               :teacher-pair '(2 3)
               :teacher-ranking '((2 3) (2 0))))
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*behavioral-locality-enabled* t)
       (cl-tpg::*behavioral-probe-revision* 9)
       (cl-tpg::*behavioral-probe-fixed-reference* (list probe))
       (cl-tpg::*behavioral-probe-fixed-early* (list probe))
       (cl-tpg::*behavioral-probe-archive* (list probe))
       (cl-tpg::*behavioral-locality-sample-cursor* 7)
       (cl-tpg::*behavioral-locality-stratum-counts*
         '((:probe-neutral . 2) (:ranking-only . 1)
           (:small-top1 . 3) (:medium-top1 . 4) (:large-top1 . 5)))
       (state (cl-tpg::behavioral-locality-state-copy)))
  (cl-tpg::reset-behavioral-locality-state)
  (cl-tpg::restore-behavioral-locality-state state)
  (check-behavioral-locality
   (and (= cl-tpg::*behavioral-probe-revision* 9)
        (= (length cl-tpg::*behavioral-probe-archive*) 1)
        (typep (getf (first cl-tpg::*behavioral-probe-archive*) :observation)
               '(simple-array double-float (*)))
        (= cl-tpg::*behavioral-locality-sample-cursor* 7)
        (= (cl-tpg::behavioral-locality-stratum-count :large-top1) 5))
   "probe archive and passive sample cursor round-trip independently"))

(let* ((neutral-team (cl-tpg::%make-team :id "neutral" :learners nil))
       (small-team (cl-tpg::%make-team :id "small" :learners nil))
       (record-base '(:mutation-events ((:INSTRUCTION-ADD 1))))
       (neutral (append record-base
                        '(:top1-hamming 0.0d0
                          :ranking-distance-mean 0.0d0)))
       (small (append record-base
                      '(:top1-hamming 0.02d0
                        :ranking-distance-mean 0.01d0)))
       (cl-tpg::*behavioral-locality-stratum-counts*
         '((:probe-neutral . 3) (:ranking-only . 0)
           (:small-top1 . 0) (:medium-top1 . 0) (:large-top1 . 0)))
       (cl-tpg::*behavioral-locality-sampling-candidates*
         (list (list :child neutral-team :parent neutral-team
                     :record neutral :stratum :probe-neutral)
               (list :child small-team :parent neutral-team
                     :record small :stratum :small-top1)))
       (selected (cl-tpg::select-behavioral-locality-sampling-candidate)))
  (check-behavioral-locality
   (eq (getf selected :stratum) :small-top1)
   "passive sampling selects the least-represented available stratum")
  (check-behavioral-locality
   (and (eq (cl-tpg::behavioral-locality-sampling-stratum neutral)
            :probe-neutral)
        (eq (cl-tpg::behavioral-locality-sampling-stratum small)
            :small-top1))
   "behavioral distance maps to stable sampling strata"))

(let ((cl-tpg::*teacher-reference-dataset* nil)
      (cl-tpg::*behavioral-locality-sample-cursor* 99)
      (legacy '(:version 1
                :protocol :behavioral-locality-phase2-v1
                :revision 4
                :fixed-reference nil
                :fixed-early nil
                :archive nil)))
  (cl-tpg::restore-behavioral-locality-state legacy)
  (check-behavioral-locality
   (and (= cl-tpg::*behavioral-probe-revision* 4)
        (zerop cl-tpg::*behavioral-locality-sample-cursor*)
        (every #'zerop
               (mapcar #'cdr cl-tpg::*behavioral-locality-stratum-counts*)))
   "version-1 Phase-2 checkpoints restore with a fresh diagnostic cursor"))

;; Event recording must not consume extra randomness or change action mutation.
(let* ((seed 24680)
       (state-a (sb-ext:seed-random-state seed))
       (state-b (sb-ext:seed-random-state seed))
       (payload-a (cl-tpg::make-factored-action :primary 2 :secondary 1))
       (payload-b (cl-tpg::make-factored-action :primary 2 :secondary 1))
       result-a next-a result-b next-b events)
  (let ((*random-state* state-a)
        (cl-tpg::*current-search-mode* :official-guided)
        (cl-tpg::*num-actions* 11)
        (cl-tpg::*behavioral-locality-enabled* nil))
    (setf result-a (cl-tpg::mutate-factored-atomic-value payload-a)
          next-a (random 1000000)))
  (let ((*random-state* state-b)
        (cl-tpg::*current-search-mode* :official-guided)
        (cl-tpg::*num-actions* 11)
        (cl-tpg::*behavioral-locality-enabled* t)
        (cl-tpg::*active-mutation-events* nil))
    (setf result-b (cl-tpg::mutate-factored-atomic-value payload-b)
          next-b (random 1000000)
          events (copy-list cl-tpg::*active-mutation-events*)))
  (check-behavioral-locality
   (and (= (cl-tpg::factored-action-primary result-a)
           (cl-tpg::factored-action-primary result-b))
        (= (cl-tpg::factored-action-secondary result-a)
           (cl-tpg::factored-action-secondary result-b))
        (= next-a next-b)
        (= (length events) 1))
   "passive instrumentation preserves the mutation RNG sequence"))

(let* ((instructions
         (make-array 0 :fill-pointer t :adjustable t))
       (program (cl-tpg::make-program :instructions instructions))
       (learner
         (cl-tpg::make-learner
          :program program
          :action
            (cl-tpg::make-action
             :type :atomic
             :action
               (cl-tpg::make-factored-action :primary 2 :secondary 0))))
       (team (cl-tpg::%make-team :id "signature-team"
                                  :learners (list learner)))
       (observation
         (make-array 62 :element-type 'double-float
                        :initial-element 0.0d0))
       (probe
         (list :source :reference :generation 1 :step 3
               :observation observation
               :teacher-pair '(2 0)
               :teacher-ranking '((2 0))))
       (cl-tpg::*behavioral-probe-archive* (list probe))
       (cl-tpg::*behavioral-signature-cache* (make-hash-table :test #'eq))
       (cl-tpg::*behavioral-teacher-action-support*
         (make-hash-table :test #'equal)))
  (setf (gethash '(2 0) cl-tpg::*behavioral-teacher-action-support*) t)
  (let ((signature (cl-tpg::behavioral-policy-signature team)))
    (check-behavioral-locality
     (and (equal (getf (first signature) :top1) '(2 0))
          (= (getf (first signature) :teacher-rank) 0)
          (not (getf (first signature) :off-support)))
     "actual TPG execution produces an executable semantic probe signature")))

(format t "Behavioral-locality checks passed: ~D.~%"
        *behavioral-locality-checks*)
