;;; Focused non-simulator checks for behaviorally changed compiled-donor seeding.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *compiled-donor-checks* 0)

(defun check-compiled-donor (condition description)
  (incf *compiled-donor-checks*)
  (unless condition
    (error "Compiled donor check failed: ~A" description)))

(defun compiled-donor-read-request ()
  (with-open-file
      (stream
        (asdf:system-relative-pathname
         "cl-tpg" "experiments/compiled-heuristic-donor.sexp")
        :direction :input)
    (read stream)))

(let ((request (compiled-donor-read-request)))
  (check-compiled-donor
   (and (eq (getf request :type) :resume-search)
        (eq (getf request :compiled-heuristic-donor-seeding-enabled)
            :enabled)
        (eq (getf request :population-diversity-pulse-enabled) :disabled)
        (= (getf request :compiled-heuristic-donor-fraction) 0.10d0))
   "the experiment is an isolated warm-start donor treatment")
  (check-compiled-donor
   (cl-tpg::valid-search-parameters-p
    (getf request :mode) (getf request :gym-environment-name)
    (getf request :dataset-name) (getf request :num-observations)
    (getf request :num-actions) (getf request :population-size)
    (getf request :init-num-learners) (getf request :max-num-learners)
    (getf request :p-add) (getf request :p-del) (getf request :p-mut)
    (getf request :p-act) (getf request :p-swap) (getf request :gap)
    (getf request :init-program-size) (getf request :max-program-size)
    (getf request :p-add-instr) (getf request :p-del-instr)
    (getf request :p-swap-instrs) (getf request :p-mut-constant)
    (getf request :p-mut-constant-sign) (getf request :migration-interval)
    (getf request :batch-size) (getf request :seed)
    nil :none (getf request :decoy-order-mode)
    (getf request :cage2-opening-mode) nil
    (getf request :teacher-forcing-rollout-mode)
    (getf request :teacher-backend) (getf request :instruction-set-profile)
    (getf request :instruction-mutation-mode) t nil nil
    (getf request :read-only-register-profile) nil nil nil nil nil 0.5d0
    t (getf request :compiled-heuristic-donor-checkpoint)
    (getf request :compiled-heuristic-donor-fraction)
    (getf request :compiled-heuristic-donor-max-top1-hamming))
   "the donor request is server-valid"))

(let* ((cl-tpg::*population-size* 4)
       (cl-tpg::*init-num-learners* 1)
       (cl-tpg::*init-program-size* 1)
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*num-actions* 36)
       (cl-tpg::*terminal-action-format* :target-response-36)
       (cl-tpg::*factored-actions-enabled* t)
       (cl-tpg::*teams* nil)
       (loaded (cl-tpg::make-team))
       (internal (cl-tpg::make-team)))
  (setf (cl-tpg::learner-action
         (first (cl-tpg::team-learners loaded)))
        (cl-tpg::make-action :type :reference :action internal))
  (cl-tpg::add-reference internal)
  ;; Reproduce the stale historical tag seen in the evolved v13 checkpoint.
  (setf (cl-tpg::team-type internal) :root
        cl-tpg::*teams* nil)
  (cl-tpg::make-initial-population)
  (cl-tpg::inject-loaded-best-team-into-population loaded)
  (check-compiled-donor
   (and (= (length (cl-tpg::root-teams)) 4)
        (eq (cl-tpg::team-type internal) :internal))
   "warm-start injection normalizes stale internal root tags"))

(let* ((cl-tpg::*compiled-heuristic-donor-seeding-enabled* t)
       (cl-tpg::*compiled-heuristic-donor-checkpoint*
         (namestring
          (asdf:system-relative-pathname
           "cl-tpg"
           "oracles/checkpoints/bline-62-36-compiled-heuristic.lisp")))
       (cl-tpg::*compiled-heuristic-donor-fraction* 0.20d0)
       (cl-tpg::*compiled-heuristic-donor-max-top1-hamming* 1.0d0)
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*current-search-seed* 153)
       (cl-tpg::*terminal-action-format* :target-response-36)
       (cl-tpg::*factored-actions-enabled* t)
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*num-actions* 36)
       (cl-tpg::*population-size* 10)
       (cl-tpg::*init-num-learners* 2)
       (cl-tpg::*max-num-learners* 32)
       (cl-tpg::*init-program-size* 4)
       (cl-tpg::*max-program-size* 256)
       (cl-tpg::*instruction-set-profile* :reduced-eq)
       (cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
       (cl-tpg::*instruction-mutation-mode* :field-local)
       (cl-tpg::*effective-aware-mutation-enabled* t)
       (cl-tpg::*p-mut* 0.5d0)
       (cl-tpg::*p-add-instr* 0.9d0)
       (cl-tpg::*p-del-instr* 0.5d0)
       (cl-tpg::*p-swap-instrs* 1.0d0)
       (cl-tpg::*p-mut-constant* 0.5d0)
       (cl-tpg::*p-mut-constant-sign* 0.1d0)
       (cl-tpg::*recurrent-policy-enabled* nil)
       (cl-tpg::*behavioral-locality-enabled* t)
       (cl-tpg::*behavioral-signature-cache* (make-hash-table :test #'eq))
       (cl-tpg::*behavioral-teacher-action-support*
         (make-hash-table :test #'equal))
       (cl-tpg::*behavioral-probe-revision* 1)
       (cl-tpg::*behavioral-probe-archive*
         (loop for index in '(4 5 6 7 8 9 10 11 12 13 14 15
                              28 29 30 31 53 54 55 56)
               for observation =
                 (make-array 62 :element-type 'double-float
                                :initial-element 0.0d0)
               do (setf (aref observation index) 1.0d0)
               collect (list :source :test
                             :observation observation
                             :teacher-pair '(2 3))))
       (cl-tpg::*generation* 1)
       (cl-tpg::*checkpoint-directory* nil)
       (cl-tpg::*teams* nil)
       (cl-tpg::*best-team* nil)
       (cl-tpg::*compiled-heuristic-donor-lineages*
         (make-hash-table :test #'eq))
       (cl-tpg::*random-state* (sb-ext:seed-random-state 9917)))
  (loop for target across cl-tpg::*semantic-36-targets*
        do (loop for response below cl-tpg::+num-semantic-responses+
                 do (setf (gethash (list target response)
                                   cl-tpg::*behavioral-teacher-action-support*)
                          t)))
  (cl-tpg::make-initial-population)
  (let* ((protected (first (cl-tpg::root-teams)))
         (roots-before (length (cl-tpg::root-teams)))
         (expected-next-random
           (let ((state (make-random-state cl-tpg::*random-state*)))
             (random 1000000 state)))
         (record
           (cl-tpg::install-compiled-heuristic-donor-cohort protected)))
    (check-compiled-donor
     (= roots-before (length (cl-tpg::root-teams)))
     "cohort installation preserves population size")
    (check-compiled-donor
     (member protected (cl-tpg::root-teams) :test #'eq)
     "the evolved warm-start root is never replaced")
    (check-compiled-donor
     (and (= (getf record :descendants) 2)
          (null (getf record :donor-installed))
          (zerop (getf record :exact-donor-descendants))
          (every #'plusp (getf record :top1-hamming)))
     "only mandatory behaviorally changed descendants enter the population")
    (check-compiled-donor
     (= expected-next-random (random 1000000 cl-tpg::*random-state*))
     "donor construction does not consume ordinary evolution RNG")
    (let* ((origin
             (find-if
              (lambda (team)
                (cl-tpg::compiled-heuristic-donor-lineage-for team))
              (cl-tpg::root-teams)))
           (child (cl-tpg::deep-copy-team-via-serialization origin))
           (origin-lineage
             (cl-tpg::compiled-heuristic-donor-lineage-for origin)))
      (cl-tpg::compiled-heuristic-donor-note-descendant origin child)
      (let ((child-lineage
              (cl-tpg::compiled-heuristic-donor-lineage-for child)))
        (check-compiled-donor
         (and origin-lineage
              child-lineage
              (= (getf child-lineage :origin-index)
                 (getf origin-lineage :origin-index))
              (= (getf child-lineage :depth) 1)
              (equal (getf child-lineage :parent-team-id)
                     (cl-tpg::team-id origin)))
         "ordinary descendants inherit donor provenance without installing the donor")))))

(let* ((cl-tpg::*compiled-heuristic-donor-seeding-enabled* t)
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0")
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*num-actions* 36)
       (cl-tpg::*instruction-set-profile* :reduced-eq)
       (cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
       (cl-tpg::*terminal-action-format* :target-response-36)
       (cl-tpg::*compiled-heuristic-donor-checkpoint* "donor.lisp")
       (cl-tpg::*compiled-heuristic-donor-fraction* 0.10d0)
       (cl-tpg::*compiled-heuristic-donor-max-top1-hamming* 0.25d0)
       (cl-tpg::*compiled-heuristic-donor-last-record*
         '(:descendants 16 :donor-installed nil))
       (cl-tpg::*compiled-heuristic-donor-best-lineage*
         '(:origin-index 3 :depth 7 :team-id 919))
       (team (cl-tpg::%make-team :learners nil))
       (data (cl-tpg::make-best-team-checkpoint-data team 0.0d0)))
  (check-compiled-donor
   (and (getf data :compiled-heuristic-donor-seeding-enabled)
        (eq (getf data :compiled-heuristic-donor-protocol)
            cl-tpg::+compiled-heuristic-donor-protocol+)
        (= (getf data :compiled-heuristic-donor-fraction) 0.10d0)
        (equal (getf data :compiled-heuristic-donor-record)
               '(:descendants 16 :donor-installed nil))
        (equal (getf data :compiled-heuristic-donor-best-lineage)
               '(:origin-index 3 :depth 7 :team-id 919)))
   "checkpoint metadata records donor protocol and cohort provenance")
  (check-compiled-donor
   (search "compiled-donor" (cl-tpg::best-team-checkpoint-filename))
   "checkpoint filenames isolate donor experiments"))

(format t "~D compiled heuristic donor checks passed.~%"
        *compiled-donor-checks*)
