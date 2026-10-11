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
       (list :version 1
             :protocol +official-admission-protocol+
             :batch-count *official-admission-batch-count*
             :lane-statistics
               (copy-tree *official-admission-lane-statistics*))))

(defun restore-official-admission-state (state)
  "Restore cumulative diagnostics; in-flight worker processes are never reused."
  (unless (and (listp state)
               (= (getf state :version 0) 1)
               (eq (getf state :protocol) +official-admission-protocol+)
               (integerp (getf state :batch-count))
               (not (minusp (getf state :batch-count))))
    (error "Invalid official admission state: ~S" state))
  (setf *official-admission-batch-count* (getf state :batch-count)
        *official-admission-lane-statistics*
          (copy-tree (getf state :lane-statistics)))
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
        *online-staged-best-nomination-lanes* nil))

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
    (loop repeat (official-admission-lane-count :behavioral-diversity)
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
    (let ((remaining (official-admission-lane-count :critical-error)))
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
