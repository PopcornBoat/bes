;;; Focused non-simulator checks for coordinated multi-specialist repair.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *coordinated-repair-checks* 0)

(defun check-coordinated-repair (condition description)
  (incf *coordinated-repair-checks*)
  (unless condition
    (error "Coordinated-repair check failed: ~A" description)))

(defun coordinated-test-program (bid)
  (cl-tpg::make-program
   :instructions
   (make-array
    1 :adjustable t :fill-pointer t
    :initial-contents
    (list
     (cl-tpg::%make-instruction
      :dest 0 :op :add :arity 2
      :src1-type :const :src1-val (coerce bid 'double-float)
      :src2-type :const :src2-val 0.0d0)))))

(defun coordinated-test-learner (bid pair)
  (cl-tpg::make-learner
   :program (coordinated-test-program bid)
   :action
   (cl-tpg::make-action
    :type :atomic
    :action
    (cl-tpg::make-target-response-36-action
     :target (first pair) :response (second pair)))))

(defun coordinated-test-observation (first second)
  (make-array 2 :element-type 'double-float
                :initial-contents (list first second)))

(let* ((teacher-first '(2 0))
       (teacher-second '(3 1))
       (base-pair '(1 0))
       (other-pair '(4 0))
       (target (coordinated-test-observation 1.0d0 1.0d0))
       (background (coordinated-test-observation 0.0d0 0.0d0))
       (observations
         (make-array 8 :initial-contents
                     (list target target target target
                           background background background background)))
       (actions
         (make-array 8 :initial-contents
                     (list '(2 0 0) '(2 0 0) '(2 0 0) '(2 0 0)
                           '(1 0 0) '(1 0 0) '(1 0 0) '(1 0 0))))
       (rankings
         (make-array 8 :initial-contents
                     (append
                      (loop repeat 4
                            collect (list teacher-first teacher-second base-pair))
                      (loop repeat 4
                            collect (list base-pair other-pair)))))
       (dataset
         (cl-tpg::%make-dataset
          :observations observations
          :actions actions
          :rewards (make-array 8 :element-type 'double-float
                                 :initial-element 0.0d0)
          :terminations (make-array 8 :initial-element 0)
          :truncations (make-array 8 :initial-element 0)
          :teacher-actions (make-array 8 :initial-element nil)
          :decoy-masks (make-array 8 :initial-element #xff)
          :semantic-rankings rankings
          :episode-ids (make-array 8 :initial-contents '(1 2 3 4 1 2 3 4))
          :steps (make-array 8 :initial-contents '(12 12 12 12 40 40 40 40))
          :episode-ranges nil
          :size 8
          :action-format :semantic-ranked))
       (parent
         (cl-tpg::%make-team
          :id "coordinated-parent"
          :learners
          (list (coordinated-test-learner 10.0d0 base-pair)
                (coordinated-test-learner 5.0d0 other-pair))))
       (probes
         (cons
          (list :source :test :generation 1 :step 12
                :observation target :teacher-pair teacher-first
                :teacher-ranking
                  (list teacher-first teacher-second base-pair))
          (loop repeat 9
                collect
                (list :source :test :generation 1 :step 40
                      :observation background :teacher-pair base-pair
                      :teacher-ranking (list base-pair other-pair)))))
       (cl-tpg::*teams* (list parent))
       (cl-tpg::*num-observations* 2)
       (cl-tpg::*max-num-learners* 8)
       (cl-tpg::*factored-actions-enabled* t)
       (cl-tpg::*terminal-action-format* :target-response-36)
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*behavioral-locality-enabled* t)
       (cl-tpg::*instruction-set-profile* :reduced-eq)
       (cl-tpg::*instruction-mutation-mode* :field-local)
       (cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
       (cl-tpg::*behavioral-probe-archive* probes)
       (cl-tpg::*behavioral-signature-cache* (make-hash-table :test #'eq))
       (cl-tpg::*behavioral-teacher-action-support*
         (let ((table (make-hash-table :test #'equal)))
           (dolist (pair (list teacher-first teacher-second base-pair other-pair))
             (setf (gethash pair table) t))
           table))
       (cl-tpg::*behavioral-team-lineage* (make-hash-table :test #'eq))
       (cl-tpg::*behavioral-team-parents* (make-hash-table :test #'eq))
       (cl-tpg::*behavioral-generation-records* nil)
       (cl-tpg::*behavioral-locality-sampling-candidates* nil)
       (cl-tpg::*semantic-locality-control-generation-records* nil))
  (let ((plan (cl-tpg::coordinated-repair-parent-plan parent dataset)))
    (check-coordinated-repair
     (and plan (= (length (getf plan :members)) 2)
          (equal (mapcar (lambda (member) (getf member :pair))
                         (getf plan :members))
                 (list teacher-first teacher-second)))
     "the planner retains two categories that repeatedly disappear together")
    (multiple-value-bind (child locality installations)
        (cl-tpg::coordinated-repair-build-child parent dataset plan)
      (check-coordinated-repair child
                                "a screened multi-specialist child is built")
      (check-coordinated-repair
       (= (length installations) 2)
       "both coordinated specialists are installed in the same genotype")
      (check-coordinated-repair
       (equal (subseq (cl-tpg::behavioral-ranking-pairs child target) 0 2)
              (list teacher-first teacher-second))
       "parent-derived bid bands reproduce the teacher's first two categories")
      (check-coordinated-repair
       (equal (first (cl-tpg::behavioral-ranking-pairs child background))
              base-pair)
       "the exact gates preserve background Top-1 behavior")
      (check-coordinated-repair
       (and (getf locality :composition-locality-override)
            (> (getf (getf locality :coordinated-repair-after) :ndcg-sum)
               (getf (getf locality :coordinated-repair-before) :ndcg-sum)))
       "accepted composition records explicit NDCG improvement and locality semantics")))
  )

(cl-tpg::initialize-coordinated-repair-bundle-state 153)
(let* ((before (cl-tpg::coordinated-repair-bundle-state-copy))
       (draw (cl-tpg::coordinated-repair-random-below 1000000)))
  (cl-tpg::restore-coordinated-repair-bundle-state before)
  (check-coordinated-repair
   (= draw (cl-tpg::coordinated-repair-random-below 1000000))
   "restoring bundle scheduler state reproduces the next draw"))

(let ((cl-tpg::*coordinated-repair-bundle-attempted-this-generation* t)
      (cursor cl-tpg::*coordinated-repair-bundle-rng-cursor*))
  (check-coordinated-repair
   (and (not (cl-tpg::coordinated-repair-bundle-slot-p))
        (= cursor cl-tpg::*coordinated-repair-bundle-rng-cursor*))
   "a generation cannot schedule a second bundle child or consume another draw"))

(format t "~D coordinated-repair checks passed.~%"
        *coordinated-repair-checks*)
