;;; Focused non-simulator checks for bounded detached Phase-5F search memory.

(in-package :cl-user)

(defvar *phase5f-checks* 0)

(defun check-phase5f (condition description)
  (incf *phase5f-checks*)
  (unless condition
    (error "Phase 5F check failed: ~A" description)))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*semantic-locality-control-enabled* t)
      (cl-tpg::*phase4-selection-enabled* t)
      (cl-tpg::*phase5f-near-miss-enabled* t))
  (check-phase5f (cl-tpg::phase5f-active-p)
                 "the isolated Phase-5F feature gate is active"))

(let ((cl-tpg::*current-search-seed* 153))
  (cl-tpg::initialize-official-guided-seed-streams 153)
  (let* ((before (cl-tpg::official-guided-seed-state-copy))
         (lineage (cl-tpg::official-guided-take-seeds :lineage 25)))
    (check-phase5f
     (and (= (getf before :version) 3)
          (= (length lineage) 25)
          (every
           (lambda (seed)
             (= (ash seed
                     (- cl-tpg::+official-guided-seed-payload-bits+))
                6))
           lineage))
     "lineage evaluation has a checkpointed independent seed namespace")
    (cl-tpg::restore-official-guided-seed-streams before)
    (check-phase5f
     (equal lineage (cl-tpg::official-guided-take-seeds :lineage 25))
     "lineage seeds resume at the exact persisted cursor")))

(let ((near-miss
        '(:status :complete :accepted nil
          :evaluation-record
          (:stage :promotion-stage-4
           :tail-audit
           (:aggregate-paired-mean 1.5d0
            :long-paired-mean 0.7d0
            :aggregate-pass nil :long-pass t
            :cvar-pass t :catastrophic-pass t)))))
  (check-phase5f
   (cl-tpg::phase5f-near-miss-eligible-p near-miss)
   "only confidence prevents an otherwise safe positive Stage-4 near miss")
  (let ((unsafe (copy-tree near-miss)))
    (setf (getf (getf (getf unsafe :evaluation-record) :tail-audit)
                :cvar-pass)
          nil)
    (check-phase5f
     (not (cl-tpg::phase5f-near-miss-eligible-p unsafe))
     "a failed tail guard forbids archive admission"))
  (let ((early (copy-tree near-miss)))
    (setf (getf (getf early :evaluation-record) :stage)
          :promotion-stage-3)
    (check-phase5f
     (not (cl-tpg::phase5f-near-miss-eligible-p early))
     "an early-stage positive candidate cannot enter search memory")))

(let* ((team-a (cl-tpg::%make-team :id "ordinary-a" :learners nil))
       (team-b (cl-tpg::%make-team :id "lineage-b" :learners nil))
       (scores (list (cons team-a 10.0d0) (cons team-b 9.0d0)))
       (cl-tpg::*phase5f-lineages*
         (list '(:lineage-id 1 :head-version 0)))
       (cl-tpg::*phase5f-team-lineages* (make-hash-table :test #'eq)))
  (setf (gethash team-b cl-tpg::*phase5f-team-lineages*) '(1 0))
  (let ((cl-tpg::*phase5f-submission-count* 3))
    (check-phase5f
     (eq (car (cl-tpg::phase5f-candidate-entry scores)) team-a)
     "ordinary challengers retain four of each five bounded slots"))
  (let ((cl-tpg::*phase5f-submission-count* 4))
    (check-phase5f
     (eq (car (cl-tpg::phase5f-candidate-entry scores)) team-b)
     "the fifth slot may select the strongest lineage descendant")))

(let* ((team-b (cl-tpg::%make-team :id "lineage-stale" :learners nil))
       (cl-tpg::*phase5f-lineages*
         (list '(:lineage-id 1 :head-version 1)))
       (cl-tpg::*phase5f-team-lineages* (make-hash-table :test #'eq)))
  (setf (gethash team-b cl-tpg::*phase5f-team-lineages*) '(1 0))
  (check-phase5f
   (and (null (cl-tpg::phase5f-lineage-for-team team-b))
        (null (cl-tpg::phase5f-local-comparison-request 1 0)))
   "descendants of an obsolete head cannot request lineage evaluation"))

(let ((record '(:created-generation 900 :age-generations 249
                :reproduction-opportunities 0 :evaluated-descendants 0)))
  (check-phase5f
   (null (cl-tpg::phase5f-lineage-expiry-reason record))
   "lineage remains active immediately before its hard age")
  (incf (getf record :age-generations))
  (check-phase5f
   (eq (cl-tpg::phase5f-lineage-expiry-reason record) :generation-age)
   "persisted age expires independently of a reset displayed generation"))

(let* ((team (cl-tpg::%make-team :id "hash-source" :learners nil))
       (copy (cl-tpg::deep-copy-team-via-serialization team)))
  (check-phase5f
   (and (not (eq team copy))
        (string= (cl-tpg::phase5f-team-graph-hash team)
                 (cl-tpg::phase5f-team-graph-hash copy)))
   "graph identity ignores allocation IDs but deep copies share no root object"))

(let* ((original-paired
         (symbol-function 'cl-tpg::official-guided-paired-rollouts))
       (original-rollout
         (symbol-function 'cl-gym:rollout)))
  (unwind-protect
       (progn
         (setf (symbol-function 'cl-tpg::official-guided-paired-rollouts)
               (lambda (candidate head environment seeds)
                 (declare (ignore candidate head environment))
                 (values
                  (make-list (length seeds) :initial-element 2.0d0)
                  (make-list (length seeds) :initial-element 1.0d0)))
               (symbol-function 'cl-gym:rollout)
               (lambda (team environment seed &key video-path)
                 (declare (ignore team environment seed video-path))
                 0.0d0))
         (let ((evaluation
                 (cl-tpg::phase5f-run-local-comparison
                  :candidate :head :anchor "Cage2-b_line-100-v0"
                  '(1 2 3 4 5)
                  (loop for seed from 6 to 25 collect seed)
                  7 2)))
           (check-phase5f
            (and (getf evaluation :accepted)
                 (eq (getf evaluation :stage) :lineage-confirm)
                 (= (getf evaluation :head-version) 2)
                 (= (getf evaluation :official-rollout-count) 190))
            "local updates require a disjoint screen and all-horizon confirmation")))
    (setf (symbol-function 'cl-tpg::official-guided-paired-rollouts)
          original-paired
          (symbol-function 'cl-gym:rollout)
          original-rollout)))

(let ((cl-tpg::*phase5f-near-miss-enabled* t)
      (cl-tpg::*phase5f-run-id* "run-1")
      (cl-tpg::*phase5f-incumbent-hash* "ABC")
      (cl-tpg::*phase5f-lineages* nil)
      (cl-tpg::*phase5f-variation-root* 123)
      (cl-tpg::*phase5f-variation-cursor* 9)
      (cl-tpg::*phase5f-submission-count* 5))
  (let ((state (cl-tpg::phase5f-state-copy)))
    (cl-tpg::phase5f-reset-state)
    (cl-tpg::phase5f-restore-state state "ABC")
    (check-phase5f
     (and (string= cl-tpg::*phase5f-run-id* "run-1")
          (= cl-tpg::*phase5f-variation-cursor* 9)
          (= cl-tpg::*phase5f-submission-count* 5))
     "small archive/RNG state survives intentional warm-start reconstruction")))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*semantic-locality-control-enabled* t)
      (cl-tpg::*phase4-selection-enabled* t)
      (cl-tpg::*phase5f-near-miss-enabled* t)
      (cl-tpg::*phase5f-run-id* nil)
      (cl-tpg::*current-search-seed* 153))
  (let ((incumbent (cl-tpg::%make-team :id "fresh-incumbent" :learners nil)))
    (cl-tpg::phase5f-initialize-state 153 incumbent)
    (check-phase5f
     (and (stringp cl-tpg::*phase5f-run-id*)
          (string=
           cl-tpg::*phase5f-incumbent-hash*
           (cl-tpg::phase5f-team-graph-hash incumbent)))
     "a fresh run initializes search memory only after an incumbent exists")))

(format t "~D Phase 5F checks passed.~%" *phase5f-checks*)
