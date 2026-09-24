;;; Focused non-simulator checks for grouped epsilon-lexicase Phase 4a.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *phase4-checks* 0)

(defun check-phase4 (condition description)
  (incf *phase4-checks*)
  (unless condition
    (error "Phase-4a check failed: ~A" description)))

(defun phase4-test-team (id)
  (cl-tpg::%make-team :id id :learners nil))

(defun install-phase4-test-scores (teams score-rows)
  (setf cl-tpg::*phase4-team-group-scores*
        (make-hash-table :test #'eq))
  (loop for team in teams
        for row in score-rows
        do (let ((table (make-hash-table :test #'equal)))
             (loop for (key score) on row by #'cddr
                   do (setf (gethash key table) score))
             (setf (gethash team cl-tpg::*phase4-team-group-scores*) table))))

;; Phase cases use recorded step metadata; pair cases require five rows.
(let* ((observation
         (make-array 1 :element-type 'double-float :initial-element 0.0d0))
       (dataset
         (cl-tpg::%make-dataset
          :observations (make-array 8 :initial-element observation)
          :actions
            (make-array 8 :initial-contents
                        '((2 0 0) (2 0 0) (2 0 0) (2 0 0)
                          (2 0 0) (3 1 0) (3 1 0) (3 1 0)))
          :rewards (make-array 8 :element-type 'double-float
                                :initial-element 0.0d0)
          :terminations (make-array 8 :initial-element 0)
          :truncations (make-array 8 :initial-element 0)
          :teacher-actions (make-array 8 :initial-element nil)
          :decoy-masks (make-array 8 :initial-element 0)
          :semantic-rankings (make-array 8 :initial-element '((2 0)))
          :episode-ids #(0 0 0 0 0 0 0 0)
          :steps #(3 4 5 6 7 8 9 10)
          :episode-ranges #((0 . 8))
          :size 8
          :action-format :semantic-ranked))
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*phase4-selection-enabled* t)
       (cl-tpg::*generation* 1))
  (cl-tpg::prepare-phase4-selection-generation dataset)
  (let ((keys (mapcar (lambda (group) (getf group :key))
                      cl-tpg::*phase4-case-groups*)))
    (check-phase4 (member '(:teacher-pair 2 0) keys :test #'equal)
                  "teacher pair with five rows becomes an active case")
    (check-phase4 (not (member '(:teacher-pair 3 1) keys :test #'equal))
                  "teacher pair below five rows remains aggregate/phase-only")
    (check-phase4 (and (member '(:phase :steps-3-9) keys :test #'equal)
                       (member '(:phase :steps-10-29) keys :test #'equal))
                  "phase cases are derived from recorded step indices")))

;; The isolated stream replays exactly and consumes no evolution random values.
(let* ((teams (loop for id in '("a" "b" "c" "d")
                    collect (phase4-test-team id)))
       (key '(:phase :steps-3-9))
       (scores (loop for team in teams
                     for aggregate in '(0.9d0 0.8d0 0.7d0 0.6d0)
                     collect (cons team aggregate)))
       (evolution-state (sb-ext:seed-random-state 777)))
  (setf cl-tpg::*phase4-case-groups*
        (list (list :key key :indices #(0))))
  (install-phase4-test-scores
   teams
   (loop for value in '(1.0d0 0.8d0 0.6d0 0.4d0)
         collect (list key value)))
  (setf cl-tpg::*phase4-group-epsilons* (make-hash-table :test #'equal)
        (gethash key cl-tpg::*phase4-group-epsilons*) 0.0d0)
  (cl-tpg::initialize-phase4-selection-state 153)
  (let* ((saved (cl-tpg::phase4-selection-state-copy))
         (first
           (mapcar (lambda (entry) (cl-tpg::team-id (car entry)))
                   (cl-tpg::phase4-lexicase-survivors
                    scores (first teams) 3))))
    (cl-tpg::restore-phase4-selection-state saved)
    (let ((second
            (mapcar (lambda (entry) (cl-tpg::team-id (car entry)))
                    (cl-tpg::phase4-lexicase-survivors
                     scores (first teams) 3))))
      (check-phase4 (equal first second)
                    "selection RNG checkpoint/restore replays survivors")
      (check-phase4 (and (= (length second) 3)
                         (= (length (remove-duplicates second
                                                       :test #'equal)) 3))
                    "survivor lexicase samples without replacement")
      (check-phase4 (member "a" second :test #'equal)
                    "aggregate champion is force-retained")))
  (let ((baseline
          (let ((*random-state* (make-random-state evolution-state)))
            (random 1000000)))
        (after-selection
          (let ((*random-state* (make-random-state evolution-state)))
            (cl-tpg::initialize-phase4-selection-state 42)
            (cl-tpg::phase4-shuffled-copy '(a b c d e))
            (random 1000000))))
    (check-phase4 (= baseline after-selection)
                  "lexicase does not consume the evolution RNG")))

;; Epsilon is the raw MAD over the full evaluated population, with exact zero.
(let* ((teams (loop for id in '("m0" "m1" "m2" "m3")
                    collect (phase4-test-team id)))
       (key-a '(:phase :steps-10-29))
       (key-b '(:teacher-pair 2 0))
       (scores (loop for team in teams collect (cons team 0.0d0))))
  (setf cl-tpg::*phase4-case-groups*
        (list (list :key key-a :indices #(0))
              (list :key key-b :indices #(1))))
  (install-phase4-test-scores
   teams
   (loop for a in '(0.0d0 1.0d0 2.0d0 100.0d0)
         collect (list key-a a key-b 7.0d0)))
  (cl-tpg::phase4-compute-group-statistics scores)
  (check-phase4 (= (gethash key-a cl-tpg::*phase4-group-epsilons*) 1.0d0)
                "epsilon uses the full pre-selection population raw MAD")
  (check-phase4 (zerop (gethash key-b
                                cl-tpg::*phase4-group-epsilons*))
                "MAD zero remains statistical epsilon zero"))

;; Rescued specialists must beat the champion locally, lose under old scalar
;; truncation, and differ behaviorally on the specialty rows.
(let* ((champion (phase4-test-team "champion"))
       (scalar-survivor (phase4-test-team "scalar-survivor"))
       (specialist (phase4-test-team "specialist"))
       (worst (phase4-test-team "worst"))
       (parent (phase4-test-team "parent"))
       (teams (list champion scalar-survivor specialist worst))
       (key '(:teacher-pair 2 0))
       (group (list :key key :indices #(0 1)))
       (scores (list (cons champion 0.9d0)
                     (cons scalar-survivor 0.8d0)
                     (cons specialist 0.1d0)
                     (cons worst 0.0d0)))
       (cl-tpg::*behavioral-team-parents* (make-hash-table :test #'eq)))
  (setf cl-tpg::*phase4-case-groups* (list group)
        cl-tpg::*phase4-group-medians* (make-hash-table :test #'equal)
        cl-tpg::*phase4-group-epsilons* (make-hash-table :test #'equal)
        cl-tpg::*phase4-team-row-behaviors* (make-hash-table :test #'eq)
        cl-tpg::*phase4-active-specialists* (make-hash-table :test #'eq)
        (gethash key cl-tpg::*phase4-group-medians*) 0.45d0
        (gethash key cl-tpg::*phase4-group-epsilons*) 0.0d0
        (gethash specialist cl-tpg::*behavioral-team-parents*) parent)
  (install-phase4-test-scores
   teams
   (list (list key 0.7d0) (list key 0.4d0)
         (list key 1.0d0) (list key 0.1d0)))
  (setf (gethash champion cl-tpg::*phase4-team-row-behaviors*) #(1 1)
        (gethash scalar-survivor cl-tpg::*phase4-team-row-behaviors*) #(1 1)
        (gethash specialist cl-tpg::*phase4-team-row-behaviors*) #(2 1)
        (gethash worst cl-tpg::*phase4-team-row-behaviors*) #(3 3))
  (check-phase4
   (cl-tpg::phase4-group-behavior-differs-p specialist champion group)
   "specialist signature comparison is restricted to group rows")
  (let* ((summary
           (cl-tpg::phase4-register-specialists
            scores scores (subseq scores 0 2) champion 2))
         (record (gethash specialist cl-tpg::*phase4-active-specialists*)))
    (check-phase4
     (and (= (getf summary :generated-rescued-specialists) 1)
          record
          (not (getf record :would-old-scalar-survive))
          (equal (getf record :direct-parent-id) "parent"))
     "rescued specialist classification includes old-scalar counterfactual")))

;; Deleting a referencing root may promote an internal team back to root; the
;; diagnostic accounting observes that existing behavior without changing it.
(let* ((empty-program
         (cl-tpg::make-program
          :instructions (make-array 0 :adjustable t :fill-pointer t)))
       (inner (phase4-test-team "inner"))
       (reference
         (cl-tpg::make-learner
          :program empty-program
          :action (cl-tpg::make-action :type :reference :action inner)))
       (outer (cl-tpg::%make-team :id "outer" :learners (list reference)))
       (cl-tpg::*teams* (list outer inner))
       (cl-tpg::*phase4-selection-generation-record*
         '(:record-type :phase4a-selection)))
  (cl-tpg::add-reference inner)
  (let ((internal-before (list inner)))
    (cl-tpg::delete-team outer)
    (cl-tpg::phase4-record-root-accounting internal-before)
    (check-phase4
     (and (eq (cl-tpg::team-type inner) :root)
          (= (getf cl-tpg::*phase4-selection-generation-record*
                   :orphaned-internal-root-count) 1)
          (equal (getf cl-tpg::*phase4-selection-generation-record*
                       :reproduction-parent-pool-ids)
                 '("inner")))
     "root/internal/orphan accounting preserves delete-reference semantics")))

;; Preferred traversal instrumentation returns exactly the top-choice path and
;; identifies the team that owns the final atomic winner.
(labels ((bid-program (value)
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
         (terminal (bid target response)
           (cl-tpg::make-learner
            :program (bid-program bid)
            :action
            (cl-tpg::make-action
             :type :atomic
             :action (cl-tpg::make-target-response-36-action
                      :target target :response response)))))
  (let* ((inner (cl-tpg::%make-team :id "path-inner"
                                    :learners (list (terminal 5 2 0))))
         (root
           (cl-tpg::%make-team
            :id "path-root"
            :learners
            (list
             (cl-tpg::make-learner
              :program (bid-program 10)
              :action (cl-tpg::make-action :type :reference :action inner))
             (terminal 1 3 1))))
         (observation
           (make-array 1 :element-type 'double-float :initial-element 0.0d0)))
    (multiple-value-bind (ranking path terminal-team)
        (cl-tpg::execute-team-semantic-ranked root observation 3)
      (check-phase4
       (and (equal (mapcar #'cl-tpg::team-id path)
                   '("path-root" "path-inner"))
            (eq terminal-team inner)
            (equal (cl-tpg::semantic-action-category-pair (first ranking))
                   '(2 0)))
       "visited path and terminal-winning owner do not alter ranked decisions"))
    (let ((cl-tpg::*phase4-active-specialists*
            (make-hash-table :test #'eq)))
      (setf (gethash inner cl-tpg::*phase4-active-specialists*)
            (list :specialty-groups '((:phase :steps-3-9))
                  :visited-count 0 :terminal-winning-count 0))
      (cl-tpg::phase4-note-routing-observation
       '((:phase :steps-3-9)) (list root inner) inner)
      (let ((record (gethash inner cl-tpg::*phase4-active-specialists*)))
        (check-phase4
         (and (= (getf record :visited-count) 1)
              (= (getf record :terminal-winning-count) 1))
         "routing diagnostics count visited and terminal-winning separately")))))

;; Checkpoint metadata carries the exact independent stream state.
(let* ((team (phase4-test-team "checkpoint"))
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*phase4-selection-enabled* t)
       (cl-tpg::*checkpoint-directory* nil))
  (cl-tpg::initialize-phase4-selection-state 2026)
  (cl-tpg::phase4-selection-random-below 10)
  (let* ((expected (cl-tpg::phase4-selection-state-copy))
         (data (cl-tpg::make-best-team-checkpoint-data team 0.5d0))
         (expected-next (cl-tpg::phase4-selection-random-below 100000)))
    (check-phase4
     (and (= (getf data :checkpoint-version) 20)
          (equal (getf data :phase4-selection-state) expected))
     "checkpoint version 20 persists the isolated selection RNG")
    (cl-tpg::initialize-phase4-selection-state 999)
    (cl-tpg::restore-official-guided-runtime-state
     (list :official-guided-incumbent-version 0
           :phase4-selection-state expected)
     "/tmp/nonexistent-phase4-checkpoint.lisp")
    (check-phase4
     (= (cl-tpg::phase4-selection-random-below 100000) expected-next)
     "official-guided resume restores the exact next selection draw")))

;; Historical graph copies remain serialization-deep and independent.
(let* ((program
         (cl-tpg::make-program
          :instructions (make-array 0 :adjustable t :fill-pointer t)))
       (payload
         (cl-tpg::make-target-response-36-action :target 2 :response 0))
       (source
         (cl-tpg::%make-team
          :id "deep-source"
          :learners
          (list (cl-tpg::make-learner
                 :program program
                 :action (cl-tpg::make-action
                          :type :atomic :action payload)))))
       (copy (cl-tpg::deep-copy-team-via-serialization source)))
  (setf (cl-tpg::target-response-36-action-target payload) 9)
  (check-phase4
   (and (not (eq source copy))
        (= (cl-tpg::target-response-36-action-target
            (cl-tpg::action-action
             (cl-tpg::learner-action
              (first (cl-tpg::team-learners copy)))))
           2))
   "historical-best serialization copy remains graph-independent"))

;; A new treatment output directory must still recover the matching journal
;; beside its source checkpoint before it writes its own journal.
(let* ((token (format nil "phase4-source-journal-~D-~D"
                      (get-universal-time) (get-internal-real-time)))
       (base (merge-pathnames (format nil "~A/" token)
                              (uiop:temporary-directory)))
       (source-directory (merge-pathnames "source/" base))
       (output-directory (merge-pathnames "output/" base))
       (checkpoint (merge-pathnames "source-best.lisp" source-directory))
       (journal (merge-pathnames ".official-guided-state.lisp"
                                 source-directory))
       (cl-tpg::*checkpoint-directory* output-directory)
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*phase4-selection-enabled* t))
  (unwind-protect
       (progn
         (ensure-directories-exist checkpoint)
         (cl-tpg::initialize-phase4-selection-state 153)
         (cl-tpg::phase4-selection-random-below 17)
         (let* ((saved (cl-tpg::phase4-selection-state-copy))
                (expected-next
                  (cl-tpg::phase4-selection-random-below 100000)))
           (with-open-file (stream journal :direction :output
                                           :if-exists :supersede
                                           :if-does-not-exist :create)
             (with-standard-io-syntax
               (write (list :version 4
                            :fitness-protocol
                              cl-tpg::+official-guided-fitness-protocol+
                            :checkpoint-filename "source-best.lisp"
                            :incumbent-version 1
                            :phase4-selection-state saved)
                      :stream stream)))
           (cl-tpg::initialize-phase4-selection-state 999)
           (multiple-value-bind (ignored matched-p)
               (cl-tpg::restore-official-guided-runtime-state nil checkpoint)
             (declare (ignore ignored))
             (check-phase4
              (and matched-p
                   (= (cl-tpg::phase4-selection-random-below 100000)
                      expected-next))
              "new output directory resumes the source checkpoint sibling journal"))))
    (when (probe-file base)
      (uiop:delete-directory-tree base :validate t))))

(format t "~D Phase-4a checks passed.~%" *phase4-checks*)
