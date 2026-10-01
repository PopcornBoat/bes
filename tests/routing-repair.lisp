;;; Focused non-simulator checks for targeted routing repair targeted routing repair.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *targeted-routing-checks* 0)

(defun check-targeted-routing (condition description)
  (incf *targeted-routing-checks*)
  (unless condition
    (error "targeted routing repair routing check failed: ~A" description)))

(defun targeted-routing-bid-program (value)
  (cl-tpg::make-program
   :instructions
   (make-array
    1 :adjustable t :fill-pointer t
    :initial-contents
    (list
     (cl-tpg::%make-instruction
      :dest 0 :op :add
      :src1-type :const :src1-val (coerce value 'double-float)
      :src2-type :const :src2-val 0.0d0 :arity 2)))))

(defun targeted-routing-terminal (bid target response)
  (cl-tpg::make-learner
   :program (targeted-routing-bid-program bid)
   :action
   (cl-tpg::make-action
    :type :atomic
    :action
    (cl-tpg::make-target-response-36-action
     :target target :response response))))

(defun targeted-routing-team (id wrong-bid teacher-bid)
  (cl-tpg::%make-team
   :id id
   :learners
   (list (targeted-routing-terminal wrong-bid 3 0)
         (targeted-routing-terminal teacher-bid 2 0))))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*targeted-routing-repair-enabled* t)
      (cl-tpg::*targeted-disagreement-audit-enabled* t)
      (cl-tpg::*semantic-locality-control-enabled* t)
      (cl-tpg::*behavioral-locality-enabled* t)
      (cl-tpg::*terminal-action-format* :target-response-36))
  (check-targeted-routing
   (cl-tpg::targeted-routing-repair-active-p)
   "routing repair activates only under the complete frozen contract"))

;; The isolated scheduling stream round-trips without consuming search RNG.
(let ((cl-tpg::*random-state* (sb-ext:seed-random-state 42)))
  (cl-tpg::initialize-targeted-routing-repair-state 153)
  (cl-tpg::targeted-routing-random-below 1000)
  (let* ((state (cl-tpg::targeted-routing-repair-state-copy))
         (expected (cl-tpg::targeted-routing-random-below 100000)))
    (cl-tpg::initialize-targeted-routing-repair-state 999)
    (cl-tpg::restore-targeted-routing-repair-state state)
    (check-targeted-routing
     (= (cl-tpg::targeted-routing-random-below 100000) expected)
     "routing-repair scheduling resumes at the exact counter")))

(let* ((observation
         (make-array 1 :element-type 'double-float :initial-element 0.0d0))
       (parent (targeted-routing-team "parent" 10 1))
       (child (targeted-routing-team "child" 10 20))
       (dataset
         (cl-tpg::%make-dataset
          :observations (make-array 3 :initial-element observation)
          :actions (make-array 3 :initial-element '(2 0 0))
          :rewards (make-array 3 :element-type 'double-float
                                :initial-element 0.0d0)
          :terminations (make-array 3 :initial-element 0)
          :truncations (make-array 3 :initial-element 0)
          :teacher-actions (make-array 3 :initial-element nil)
          :decoy-masks (make-array 3 :initial-element 0)
          :semantic-rankings
            (make-array 3 :initial-element '((2 0) (3 0)))
          :episode-ids #(1 2 3)
          :steps #(10 11 12)
          :episode-ranges #((0 . 1) (1 . 2) (2 . 3))
          :size 3
          :action-format :semantic-ranked))
       (issue
         '(:case :case-a-routing
           :phase :steps-10-29
           :teacher-pair (2 0)
           :predicted-pair (3 0)
           :occurrences 3
           :episode-count 3
           :systematic-p t))
       (cl-tpg::*num-observations* 1)
       (cl-tpg::*factored-actions-enabled* t)
       (cl-tpg::*terminal-action-format* :target-response-36)
       (contexts
         (cl-tpg::targeted-parent-row-contexts parent dataset issue))
       (comparison
         (cl-tpg::targeted-target-group-comparison child contexts)))
  (check-targeted-routing
   (equal (cl-tpg::targeted-supporting-root-learner-indices parent '(2 0))
          '(1))
   "only the root learner whose action supports the teacher pair is mutable")
  (check-targeted-routing
   (= (length contexts) 3)
   "target rows must reproduce the same systematic disagreement")
  (check-targeted-routing
   (and (= (getf comparison :top1-gains) 3)
        (zerop (getf comparison :top1-losses))
        (= (getf comparison :child-mean-rank) 0.0d0)
        (cl-tpg::targeted-target-comparison-improves-p comparison))
   "a promoted teacher path is recognized as monotonic local repair"))

(check-targeted-routing
 (cl-tpg::targeted-collateral-acceptable-p
  '(:exact-losses 0 :rank-regression-rate 0.05d0)
  '(:top1-hamming 0.20d0 :ranking-distance-mean 0.20d0))
 "the frozen collateral/locality boundary is inclusive")

(check-targeted-routing
 (not
  (cl-tpg::targeted-collateral-acceptable-p
   '(:exact-losses 1 :rank-regression-rate 0.0d0)
   '(:top1-hamming 0.01d0 :ranking-distance-mean 0.01d0)))
 "one previously correct non-target action loss rejects a repair")

;; Checkpoints include the independent repair state and use a distinct name.
(let* ((team (targeted-routing-team "checkpoint" 10 1))
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*targeted-routing-repair-enabled* t)
       (cl-tpg::*checkpoint-directory* nil))
  (cl-tpg::initialize-targeted-routing-repair-state 2026)
  (let ((data (cl-tpg::make-best-team-checkpoint-data team 0.5d0)))
    (check-targeted-routing
     (and (= (getf data :checkpoint-version)
             cl-tpg::+best-team-checkpoint-version+)
          (equal (getf data :targeted-routing-repair-state)
                 (cl-tpg::targeted-routing-repair-state-copy)))
     "the current checkpoint persists the independent repair stream")
    (check-targeted-routing
     (search "official-guided-routing-repair"
             (cl-tpg::best-team-checkpoint-filename))
     "targeted routing repair cannot overwrite the protected grouped selection filename")))

(format t "targeted routing repair routing repair checks passed (~D checks).~%"
        *targeted-routing-checks*)
