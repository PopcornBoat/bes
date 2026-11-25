;;; Focused non-simulator checks for grouped epsilon-lexicase grouped selection.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *grouped-checks* 0)

(defun check-grouped-selection (condition description)
  (incf *grouped-checks*)
  (unless condition
    (error "grouped selection check failed: ~A" description)))

(defun grouped-test-team (id)
  (cl-tpg::%make-team :id id :learners nil))

(defun install-grouped-test-scores (teams score-rows)
  (setf cl-tpg::*grouped-team-group-scores*
        (make-hash-table :test #'eq))
  (loop for team in teams
        for row in score-rows
        do (let ((table (make-hash-table :test #'equal)))
             (loop for (key score) on row by #'cddr
                   do (setf (gethash key table) score))
             (setf (gethash team cl-tpg::*grouped-team-group-scores*) table))))

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
       (cl-tpg::*grouped-selection-enabled* t)
       (cl-tpg::*generation* 1))
  (cl-tpg::prepare-grouped-selection-generation dataset)
  (let ((keys (mapcar (lambda (group) (getf group :key))
                      cl-tpg::*grouped-case-groups*)))
    (check-grouped-selection (member '(:teacher-pair 2 0) keys :test #'equal)
                  "teacher pair with five rows becomes an active case")
    (check-grouped-selection (not (member '(:teacher-pair 3 1) keys :test #'equal))
                  "teacher pair below five rows remains aggregate/phase-only")
    (check-grouped-selection (and (member '(:phase :steps-3-9) keys :test #'equal)
                       (member '(:phase :steps-10-29) keys :test #'equal))
                  "phase cases are derived from recorded step indices")))

;; The isolated stream replays exactly and consumes no evolution random values.
(let* ((teams (loop for id in '("a" "b" "c" "d")
                    collect (grouped-test-team id)))
       (key '(:phase :steps-3-9))
       (scores (loop for team in teams
                     for aggregate in '(0.9d0 0.8d0 0.7d0 0.6d0)
                     collect (cons team aggregate)))
       (evolution-state (sb-ext:seed-random-state 777)))
  (setf cl-tpg::*grouped-case-groups*
        (list (list :key key :indices #(0))))
  (install-grouped-test-scores
   teams
   (loop for value in '(1.0d0 0.8d0 0.6d0 0.4d0)
         collect (list key value)))
  (setf cl-tpg::*grouped-group-epsilons* (make-hash-table :test #'equal)
        (gethash key cl-tpg::*grouped-group-epsilons*) 0.0d0)
  (cl-tpg::initialize-grouped-selection-state 153)
  (let* ((saved (cl-tpg::grouped-selection-state-copy))
         (first
           (mapcar (lambda (entry) (cl-tpg::team-id (car entry)))
                   (cl-tpg::grouped-lexicase-survivors
                    scores (first teams) 3))))
    (cl-tpg::restore-grouped-selection-state saved)
    (let ((second
            (mapcar (lambda (entry) (cl-tpg::team-id (car entry)))
                    (cl-tpg::grouped-lexicase-survivors
                     scores (first teams) 3))))
      (check-grouped-selection (equal first second)
                    "selection RNG checkpoint/restore replays survivors")
      (check-grouped-selection (and (= (length second) 3)
                         (= (length (remove-duplicates second
                                                       :test #'equal)) 3))
                    "survivor lexicase samples without replacement")
      (check-grouped-selection (member "a" second :test #'equal)
                    "aggregate champion is force-retained")))
  (cl-tpg::initialize-grouped-selection-state 153)
  (let ((forced
          (mapcar (lambda (entry) (cl-tpg::team-id (car entry)))
                  (cl-tpg::grouped-lexicase-survivors
                   scores (first teams) 3 (list (fourth teams))))))
    (check-grouped-selection
     (and (= (length forced) 3)
          (member "a" forced :test #'equal)
          (member "d" forced :test #'equal))
     "a bounded return-credit anchor consumes one ordinary survivor slot"))
  (let ((baseline
          (let ((*random-state* (make-random-state evolution-state)))
            (random 1000000)))
        (after-selection
          (let ((*random-state* (make-random-state evolution-state)))
            (cl-tpg::initialize-grouped-selection-state 42)
            (cl-tpg::grouped-shuffled-copy '(a b c d e))
            (random 1000000))))
    (check-grouped-selection (= baseline after-selection)
                  "lexicase does not consume the evolution RNG")))

;; Epsilon is the raw MAD over the full evaluated population, with exact zero.
(let* ((teams (loop for id in '("m0" "m1" "m2" "m3")
                    collect (grouped-test-team id)))
       (key-a '(:phase :steps-10-29))
       (key-b '(:teacher-pair 2 0))
       (scores (loop for team in teams collect (cons team 0.0d0))))
  (setf cl-tpg::*grouped-case-groups*
        (list (list :key key-a :indices #(0))
              (list :key key-b :indices #(1))))
  (install-grouped-test-scores
   teams
   (loop for a in '(0.0d0 1.0d0 2.0d0 100.0d0)
         collect (list key-a a key-b 7.0d0)))
  (cl-tpg::grouped-compute-group-statistics scores)
  (check-grouped-selection (= (gethash key-a cl-tpg::*grouped-group-epsilons*) 1.0d0)
                "epsilon uses the full pre-selection population raw MAD")
  (check-grouped-selection (zerop (gethash key-b
                                cl-tpg::*grouped-group-epsilons*))
                "MAD zero remains statistical epsilon zero"))

;; Rescued specialists must beat the champion locally, lose under old scalar
;; truncation, and differ behaviorally on the specialty rows.
(let* ((champion (grouped-test-team "champion"))
       (scalar-survivor (grouped-test-team "scalar-survivor"))
       (specialist (grouped-test-team "specialist"))
       (worst (grouped-test-team "worst"))
       (parent (grouped-test-team "parent"))
       (teams (list champion scalar-survivor specialist worst))
       (key '(:teacher-pair 2 0))
       (group (list :key key :indices #(0 1)))
       (scores (list (cons champion 0.9d0)
                     (cons scalar-survivor 0.8d0)
                     (cons specialist 0.1d0)
                     (cons worst 0.0d0)))
       (cl-tpg::*behavioral-team-parents* (make-hash-table :test #'eq)))
  (setf cl-tpg::*grouped-case-groups* (list group)
        cl-tpg::*grouped-group-medians* (make-hash-table :test #'equal)
        cl-tpg::*grouped-group-epsilons* (make-hash-table :test #'equal)
        cl-tpg::*grouped-team-row-behaviors* (make-hash-table :test #'eq)
        cl-tpg::*grouped-active-specialists* (make-hash-table :test #'eq)
        (gethash key cl-tpg::*grouped-group-medians*) 0.45d0
        (gethash key cl-tpg::*grouped-group-epsilons*) 0.0d0
        (gethash specialist cl-tpg::*behavioral-team-parents*) parent)
  (install-grouped-test-scores
   teams
   (list (list key 0.7d0) (list key 0.4d0)
         (list key 1.0d0) (list key 0.1d0)))
  (setf (gethash champion cl-tpg::*grouped-team-row-behaviors*) #(1 1)
        (gethash scalar-survivor cl-tpg::*grouped-team-row-behaviors*) #(1 1)
        (gethash specialist cl-tpg::*grouped-team-row-behaviors*) #(2 1)
        (gethash worst cl-tpg::*grouped-team-row-behaviors*) #(3 3))
  (check-grouped-selection
   (cl-tpg::grouped-group-behavior-differs-p specialist champion group)
   "specialist signature comparison is restricted to group rows")
  (let* ((summary
           (cl-tpg::grouped-register-specialists
            scores scores (subseq scores 0 2) champion 2))
         (record (gethash specialist cl-tpg::*grouped-active-specialists*)))
    (check-grouped-selection
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
       (inner (grouped-test-team "inner"))
       (reference
         (cl-tpg::make-learner
          :program empty-program
          :action (cl-tpg::make-action :type :reference :action inner)))
       (outer (cl-tpg::%make-team :id "outer" :learners (list reference)))
       (cl-tpg::*teams* (list outer inner))
       (cl-tpg::*grouped-selection-generation-record*
         '(:record-type :grouped-selection-selection)))
  (cl-tpg::add-reference inner)
  (let ((internal-before (list inner)))
    (cl-tpg::delete-team outer)
    (cl-tpg::grouped-record-root-accounting internal-before)
    (check-grouped-selection
     (and (eq (cl-tpg::team-type inner) :root)
          (= (getf cl-tpg::*grouped-selection-generation-record*
                   :orphaned-internal-root-count) 1)
          (equal (getf cl-tpg::*grouped-selection-generation-record*
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
      (check-grouped-selection
       (and (equal (mapcar #'cl-tpg::team-id path)
                   '("path-root" "path-inner"))
            (eq terminal-team inner)
            (equal (cl-tpg::semantic-action-category-pair (first ranking))
                   '(2 0)))
       "visited path and terminal-winning owner do not alter ranked decisions"))
    (let ((cl-tpg::*grouped-active-specialists*
            (make-hash-table :test #'eq)))
      (setf (gethash inner cl-tpg::*grouped-active-specialists*)
            (list :specialty-groups '((:phase :steps-3-9))
                  :visited-count 0 :terminal-winning-count 0))
      (cl-tpg::grouped-note-routing-observation
       '((:phase :steps-3-9)) (list root inner) inner)
      (let ((record (gethash inner cl-tpg::*grouped-active-specialists*)))
        (check-grouped-selection
         (and (= (getf record :visited-count) 1)
              (= (getf record :terminal-winning-count) 1))
         "routing diagnostics count visited and terminal-winning separately")))))

;; Checkpoint metadata carries the exact independent stream state.
(let* ((team (grouped-test-team "checkpoint"))
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*grouped-selection-enabled* t)
       (cl-tpg::*checkpoint-directory* nil))
  (cl-tpg::initialize-grouped-selection-state 2026)
  (cl-tpg::grouped-selection-random-below 10)
  (let* ((expected (cl-tpg::grouped-selection-state-copy))
         (data (cl-tpg::make-best-team-checkpoint-data team 0.5d0))
         (expected-next (cl-tpg::grouped-selection-random-below 100000)))
    (check-grouped-selection
     (and (= (getf data :checkpoint-version)
             cl-tpg::+best-team-checkpoint-version+)
          (equal (getf data :grouped-selection-state) expected))
     "the current checkpoint persists the isolated selection RNG")
    (cl-tpg::initialize-grouped-selection-state 999)
    (cl-tpg::restore-official-guided-runtime-state
     (list :official-guided-incumbent-version 0
           :grouped-selection-state expected)
     "/tmp/nonexistent-grouped-checkpoint.lisp")
    (check-grouped-selection
     (= (cl-tpg::grouped-selection-random-below 100000) expected-next)
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
  (check-grouped-selection
   (and (not (eq source copy))
        (= (cl-tpg::target-response-36-action-target
            (cl-tpg::action-action
             (cl-tpg::learner-action
              (first (cl-tpg::team-learners copy)))))
           2))
   "historical-best serialization copy remains graph-independent"))

;; A new treatment output directory must still recover the matching journal
;; beside its source checkpoint before it writes its own journal.
(let* ((token (format nil "grouped-source-journal-~D-~D"
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
       (cl-tpg::*grouped-selection-enabled* t))
  (unwind-protect
       (progn
         (ensure-directories-exist checkpoint)
         (cl-tpg::initialize-grouped-selection-state 153)
         (cl-tpg::grouped-selection-random-below 17)
         (let* ((saved (cl-tpg::grouped-selection-state-copy))
                (expected-next
                  (cl-tpg::grouped-selection-random-below 100000)))
           (with-open-file (stream journal :direction :output
                                           :if-exists :supersede
                                           :if-does-not-exist :create)
             (with-standard-io-syntax
               (write (list :version 4
                            :fitness-protocol
                              cl-tpg::+official-guided-fitness-protocol+
                            :checkpoint-filename "source-best.lisp"
                            :incumbent-version 1
                            :grouped-selection-state saved)
                      :stream stream)))
           (cl-tpg::initialize-grouped-selection-state 999)
           (multiple-value-bind (ignored matched-p)
               (cl-tpg::restore-official-guided-runtime-state nil checkpoint)
             (declare (ignore ignored))
             (check-grouped-selection
              (and matched-p
                   (= (cl-tpg::grouped-selection-random-below 100000)
                      expected-next))
              "new output directory resumes the source checkpoint sibling journal"))))
    (when (probe-file base)
      (uiop:delete-directory-tree base :validate t))))

(format t "~D grouped selection checks passed.~%" *grouped-checks*)
