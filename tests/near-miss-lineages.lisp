;;; Focused non-simulator checks for bounded detached near-miss lineage search memory.

(in-package :cl-user)

(defvar *near-miss-checks* 0)

(defun check-near-miss (condition description)
  (incf *near-miss-checks*)
  (unless condition
    (error "near-miss lineage check failed: ~A" description)))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*semantic-locality-control-enabled* t)
      (cl-tpg::*grouped-selection-enabled* t)
      (cl-tpg::*near-miss-lineages-enabled* t))
  (check-near-miss (cl-tpg::near-miss-active-p)
                 "the isolated near-miss lineage feature gate is active"))

(let ((cl-tpg::*current-search-seed* 153))
  (cl-tpg::initialize-official-guided-seed-streams 153)
  (let* ((before (cl-tpg::official-guided-seed-state-copy))
         (lineage (cl-tpg::official-guided-take-seeds :lineage 25)))
    (check-near-miss
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
    (check-near-miss
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
  (check-near-miss
   (cl-tpg::near-miss-lineages-eligible-p near-miss)
   "only confidence prevents an otherwise safe positive Stage-4 near miss")
  (let ((unsafe (copy-tree near-miss)))
    (setf (getf (getf (getf unsafe :evaluation-record) :tail-audit)
                :cvar-pass)
          nil)
    (check-near-miss
     (not (cl-tpg::near-miss-lineages-eligible-p unsafe))
     "a failed tail guard forbids archive admission"))
  (let ((early (copy-tree near-miss)))
    (setf (getf (getf early :evaluation-record) :stage)
          :promotion-stage-3)
    (check-near-miss
     (not (cl-tpg::near-miss-lineages-eligible-p early))
     "an early-stage positive candidate cannot enter search memory")))

(let* ((team-a (cl-tpg::%make-team :id "ordinary-a" :learners nil))
       (team-b (cl-tpg::%make-team :id "lineage-b" :learners nil))
       (scores (list (cons team-a 10.0d0) (cons team-b 9.0d0)))
       (cl-tpg::*near-miss-lineages*
         (list '(:lineage-id 1 :head-version 0)))
       (cl-tpg::*near-miss-team-lineages* (make-hash-table :test #'eq)))
  (setf (gethash team-b cl-tpg::*near-miss-team-lineages*) '(1 0))
  (let ((cl-tpg::*near-miss-submission-count* 3))
    (check-near-miss
     (eq (car (cl-tpg::near-miss-candidate-entry scores)) team-a)
     "ordinary challengers retain four of each five bounded slots"))
  (let ((cl-tpg::*near-miss-submission-count* 4))
    (check-near-miss
     (eq (car (cl-tpg::near-miss-candidate-entry scores)) team-b)
     "the fifth slot may select the strongest lineage descendant")))

(let* ((team-b (cl-tpg::%make-team :id "lineage-stale" :learners nil))
       (cl-tpg::*near-miss-lineages*
         (list '(:lineage-id 1 :head-version 1)))
       (cl-tpg::*near-miss-team-lineages* (make-hash-table :test #'eq)))
  (setf (gethash team-b cl-tpg::*near-miss-team-lineages*) '(1 0))
  (check-near-miss
   (and (null (cl-tpg::near-miss-lineage-for-team team-b))
        (null (cl-tpg::near-miss-local-comparison-request 1 0)))
   "descendants of an obsolete head cannot request lineage evaluation"))

(let ((record '(:created-generation 900 :age-generations 249
                :reproduction-opportunities 0 :evaluated-descendants 0)))
  (check-near-miss
   (null (cl-tpg::near-miss-lineage-expiry-reason record))
   "lineage remains active immediately before its hard age")
  (incf (getf record :age-generations))
  (check-near-miss
   (eq (cl-tpg::near-miss-lineage-expiry-reason record) :generation-age)
   "persisted age expires independently of a reset displayed generation"))

(let* ((team (cl-tpg::%make-team :id "hash-source" :learners nil))
       (copy (cl-tpg::deep-copy-team-via-serialization team)))
  (check-near-miss
   (and (not (eq team copy))
        (string= (cl-tpg::near-miss-team-graph-hash team)
                 (cl-tpg::near-miss-team-graph-hash copy)))
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
                 (cl-tpg::near-miss-run-local-comparison
                  :candidate :head :anchor "Cage2-b_line-100-v0"
                  '(1 2 3 4 5)
                  (loop for seed from 6 to 25 collect seed)
                  7 2)))
           (check-near-miss
            (and (getf evaluation :accepted)
                 (eq (getf evaluation :stage) :lineage-confirm)
                 (= (getf evaluation :head-version) 2)
                 (= (getf evaluation :official-rollout-count) 190))
            "local updates require a disjoint screen and all-horizon confirmation")))
    (setf (symbol-function 'cl-tpg::official-guided-paired-rollouts)
          original-paired
          (symbol-function 'cl-gym:rollout)
          original-rollout)))

(let ((cl-tpg::*near-miss-lineages-enabled* t)
      (cl-tpg::*near-miss-run-id* "run-1")
      (cl-tpg::*near-miss-incumbent-hash* "ABC")
      (cl-tpg::*near-miss-lineages* nil)
      (cl-tpg::*near-miss-variation-root* 123)
      (cl-tpg::*near-miss-variation-cursor* 9)
      (cl-tpg::*near-miss-submission-count* 5))
  (let ((state (cl-tpg::near-miss-state-copy)))
    (cl-tpg::near-miss-reset-state)
    (cl-tpg::near-miss-restore-state state "ABC")
    (check-near-miss
     (and (string= cl-tpg::*near-miss-run-id* "run-1")
          (= cl-tpg::*near-miss-variation-cursor* 9)
          (= cl-tpg::*near-miss-submission-count* 5))
     "small archive/RNG state survives intentional warm-start reconstruction")))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*semantic-locality-control-enabled* t)
      (cl-tpg::*grouped-selection-enabled* t)
      (cl-tpg::*near-miss-lineages-enabled* t)
      (cl-tpg::*near-miss-run-id* nil)
      (cl-tpg::*current-search-seed* 153))
  (let ((incumbent (cl-tpg::%make-team :id "fresh-incumbent" :learners nil)))
    (cl-tpg::near-miss-initialize-state 153 incumbent)
    (check-near-miss
     (and (stringp cl-tpg::*near-miss-run-id*)
          (string=
           cl-tpg::*near-miss-incumbent-hash*
           (cl-tpg::near-miss-team-graph-hash incumbent)))
     "a fresh run initializes search memory only after an incumbent exists")))

(format t "~D near-miss lineage checks passed.~%" *near-miss-checks*)
