(in-package :cl-tpg)

;;; Donor-free admission for evolved candidates.  The cheap official stage is
;;; deliberately a negative filter: uncertain and mildly negative evidence is
;;; retained, while only clearly futile policies are discarded.

(defun official-admission-active-p ()
  "Return true when multi-source official admission is active."
  (and *official-admission-enabled* (official-guided-mode-p)))

(defun official-admission-lane-count (lane)
  "Return the configured nomination count for LANE."
  (or (cdr (assoc lane +official-admission-lane-counts+ :test #'eq)) 0))

(defun official-admission-lane-statistics (lane)
  "Return or create the mutable statistics plist for LANE."
  (or (cdr (assoc lane *official-admission-lane-statistics* :test #'eq))
      (let ((record (list :nominated 0 :cheap-kept 0 :cheap-rejected 0
                          :tournament-evaluated 0 :tournament-positive 0
                          :tournament-selected 0
                          :full-evaluated 0 :positive-official 0
                          :stage-1-reached 0 :stage-4-reached 0
                          :promoted 0)))
        (push (cons lane record) *official-admission-lane-statistics*)
        record)))

(defun official-admission-increment-lanes (lanes key)
  "Increment statistic KEY once for every provenance lane in LANES."
  (dolist (lane lanes)
    (let ((record (official-admission-lane-statistics lane)))
      (incf (getf record key 0)))))

(defun official-admission-state-copy ()
  "Return serialization-safe cumulative admission diagnostics."
  (and *official-admission-enabled*
       (list :version 2
             :protocol +official-admission-protocol+
             :batch-count *official-admission-batch-count*
             :lane-statistics
               (copy-tree *official-admission-lane-statistics*)
             :evidence-state
               (official-admission-evidence-state-copy))))

(defun restore-official-admission-state (state)
  "Restore cumulative diagnostics; in-flight worker processes are never reused."
  (unless (and (listp state)
               (member (getf state :version 0) '(1 2))
               (eq (getf state :protocol) +official-admission-protocol+)
               (integerp (getf state :batch-count))
               (not (minusp (getf state :batch-count))))
    (error "Invalid official admission state: ~S" state))
  (setf *official-admission-batch-count* (getf state :batch-count)
        *official-admission-lane-statistics*
          (copy-tree (getf state :lane-statistics)))
  (if (= (getf state :version) 2)
      (restore-official-admission-evidence-state
       (getf state :evidence-state))
      (reset-official-admission-evidence-state))
  state)

(defun reset-official-admission-runtime ()
  "Stop a local worker and clear ephemeral queues and cumulative diagnostics."
  (when (and *official-admission-process*
             (ignore-errors
               (uiop:process-alive-p *official-admission-process*)))
    (ignore-errors (uiop:terminate-process *official-admission-process*)))
  (setf *official-admission-process* nil
        *official-admission-job* nil
        *official-admission-full-queue* nil
        *official-admission-batch-count* 0
        *official-admission-lane-statistics* nil
        *online-staged-best-nomination-lanes* nil)
  (reset-official-admission-evidence-state))

(defun official-admission-evidence-serialize-anchor (record)
  "Return the persistent portion of one official-evidence anchor RECORD."
  (list :lineage-id (getf record :lineage-id)
        :team-id (getf record :team-id)
        :checkpoint-path (getf record :checkpoint-path)
        :candidate-generation (getf record :candidate-generation)
        :approved-generation (getf record :approved-generation)
        :remaining-selection-cycles
          (getf record :remaining-selection-cycles 0)
        :evidence-episodes (getf record :evidence-episodes)
        :paired-mean (getf record :paired-mean)
        :paired-se (getf record :paired-se)
        :parent-weight (getf record :parent-weight)
        :lanes (copy-list (getf record :lanes))))

(defun official-admission-evidence-state-copy ()
  "Return serializable counters and bounded official-evidence anchors."
  (list :version 1
        :next-id *official-admission-evidence-next-id*
        :admitted-count *official-admission-evidence-admitted-count*
        :anchors
          (mapcar #'official-admission-evidence-serialize-anchor
                  *official-admission-evidence-anchors*)))

(defun reset-official-admission-evidence-state ()
  "Reset all run-local official-evidence lineage state."
  (setf *official-admission-evidence-anchors* nil
        *official-admission-evidence-team-lineages*
          (make-hash-table :test #'eq)
        *official-admission-evidence-next-id* 0
        *official-admission-evidence-admitted-count* 0))

(defun official-admission-evidence-load-anchor (path lineage-id)
  "Load PATH as an independent live root owned by LINEAGE-ID."
  (unless (probe-file path)
    (error "Official-evidence anchor is missing: ~A" path))
  (unless *official-admission-evidence-team-lineages*
    (setf *official-admission-evidence-team-lineages*
            (make-hash-table :test #'eq)))
  (let ((anchor (load-best-team path)))
    (ensure-team-observation-compatible anchor *num-observations*)
    (setf (team-type anchor) :root
          (team-references anchor) 0)
    (dolist (team (closure anchor))
      (pushnew team *teams* :test #'eq))
    (setf (gethash anchor *official-admission-evidence-team-lineages*)
            lineage-id)
    anchor))

(defun restore-official-admission-evidence-state (state)
  "Restore bounded official-evidence anchors from a versioned STATE."
  (reset-official-admission-evidence-state)
  (when state
    (unless (and (listp state) (= (getf state :version 0) 1))
      (error "Invalid official-admission evidence state: ~S" state))
    (setf *official-admission-evidence-next-id* (getf state :next-id 0)
          *official-admission-evidence-admitted-count*
            (getf state :admitted-count 0))
    (dolist (saved (getf state :anchors))
      (when (plusp (getf saved :remaining-selection-cycles 0))
        (let* ((lineage-id (getf saved :lineage-id))
               (anchor
                 (official-admission-evidence-load-anchor
                  (getf saved :checkpoint-path) lineage-id)))
          (push (append (copy-tree saved) (list :team anchor))
                *official-admission-evidence-anchors*))))
    (setf *official-admission-evidence-anchors*
            (nreverse *official-admission-evidence-anchors*)))
  state)

(defun official-admission-evidence-parent-weight (episode-count)
  "Convert cumulative paired evidence into a bounded parent multiplicity."
  (min +official-admission-evidence-max-parent-weight+
       (cond ((>= episode-count 100) 4)
             ((>= episode-count 40) 3)
             (t 2))))

(defun official-admission-evidence-next-lineage-id (generation)
  "Return a deterministic identifier for one newly admitted lineage."
  (incf *official-admission-evidence-next-id*)
  (format nil "OFFICIAL-EVIDENCE-~D-G~D"
          *official-admission-evidence-next-id* generation))

(defun official-admission-evidence-trim-anchors ()
  "Enforce the active-anchor budget without deleting ordinary live roots."
  (loop while (> (length *official-admission-evidence-anchors*)
                 +official-admission-evidence-max-active-anchors+)
        do (let ((oldest
                   (reduce
                    (lambda (left right)
                      (if (< (getf left :approved-generation 0)
                             (getf right :approved-generation 0))
                          left right))
                    *official-admission-evidence-anchors*)))
             (setf *official-admission-evidence-anchors*
                     (remove oldest *official-admission-evidence-anchors*
                             :test #'eq)))))

(defun official-admission-install-evidence-anchor (record)
  "Install RECORD as a bounded survival/reproduction anchor, never as best."
  (let* ((generation (getf record :candidate-generation *generation*))
         (last-stage (car (last (getf record :tournament-stages))))
         (episodes (getf last-stage :episode-count))
         (lineage-id
           (official-admission-evidence-next-lineage-id generation))
         (anchor
           (official-admission-evidence-load-anchor
            (getf record :candidate-path) lineage-id))
         (anchor-record
           (list :lineage-id lineage-id
                 :team anchor
                 :team-id (team-id anchor)
                 :checkpoint-path (getf record :candidate-path)
                 :candidate-generation generation
                 :approved-generation *generation*
                 :remaining-selection-cycles
                   +official-admission-evidence-protection-generations+
                 :evidence-episodes episodes
                 :paired-mean (getf last-stage :paired-mean)
                 :paired-se (getf last-stage :paired-se)
                 :parent-weight
                   (official-admission-evidence-parent-weight episodes)
                 :lanes (copy-list (getf record :lanes)))))
    (push anchor-record *official-admission-evidence-anchors*)
    (incf *official-admission-evidence-admitted-count*)
    (official-admission-increment-lanes
     (getf record :lanes) :evidence-admitted)
    (official-admission-evidence-trim-anchors)
    anchor-record))

(defun official-admission-evidence-eligible-p (record)
  "Return true for non-negative evidence surviving at least twelve episodes."
  (let ((last-stage (car (last (getf record :tournament-stages)))))
    (and (getf record :keep)
         last-stage
         (getf last-stage :continue)
         (>= (getf last-stage :episode-count 0)
             +official-admission-evidence-minimum-episodes+)
         (>= (getf last-stage :paired-mean most-negative-double-float)
             0.0d0))))

(defun official-admission-install-batch-evidence (candidate-records)
  "Install at most two strongest non-negative records as live evidence anchors."
  (let* ((eligible
           (remove-if-not #'official-admission-evidence-eligible-p
                          candidate-records))
         (ranked
           (stable-sort
            (copy-list eligible)
            (lambda (left right)
              (let ((left-stage (car (last (getf left :tournament-stages))))
                    (right-stage (car (last (getf right :tournament-stages)))))
                (or (> (getf left-stage :episode-count)
                       (getf right-stage :episode-count))
                    (and (= (getf left-stage :episode-count)
                            (getf right-stage :episode-count))
                         (> (getf left-stage :paired-mean)
                            (getf right-stage :paired-mean))))))))
         (limit
           (min (length ranked)
                +official-admission-evidence-max-anchors-per-batch+)))
    (mapcar #'official-admission-install-evidence-anchor
            (subseq ranked 0 limit))))

(defun official-admission-evidence-protected-teams ()
  "Return active evidence anchors that must survive grouped selection."
  (let ((roots (root-teams)))
    (loop for record in *official-admission-evidence-anchors*
          for team = (getf record :team)
          when (and team
                    (plusp (getf record :remaining-selection-cycles 0))
                    (member team roots :test #'eq))
            collect team)))

(defun official-admission-evidence-note-selection (selected-teams)
  "Spend one protection cycle and retire exhausted or deleted anchors."
  (let ((roots (root-teams))
        (retained nil))
    (dolist (record *official-admission-evidence-anchors*)
      (let ((team (getf record :team)))
        (when (and team (member team selected-teams :test #'eq)
                   (plusp (getf record :remaining-selection-cycles 0)))
          (decf (getf record :remaining-selection-cycles)))
        (when (and team (member team roots :test #'eq)
                   (plusp (getf record :remaining-selection-cycles 0)))
          (push record retained))))
    (setf *official-admission-evidence-anchors* (nreverse retained))))

(defun official-admission-weighted-parent-pool (roots)
  "Return ROOTS plus bounded duplicate references for active evidence anchors."
  (let ((weighted (copy-list roots)))
    (dolist (record *official-admission-evidence-anchors* weighted)
      (let ((anchor (getf record :team))
            (weight (getf record :parent-weight 1)))
        (when (and anchor (member anchor roots :test #'eq)
                   (plusp (getf record :remaining-selection-cycles 0)))
          (loop repeat (1- weight) do (push anchor weighted)))))))

(defun official-admission-note-evidence-descendant (parent child)
  "Propagate evidence lineage identity for diagnostics only."
  (when *official-admission-evidence-team-lineages*
    (multiple-value-bind (lineage-id present-p)
        (gethash parent *official-admission-evidence-team-lineages*)
      (when present-p
        (setf (gethash child *official-admission-evidence-team-lineages*)
                lineage-id))))
  child)

(defun official-admission-prune-evidence-lineages ()
  "Retain descendant lineage tags only for roots still in the population."
  (when *official-admission-evidence-team-lineages*
    (let ((retained (make-hash-table :test #'eq)))
      (dolist (team (root-teams))
        (multiple-value-bind (lineage-id present-p)
            (gethash team *official-admission-evidence-team-lineages*)
          (when present-p
            (setf (gethash team retained) lineage-id))))
      (setf *official-admission-evidence-team-lineages* retained))))

(defun official-admission-random-below (limit)
  "Draw a replayable integer below LIMIT from the isolated nomination stream."
  (unless (and (integerp limit) (plusp limit))
    (error "Official admission random limit must be positive, got ~S." limit))
  (mod (first (official-guided-take-seeds :nomination 1)) limit))

(defun official-admission-behavior (team)
  "Return TEAM's already-computed generation behavior vector, if available."
  (and *grouped-team-row-behaviors*
       (gethash team *grouped-team-row-behaviors*)))

(defun official-admission-behavior-equal-p (left right)
  "Return true when two nomination records have identical ranked behavior."
  (let ((left-behavior (getf left :behavior))
        (right-behavior (getf right :behavior)))
    (and left-behavior right-behavior
         (equalp left-behavior right-behavior))))

(defun official-admission-behavior-distance (left right)
  "Return normalized row-level behavior Hamming distance for two records."
  (let ((left-behavior (getf left :behavior))
        (right-behavior (getf right :behavior)))
    (if (and left-behavior right-behavior
             (= (length left-behavior) (length right-behavior))
             (plusp (length left-behavior)))
        (/ (coerce
            (loop for index below (length left-behavior)
                  count (/= (aref left-behavior index)
                             (aref right-behavior index)))
            'double-float)
           (coerce (length left-behavior) 'double-float))
        0.0d0)))

(defun make-official-admission-nomination (entry lane)
  "Build one live, generation-local nomination record from score ENTRY."
  (list :team (car entry)
        :fitness (cdr entry)
        :generation *generation*
        :lanes (list lane)
        :behavior (official-admission-behavior (car entry))))

(defun official-admission-add-nomination (nominations entry lane)
  "Add ENTRY under LANE, merging exact duplicate behavior provenance."
  (let* ((candidate (make-official-admission-nomination entry lane))
         (duplicate
           (find-if
            (lambda (existing)
              (or (eq (getf existing :team) (getf candidate :team))
                  (official-admission-behavior-equal-p existing candidate)))
            nominations)))
    (if duplicate
        (pushnew lane (getf duplicate :lanes) :test #'eq)
        (setf nominations (append nominations (list candidate))))
    nominations))

(defun official-admission-team-nominated-p (team nominations)
  "Return true when TEAM or an exactly behavior-equivalent policy is nominated."
  (let ((candidate
          (list :team team :behavior (official-admission-behavior team))))
    (some (lambda (existing)
            (or (eq team (getf existing :team))
                (official-admission-behavior-equal-p existing candidate)))
          nominations)))

(defun official-admission-specialist-proposals (scores)
  "Rank distinct per-group elites by improvement above the group median."
  (let ((proposals nil))
    (dolist (group *grouped-case-groups*)
      (let* ((key (getf group :key))
             (best-entry
               (reduce
                (lambda (left right)
                  (if (> (grouped-team-group-score (car left) key)
                         (grouped-team-group-score (car right) key))
                      left right))
                scores))
             (score (grouped-team-group-score (car best-entry) key))
             (median
               (numeric-median
                (mapcar (lambda (entry)
                          (grouped-team-group-score (car entry) key))
                        scores))))
        (push (list :entry best-entry :key key
                    :advantage (- score median))
              proposals)))
    (stable-sort proposals #'> :key (lambda (record)
                                      (getf record :advantage)))))

(defun official-admission-critical-entries (scores)
  "Return roots ordered by the late-episode critical case score."
  (let ((key '(:phase :steps-50-99)))
    (if (find key *grouped-case-groups*
              :key (lambda (group) (getf group :key)) :test #'equal)
        (stable-sort
         (copy-list scores) #'>
         :key (lambda (entry)
                (grouped-team-group-score (car entry) key)))
        (stable-sort (copy-list scores) #'> :key #'cdr))))

(defun official-admission-nominate (scores sorted)
  "Nominate a deduplicated donor-free batch from five complementary lanes."
  (let ((nominations nil))
    ;; Aggregate champion.
    (when (and sorted (plusp (official-admission-lane-count :aggregate)))
      (setf nominations
            (official-admission-add-nomination
             nominations (first sorted) :aggregate)))

    ;; Per-case specialists with the largest advantage over their population median.
    (let ((remaining (official-admission-lane-count :specialist)))
      (dolist (proposal (official-admission-specialist-proposals scores))
        (when (and (plusp remaining)
                   (not (official-admission-team-nominated-p
                         (car (getf proposal :entry)) nominations)))
          (setf nominations
                (official-admission-add-nomination
                 nominations (getf proposal :entry) :specialist))
          (decf remaining))))

    ;; Farthest-first policies under the exact ranked row behavior already scored.
    (loop repeat (if *grouped-team-row-behaviors*
                     (official-admission-lane-count :behavioral-diversity)
                     0)
          do
      (let ((best-entry nil)
            (best-distance -1.0d0))
        (dolist (entry scores)
          (unless (official-admission-team-nominated-p (car entry) nominations)
            (let* ((candidate
                     (make-official-admission-nomination
                      entry :behavioral-diversity))
                   (distance
                     (if nominations
                         (reduce #'min nominations
                                 :key (lambda (existing)
                                        (official-admission-behavior-distance
                                         candidate existing)))
                         1.0d0)))
              (when (> distance best-distance)
                (setf best-distance distance
                      best-entry entry)))))
        (when best-entry
          (setf nominations
                (official-admission-add-nomination
                 nominations best-entry :behavioral-diversity)))))

    ;; One late-trajectory critical-error candidate.
    (let ((remaining (if *grouped-case-groups*
                         (official-admission-lane-count :critical-error)
                         0)))
      (dolist (entry (official-admission-critical-entries scores))
        (when (and (plusp remaining)
                   (not (official-admission-team-nominated-p
                         (car entry) nominations)))
          (setf nominations
                (official-admission-add-nomination
                 nominations entry :critical-error))
          (decf remaining))))

    ;; Unbiased inspection control from the still-eligible deduplicated pool.
    (loop repeat (official-admission-lane-count :random-control)
          do
      (let ((eligible
              (remove-if
               (lambda (entry)
                 (official-admission-team-nominated-p
                  (car entry) nominations))
               scores)))
        (when eligible
          (let ((entry
                  (nth (official-admission-random-below (length eligible))
                       eligible)))
            (setf nominations
                  (official-admission-add-nomination
                   nominations entry :random-control))))))

    (dolist (record nominations)
      (official-admission-increment-lanes (getf record :lanes) :nominated))
    nominations))

(defun official-admission-continue-p (candidate-returns incumbent-returns)
  "Keep anything not clearly futile under the two-episode negative filter.

One episode can never reject.  With two or more paired episodes, reject only
when mean + 2*SE is still more than five reward points below the incumbent."
  (multiple-value-bind (mean se correlation paired-variance unpaired-variance)
      (official-guided-comparison-statistics
       candidate-returns incumbent-returns)
    (declare (ignore correlation paired-variance unpaired-variance))
    (let* ((episode-count (length candidate-returns))
           (upper-bound
             (+ mean (* +official-admission-standard-errors+ se)))
           (keep-p
             (or (< episode-count 2)
                 (>= upper-bound
                     (- +official-admission-futility-floor+)))))
      (values keep-p mean se upper-bound
              (if keep-p :uncertain-or-promising :clearly-futile)))))

(defun official-admission-tournament-select
       (candidate-records incumbent-returns seeds)
  "Reduce CANDIDATE-RECORDS to one common-seed tournament winner.

Every record must contain 100 tournament returns.  Existing staged futility
rules reduce the field at 5/12/40/100 episodes.  Selection is order-independent:
the survivor with the largest paired mean on the common 100-seed block wins.
This is nomination only; disjoint full confirmation remains authoritative."
  (let* ((records
           (mapcar
            (lambda (record)
              (list* :tournament-stages nil
                     :tournament-selected nil
                     (copy-list record)))
            candidate-records))
         (survivors (copy-list records)))
    (dolist (stage-count +official-admission-tournament-stages+)
      (let ((stage
              (if (= stage-count +official-guided-racing-episodes+)
                  :racing
                  (official-guided-promotion-stage-name stage-count)))
            (next nil))
        (dolist (record survivors)
          (let ((candidate-prefix
                  (subseq (getf record :tournament-returns) 0 stage-count))
                (incumbent-prefix
                  (subseq incumbent-returns 0 stage-count)))
            (multiple-value-bind
                  (continue-p mean se upper-bound reason)
                (official-admission-continue-p
                 candidate-prefix incumbent-prefix)
              (multiple-value-bind
                    (ignored-mean ignored-se correlation paired-variance
                     unpaired-variance)
                  (official-guided-comparison-statistics
                   candidate-prefix incumbent-prefix)
                (declare (ignore ignored-mean ignored-se))
                (setf (getf record :tournament-stages)
                      (append
                       (getf record :tournament-stages)
                       (list
                        (list :stage stage :episode-count stage-count
                              :continue continue-p :paired-mean mean
                              :paired-se se
                              :margin
                                (* +official-admission-standard-errors+ se)
                              :upper-bound upper-bound :reason reason
                              :same-seed-correlation correlation
                              :paired-variance paired-variance
                              :unpaired-variance unpaired-variance)))))
              (when continue-p
                (push record next)))))
        (setf survivors (nreverse next))
        (when (null survivors)
          (return))))
    (let ((winner
            (when survivors
              (reduce
               (lambda (left right)
                 (let ((left-mean
                         (getf (car (last (getf left :tournament-stages)))
                               :paired-mean))
                       (right-mean
                         (getf (car (last (getf right :tournament-stages)))
                               :paired-mean)))
                   (cond
                     ((> left-mean right-mean) left)
                     ((< left-mean right-mean) right)
                     ((> (getf left :candidate-imitation-score 0.0d0)
                         (getf right :candidate-imitation-score 0.0d0))
                      left)
                     ((< (getf left :candidate-imitation-score 0.0d0)
                         (getf right :candidate-imitation-score 0.0d0))
                      right)
                     ((string-lessp
                       (princ-to-string (getf left :candidate-id))
                       (princ-to-string (getf right :candidate-id)))
                      left)
                     (t right))))
               survivors))))
      (when winner
        (setf (getf winner :tournament-selected) t))
      (values records winner
              (copy-list seeds) (copy-list incumbent-returns)))))

(defun official-admission-note-tournament-outcome (record)
  "Attribute common-seed tournament evidence to RECORD's provenance lanes."
  (let* ((lanes (getf record :lanes))
         (stages (getf record :tournament-stages))
         (last-stage (car (last stages))))
    (when stages
      (official-admission-increment-lanes lanes :tournament-evaluated)
      (when (> (getf last-stage :paired-mean 0.0d0) 0.0d0)
        (official-admission-increment-lanes lanes :tournament-positive))
      (when (getf record :tournament-selected)
        (official-admission-increment-lanes lanes :tournament-selected)))))

(defun official-admission-history-path ()
  "Return the append-only admission audit path."
  (and *checkpoint-directory*
       (checkpoint-path *checkpoint-directory*
                        "official-admission-history.lisp")))

(defun persist-official-admission-record (record)
  "Append one readable admission RECORD for lane-rate analysis."
  (let ((path (official-admission-history-path)))
    (when path
      (ensure-directories-exist path)
      (with-open-file (stream path :direction :output
                              :if-exists :append
                              :if-does-not-exist :create)
        (with-standard-io-syntax
          (let ((*print-readably* t) (*print-pretty* nil))
            (write record :stream stream)
            (terpri stream)))))))

(defun official-admission-note-full-outcome (result)
  "Attribute a completed full-racing RESULT to every nomination lane."
  (let* ((lanes (copy-list (getf result :nomination-lanes)))
         (record (getf result :evaluation-record))
         (stage (getf record :stage))
         (paired-mean (getf record :paired-mean 0.0d0)))
    (when lanes
      (official-admission-increment-lanes lanes :full-evaluated)
      (when (> paired-mean 0.0d0)
        (official-admission-increment-lanes lanes :positive-official))
      (unless (eq stage :racing)
        (official-admission-increment-lanes lanes :stage-1-reached))
      (when (eq stage :promotion-stage-4)
        (official-admission-increment-lanes lanes :stage-4-reached))
      (when (getf result :accepted)
        (official-admission-increment-lanes lanes :promoted))
      (persist-official-admission-record
       (list :type :full-outcome :protocol +official-admission-protocol+
             :generation (getf result :candidate-generation)
             :lanes lanes :stage stage :paired-mean paired-mean
             :accepted (not (null (getf result :accepted))))))))

(defun official-admission-summary ()
  "Return a stable copy of per-lane counters for telemetry and analysis."
  (sort (copy-tree *official-admission-lane-statistics*)
        #'string< :key (lambda (entry) (symbol-name (car entry)))))
