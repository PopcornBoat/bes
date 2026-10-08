(in-package :cl-tpg)

;;; Teacher-guided predicate injection converts repeated DAgger disagreements
;;; into bounded genotype variation.  The teacher identifies an error group and
;;; desired Semantic-36 terminal; categorical predicates are selected only for
;;; their separation of that group from protected probe states.  Every child
;;; remains subject to the existing locality, collateral, grouped-selection,
;;; and official paired-promotion contracts.

(defun teacher-guided-predicate-active-p ()
  "Return true when disagreement-directed predicate injection is safe."
  (and (or *teacher-guided-predicate-injection-enabled*
           *incumbent-conservative-repair-enabled*)
       *targeted-disagreement-audit-enabled*
       *grouped-selection-enabled*
       *semantic-locality-control-enabled*
       *behavioral-locality-enabled*
       (official-guided-mode-p)
       (eq *terminal-action-format* :target-response-36)
       (member :eq (active-instruction-opcodes) :test #'eq)
       (plusp (active-read-only-register-count))))

(defun teacher-guided-active-protocol ()
  "Return the protocol owning the shared guided-repair scheduler."
  (if *incumbent-conservative-repair-enabled*
      +incumbent-conservative-repair-protocol+
      +teacher-guided-predicate-protocol+))

(defun initialize-teacher-guided-predicate-state (search-seed)
  "Initialize the independent deterministic guided-predicate stream."
  (unless (integerp search-seed)
    (error "Teacher-guided predicates require an integer seed, got ~S."
           search-seed))
  (setf *teacher-guided-predicate-rng-root*
          (official-guided-mix64
           (+ search-seed +teacher-guided-predicate-rng-salt+))
        *teacher-guided-predicate-rng-cursor* 0
        *teacher-guided-predicate-age* 0
        *teacher-guided-predicate-generation-records* nil
        *teacher-guided-predicate-live-records* (make-hash-table :test #'eq)))

(defun teacher-guided-predicate-state-copy ()
  "Return resumable scheduling state; live population objects are ephemeral."
  (and *teacher-guided-predicate-rng-root*
       (list :version 1
             :protocol (teacher-guided-active-protocol)
             :root *teacher-guided-predicate-rng-root*
             :cursor *teacher-guided-predicate-rng-cursor*
             :age *teacher-guided-predicate-age*)))

(defun teacher-guided-predicate-state-valid-p (state)
  "Return true when STATE can resume guided-predicate scheduling."
  (and (listp state)
       (= (getf state :version 0) 1)
       (member (getf state :protocol)
               (list +teacher-guided-predicate-protocol+
                     +incumbent-conservative-repair-protocol+)
               :test #'eq)
       (integerp (getf state :root))
       (integerp (getf state :cursor))
       (not (minusp (getf state :cursor)))
       (integerp (getf state :age))
       (not (minusp (getf state :age)))))

(defun restore-teacher-guided-predicate-state (state)
  "Restore scheduling state without restoring a discarded old population."
  (unless (and (teacher-guided-predicate-state-valid-p state)
               (eq (getf state :protocol)
                   (teacher-guided-active-protocol)))
    (error "Invalid teacher-guided predicate state: ~S" state))
  (setf *teacher-guided-predicate-rng-root* (getf state :root)
        *teacher-guided-predicate-rng-cursor* (getf state :cursor)
        *teacher-guided-predicate-age* (getf state :age)
        *teacher-guided-predicate-generation-records* nil
        *teacher-guided-predicate-live-records* (make-hash-table :test #'eq)))

(defun teacher-guided-predicate-random-below (limit)
  "Draw below LIMIT from the isolated guided-predicate stream."
  (unless (and (integerp limit) (plusp limit))
    (error "Guided-predicate random bound must be positive, got ~S." limit))
  (unless *teacher-guided-predicate-rng-root*
    (error "Teacher-guided predicate state is not initialized."))
  (prog1
      (mod (official-guided-mix64
            (+ *teacher-guided-predicate-rng-root*
               *teacher-guided-predicate-rng-cursor*))
           limit)
    (incf *teacher-guided-predicate-rng-cursor*)))

(defun teacher-guided-predicate-slot-p ()
  "Choose whether one offspring slot receives guided variation."
  (< (/ (coerce (teacher-guided-predicate-random-below 1000000)
                 'double-float)
        1000000.0d0)
     +teacher-guided-predicate-quota+))

(defun teacher-guided-systematic-issues ()
  "Return every repeated disagreement with a direct Semantic-36 repair."
  (remove-if-not
   (lambda (issue)
     (and (getf issue :systematic-p)
          (member (getf issue :case)
                  '(:case-a-routing
                    :case-b1-reachable-support
                    :case-b2-missing-support)
                  :test #'eq)))
   (getf (getf *last-dagger-diagnostics* :targeted-repair-audit)
         :systematic-issues)))

(defun teacher-guided-weighted-issue (issues)
  "Select one issue in proportion to its observed recurrence."
  (let ((total (loop for issue in issues
                     sum (max 1 (getf issue :occurrences 1)))))
    (when (plusp total)
      (let ((draw (teacher-guided-predicate-random-below total)))
        (dolist (issue issues (car (last issues)))
          (let ((weight (max 1 (getf issue :occurrences 1))))
            (if (< draw weight)
                (return issue)
                (decf draw weight))))))))

(defun teacher-guided-parent-row-contexts (parent dataset issue)
  "Collect current rows where PARENT reproduces ISSUE's disagreement."
  (let ((contexts nil)
        (teacher (getf issue :teacher-pair))
        (predicted (getf issue :predicted-pair))
        (case (getf issue :case)))
    (dotimes (index (dataset-size dataset) (nreverse contexts))
      (when (targeted-row-matches-issue-p dataset index issue)
        (let* ((observation
                 (policy-observation
                  (aref (observations dataset) index)))
               (ranking (behavioral-ranking-pairs parent observation))
               (rank (position teacher ranking :test #'equal)))
          (when (and (equal (first ranking) predicted)
                     (ecase case
                       (:case-a-routing (not (null rank)))
                       ((:case-b1-reachable-support
                         :case-b2-missing-support)
                        (null rank))))
            (push (list :observation observation
                        :teacher-pair teacher
                        :parent-ranking ranking
                        :parent-rank
                          (or rank +semantic-ranking-limit+))
                  contexts)
            (when (>= (length contexts) 32)
              (return (nreverse contexts)))))))))

(defun teacher-guided-background-observations (issue)
  "Return protected archive observations outside ISSUE's case group."
  (loop for probe in *behavioral-probe-archive*
        unless (targeted-probe-belongs-to-issue-p probe issue)
          collect (getf probe :observation)))

(defun teacher-guided-predicate-records (contexts issue)
  "Rank exact categorical predicates by target coverage minus collisions."
  (let* ((targets
           (mapcar (lambda (context) (getf context :observation)) contexts))
         (background (teacher-guided-background-observations issue))
         (target-count (length targets))
         (background-count (length background))
         (records nil))
    (dotimes (index *num-observations*)
      (dotimes (ror-index (active-read-only-register-count))
        (let* ((value (aref (active-read-only-register-values) ror-index))
               (target-hits
                 (count-if (lambda (observation)
                             (= (aref observation index) value))
                           targets))
               (background-hits
                 (count-if (lambda (observation)
                             (= (aref observation index) value))
                           background))
               (coverage
                 (/ target-hits
                    (coerce (max 1 target-count) 'double-float)))
               (collision-rate
                 (/ background-hits
                    (coerce (max 1 background-count) 'double-float))))
          (when (>= target-hits +targeted-routing-repair-minimum-rows+)
            (push (list :observation-index index
                        :ror-index ror-index
                        :value value
                        :target-hits target-hits
                        :target-count target-count
                        :coverage coverage
                        :background-hits background-hits
                        :background-count background-count
                        :collision-rate collision-rate
                        :separation (- coverage collision-rate))
                  records)))))
    (subseq
     (stable-sort
      records
      (lambda (left right)
        (or (> (getf left :separation) (getf right :separation))
            (and (= (getf left :separation) (getf right :separation))
                 (or (> (getf left :coverage) (getf right :coverage))
                     (and (= (getf left :coverage) (getf right :coverage))
                          (or (< (getf left :collision-rate)
                                 (getf right :collision-rate))
                              (and (= (getf left :collision-rate)
                                      (getf right :collision-rate))
                                   (< (getf left :observation-index)
                                      (getf right
                                            :observation-index))))))))))
     0 (min +teacher-guided-predicate-max-predicates+
            (length records)))))

(defun teacher-guided-instruction
       (dest op src1-type src1-value src2-type src2-value)
  "Construct one deterministic binary instruction."
  (%make-instruction
   :dest dest :op op :arity 2
   :src1-type src1-type :src1-val (coerce src1-value 'double-float)
   :src2-type src2-type :src2-val (coerce src2-value 'double-float)))

(defun teacher-guided-append-instruction (program instruction)
  "Append INSTRUCTION to PROGRAM's adjustable instruction vector."
  (vector-push-extend instruction (program-instructions program))
  program)

(defun teacher-guided-append-support-gate (program predicate)
  "Saturate an existing learner's bid only when PREDICATE is true."
  (let ((scratch 1)
        (index (getf predicate :observation-index))
        (ror-index (getf predicate :ror-index)))
    (dolist
        (instruction
          (list
           (teacher-guided-instruction
            scratch :eq :obs index :ror ror-index)
           (teacher-guided-instruction
            scratch :mul :reg scratch :const 1000.0d0)
           (teacher-guided-instruction
            +bid-register+ :add :reg +bid-register+ :reg scratch)
           (teacher-guided-instruction
            +bid-register+ :add :reg +bid-register+ :reg scratch)))
      (teacher-guided-append-instruction program instruction)))
  program)

(defun teacher-guided-new-gate-program (predicate)
  "Return a minimal bidder producing -1000/1000 off/on PREDICATE."
  (let ((program
          (make-program
           :instructions
             (make-array 0 :fill-pointer 0 :adjustable t))))
    (let ((scratch 1)
          (index (getf predicate :observation-index))
          (ror-index (getf predicate :ror-index)))
      (dolist
          (instruction
            (list
             (teacher-guided-instruction
              scratch :eq :obs index :ror ror-index)
             (teacher-guided-instruction
              scratch :mul :reg scratch :const 2.0d0)
             (teacher-guided-instruction
              scratch :add :reg scratch :const -1.0d0)
             (teacher-guided-instruction
              +bid-register+ :mul :reg scratch :const 1000.0d0)))
        (teacher-guided-append-instruction program instruction)))
    program))

(defun teacher-guided-direct-learner-indices (team teacher-pair)
  "Return root learners whose atomic terminal is TEACHER-PAIR."
  (loop for learner in (team-learners team)
        for index fixnum from 0
        for action = (learner-action learner)
        for payload = (and (eq (action-type action) :atomic)
                           (action-action action))
        when (and (target-response-36-action-p payload)
                  (equal teacher-pair
                         (list (target-response-36-action-target payload)
                               (target-response-36-action-response payload))))
          collect index))

(defun teacher-guided-install-predicate (child teacher-pair predicate)
  "Attach PREDICATE to direct support, or inject a direct terminal specialist."
  (let ((direct-indices
          (teacher-guided-direct-learner-indices child teacher-pair)))
    (cond
      (direct-indices
       (let* ((index
                (nth (teacher-guided-predicate-random-below
                      (length direct-indices))
                     direct-indices))
              (learner (nth index (team-learners child)))
              (program (learner-program learner)))
         (when (and (realp *max-program-size*)
                    (> (+ (length (program-instructions program)) 4)
                       *max-program-size*))
           (return-from teacher-guided-install-predicate nil))
         (teacher-guided-append-support-gate program predicate)
         ;; Stable learner-order tie breaking makes a saturated guided bid win.
         (setf (team-learners child)
               (cons learner
                     (remove learner (team-learners child) :test #'eq)))
         (note-mutation-event :teacher-guided-predicate-injection)
         (note-mutation-event :teacher-guided-existing-terminal-gate)
         (list :mode :existing-terminal :learner-index index)))
      ((< (length (team-learners child)) *max-num-learners*)
       (let ((learner
               (make-learner
                :program (teacher-guided-new-gate-program predicate)
                :action
                  (make-action
                   :type :atomic
                   :action
                     (make-target-response-36-action
                      :target (first teacher-pair)
                      :response (second teacher-pair))))))
         (push learner (team-learners child))
         (note-mutation-event :teacher-guided-predicate-injection)
         (note-mutation-event :teacher-guided-terminal-injection)
         (list :mode :new-terminal :learner-index 0)))
      (t nil))))

(defun teacher-guided-candidate-better-p (left right)
  "Prefer greater local correction, then separation and lower disruption."
  (let ((lt (getf left :target))
        (rt (getf right :target))
        (lp (getf left :predicate))
        (rp (getf right :predicate))
        (ll (getf left :locality))
        (rl (getf right :locality)))
    (or (> (getf lt :top1-gains) (getf rt :top1-gains))
        (and (= (getf lt :top1-gains) (getf rt :top1-gains))
             (or (< (getf lt :child-mean-rank)
                    (getf rt :child-mean-rank))
                 (and (= (getf lt :child-mean-rank)
                         (getf rt :child-mean-rank))
                      (or (> (getf lp :separation)
                             (getf rp :separation))
                          (and (= (getf lp :separation)
                                  (getf rp :separation))
                               (< (+ (getf ll :top1-hamming)
                                     (getf ll :ranking-distance-mean))
                                  (+ (getf rl :top1-hamming)
                                     (getf rl
                                           :ranking-distance-mean)))))))))))

(defun teacher-guided-try-parent-issue (parent issue contexts)
  "Try the best separating predicates for one PARENT/ISSUE pair."
  (let ((predicates (teacher-guided-predicate-records contexts issue))
        (best nil)
        (attempt 0))
    (dolist (predicate predicates)
      (incf attempt)
      (let ((child (clone-team parent))
            (*active-mutation-events* nil))
        (let ((installation
                (teacher-guided-install-predicate
                 child (getf issue :teacher-pair) predicate)))
          (if (null installation)
              (discard-semantic-locality-candidate child)
              (let* ((events (nreverse *active-mutation-events*))
                     (target
                       (targeted-target-group-comparison child contexts))
                     (locality
                       (make-behavioral-mutation-record parent child events))
                     (collateral
                       (targeted-collateral-comparison parent child issue))
                     (candidate
                       (list :child child :predicate predicate
                             :installation installation :target target
                             :locality locality :collateral collateral
                             :attempt attempt)))
                (if (and locality
                         (targeted-target-comparison-improves-p target)
                         (targeted-collateral-acceptable-p collateral locality))
                    (if (or (null best)
                            (teacher-guided-candidate-better-p
                             candidate best))
                        (progn
                          (when best
                            (discard-semantic-locality-candidate
                             (getf best :child)))
                          (setf best candidate))
                        (discard-semantic-locality-candidate child))
                    (discard-semantic-locality-candidate child)))))))
    (when best
      (let ((locality (getf best :locality)))
        (setf
         (getf locality :control-protocol)
           +semantic-locality-control-protocol+
         (getf locality :control-stage) :teacher-guided-predicate
         (getf locality :control-age) *semantic-locality-control-age*
         (getf locality :control-requested-tier) :targeted
         (getf locality :control-tier) :bounded
         (getf locality :control-effective-tier) :bounded
         (getf locality :control-escalated-p) nil
         (getf locality :control-attempts) (getf best :attempt)
         (getf locality :control-fallback-p) nil
         (getf locality :teacher-guided-issue) (copy-tree issue)
         (getf locality :teacher-guided-predicate)
           (copy-tree (getf best :predicate))
         (getf locality :teacher-guided-installation)
           (copy-tree (getf best :installation))
         (getf locality :teacher-guided-target-comparison)
           (copy-tree (getf best :target))
         (getf locality :teacher-guided-collateral)
           (copy-tree (getf best :collateral)))
        (register-behavioral-mutation-record
         parent (getf best :child) locality)
        (push (copy-tree locality)
              *semantic-locality-control-generation-records*)
        (values (getf best :child) locality attempt)))))

(defun teacher-guided-note-attempt (record)
  "Retain one serializable guided-predicate decision."
  (push (copy-tree record) *teacher-guided-predicate-generation-records*)
  record)

(defun teacher-guided-register-live-child (child parent locality issue)
  "Mark CHILD for one evaluated generation of retention and nomination."
  (unless *teacher-guided-predicate-live-records*
    (setf *teacher-guided-predicate-live-records*
          (make-hash-table :test #'eq)))
  (setf (gethash child *teacher-guided-predicate-live-records*)
        (list :protocol +teacher-guided-predicate-protocol+
              :generation-created *generation*
              :parent-team-id (team-id parent)
              :child-team-id (team-id child)
              :issue (copy-tree issue)
              :predicate
                (copy-tree (getf locality :teacher-guided-predicate))
              :target-comparison
                (copy-tree
                 (getf locality :teacher-guided-target-comparison))
              :collateral
                (copy-tree (getf locality :teacher-guided-collateral))
              :top1-hamming (getf locality :top1-hamming)
              :ranking-distance (getf locality :ranking-distance-mean)))
  child)

(defun teacher-guided-attempt-predicate-repair (parents)
  "Attempt one disagreement-directed child and return CHILD/PARENT."
  (when *incumbent-conservative-repair-enabled*
    (return-from teacher-guided-attempt-predicate-repair
      (incumbent-conservative-attempt-repair)))
  (let ((issues (teacher-guided-systematic-issues)))
    (unless (and issues *teacher-training-dataset*)
      (teacher-guided-note-attempt
       (list :protocol +teacher-guided-predicate-protocol+
             :generation *generation* :accepted nil
             :reason :no-systematic-issues))
      (return-from teacher-guided-attempt-predicate-repair
        (values nil nil)))
    (let* ((issue (teacher-guided-weighted-issue issues))
           (start (teacher-guided-predicate-random-below (length parents)))
           (checked 0))
      (loop for offset below
              (min +teacher-guided-predicate-max-parents+ (length parents))
            for parent = (nth (mod (+ start offset) (length parents)) parents)
            for contexts =
              (teacher-guided-parent-row-contexts
               parent *teacher-training-dataset* issue)
            do (incf checked)
               (when (>= (length contexts)
                         +targeted-routing-repair-minimum-rows+)
                 (multiple-value-bind (child locality attempts)
                     (teacher-guided-try-parent-issue parent issue contexts)
                   (when child
                     (teacher-guided-register-live-child
                      child parent locality issue)
                     (teacher-guided-note-attempt
                      (list :protocol +teacher-guided-predicate-protocol+
                            :generation *generation* :accepted t
                            :issue (copy-tree issue)
                            :parent-team-id (team-id parent)
                            :child-team-id (team-id child)
                            :parents-checked checked
                            :predicate-attempts attempts
                            :predicate
                              (copy-tree
                               (getf locality :teacher-guided-predicate))
                            :installation
                              (copy-tree
                               (getf locality :teacher-guided-installation))
                            :target-comparison
                              (copy-tree
                               (getf locality
                                     :teacher-guided-target-comparison))
                            :collateral
                              (copy-tree
                               (getf locality :teacher-guided-collateral))
                            :top1-hamming
                              (getf locality :top1-hamming)
                            :ranking-distance
                              (getf locality :ranking-distance-mean)))
                     (return-from teacher-guided-attempt-predicate-repair
                       (values child parent))))))
      (teacher-guided-note-attempt
       (list :protocol +teacher-guided-predicate-protocol+
             :generation *generation* :accepted nil
             :reason :no-acceptable-guided-predicate
             :issue (copy-tree issue)
             :parents-checked checked))
      (values nil nil))))

(defun teacher-guided-evaluated-entries (scores)
  "Return evaluated SCORE entries generated by the previous guided step."
  (loop for entry in scores
        when (and *teacher-guided-predicate-live-records*
                  (gethash (car entry)
                           *teacher-guided-predicate-live-records*))
          collect entry))

(defun teacher-guided-entry-better-p (left right)
  "Order evaluated repairs by local gain, then aggregate imitation score."
  (let* ((left-record
           (gethash (car left) *teacher-guided-predicate-live-records*))
         (right-record
           (gethash (car right) *teacher-guided-predicate-live-records*))
         (left-target (getf left-record :target-comparison))
         (right-target (getf right-record :target-comparison)))
    (or (> (getf left-target :top1-gains)
           (getf right-target :top1-gains))
        (and (= (getf left-target :top1-gains)
                (getf right-target :top1-gains))
             (or (< (getf left-target :child-mean-rank)
                    (getf right-target :child-mean-rank))
                 (and (= (getf left-target :child-mean-rank)
                         (getf right-target :child-mean-rank))
                      (> (cdr left) (cdr right))))))))

(defun teacher-guided-candidate-entry (scores)
  "Return the strongest evaluated guided repair for official nomination."
  (first (stable-sort (teacher-guided-evaluated-entries scores)
                      #'teacher-guided-entry-better-p)))

(defun teacher-guided-protected-teams (scores)
  "Return a bounded first-evaluation survival set for grouped selection."
  (let* ((entries (teacher-guided-evaluated-entries scores))
         (ordered (stable-sort entries #'teacher-guided-entry-better-p)))
    (mapcar
     #'car
     (subseq ordered
             0 (min +teacher-guided-predicate-protected-survivors+
                    (length ordered))))))

(defun teacher-guided-finish-selection ()
  "Expire one-generation repair protection before new offspring are made."
  (when (teacher-guided-predicate-active-p)
    (setf *teacher-guided-predicate-live-records*
          (make-hash-table :test #'eq))))

(defun finish-teacher-guided-predicate-generation ()
  "Journal and summarize guided-predicate decisions for this generation."
  (when (teacher-guided-predicate-active-p)
    (let* ((records
             (nreverse *teacher-guided-predicate-generation-records*))
           (attempted (length records))
           (accepted
             (count-if (lambda (record) (getf record :accepted)) records)))
      (when attempted
        (emit-message
         (format nil
                 "Generation ~D teacher-guided predicates: slots=~D accepted=~D fallback=~D."
                 *generation* attempted accepted (- attempted accepted)))
        (when (behavioral-locality-active-p)
          (append-behavioral-locality-form
           (list :type :teacher-guided-predicate-generation
                 :protocol (teacher-guided-active-protocol)
                 :generation *generation*
                 :age *teacher-guided-predicate-age*
                 :attempted attempted
                 :accepted accepted
                 :fallback (- attempted accepted)
                 :records records))))
      (incf *teacher-guided-predicate-age*)
      (setf *teacher-guided-predicate-generation-records* nil))))
