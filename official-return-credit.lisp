(in-package :cl-tpg)

;;; Phase 5B keeps the Phase-5A paired child/direct-parent measurement, but
;;; admits behavior-changing children before neutral fallbacks and gives an
;;; approved lineage a small, checkpointed survival budget. Native mutation,
;;; grouped epsilon-lexicase, and historical promotion remain unchanged.

(defun official-return-credit-active-p ()
  "Return true when the isolated Phase-5B treatment is active."
  (and *official-return-credit-enabled*
       (official-guided-mode-p)
       *semantic-locality-control-enabled*
       *phase4-selection-enabled*
       (not *phase4b-routing-repair-enabled*)
       (not *phase4b-specialist-composition-enabled*)
       (not *phase4b-combined-repair-enabled*)))

(defun official-return-credit-serialize-lineage (record)
  "Return the persistent portion of one active lineage RECORD."
  (list :lineage-id (getf record :lineage-id)
        :team-id (getf record :team-id)
        :checkpoint-path (getf record :checkpoint-path)
        :created-generation (getf record :created-generation)
        :approved-generation (getf record :approved-generation)
        :approved-steps (getf record :approved-steps 1)
        :remaining-selection-cycles
          (getf record :remaining-selection-cycles 0)
        :credit-delta (getf record :credit-delta)
        :credit-margin (getf record :credit-margin)))

(defun official-return-credit-state-copy ()
  "Return serializable Phase-5B counters and active lineage anchors."
  (when *official-return-credit-enabled*
    (list :version 2
          :protocol +official-return-credit-protocol+
          :approved-count *official-return-credit-approved-count*
          :rejected-count *official-return-credit-rejected-count*
          :next-lineage-id *official-return-credit-next-lineage-id*
          :neutral-submissions *official-return-credit-neutral-submissions*
          :active-lineages
            (mapcar #'official-return-credit-serialize-lineage
                    *official-return-credit-active-lineages*))))

(defun official-return-credit-load-anchor (path lineage-id)
  "Load PATH as an independent live root belonging to LINEAGE-ID."
  (unless (probe-file path)
    (error "Cannot restore return-credit lineage ~A; anchor is missing: ~A"
           lineage-id path))
  (unless *official-return-credit-team-lineages*
    (setf *official-return-credit-team-lineages*
            (make-hash-table :test #'eq)))
  (let ((anchor (load-best-team path)))
    (ensure-team-observation-compatible anchor *num-observations*)
    (setf (team-type anchor) :root
          (team-references anchor) 0)
    (dolist (team (closure anchor))
      (pushnew team *teams* :test #'eq))
    (setf (gethash anchor *official-return-credit-team-lineages*)
            lineage-id)
    anchor))

(defun restore-official-return-credit-state (state)
  "Restore validated Phase-5B counters and independently saved anchors."
  (when state
    (let ((version (getf state :version 0))
          (protocol (getf state :protocol)))
      (unless (or (and (= version 2)
                       (eq protocol +official-return-credit-protocol+))
                  ;; Phase 5A counters can be read for mechanical compatibility,
                  ;; but they contain no protected lineage to revive.
                  (and (= version 1)
                       (eq protocol
                           :paired-parent-child-return-credit-phase5a-v1)))
        (error "Invalid official return-credit state: ~S" state))
      (setf *official-return-credit-approved-count*
              (getf state :approved-count 0)
            *official-return-credit-rejected-count*
              (getf state :rejected-count 0)
            *official-return-credit-next-lineage-id*
              (if (= version 2) (getf state :next-lineage-id 0) 0)
            *official-return-credit-neutral-submissions*
              (if (= version 2) (getf state :neutral-submissions 0) 0)
            *official-return-credit-active-lineages* nil
            *official-return-credit-team-lineages*
              (make-hash-table :test #'eq))
      (when (= version 2)
        (dolist (saved (getf state :active-lineages))
          (when (plusp (getf saved :remaining-selection-cycles 0))
            (let* ((lineage-id (getf saved :lineage-id))
                   (path (getf saved :checkpoint-path))
                   (anchor
                     (official-return-credit-load-anchor path lineage-id)))
              (push (append (copy-tree saved) (list :team anchor))
                    *official-return-credit-active-lineages*)))))))
  state)

(defun reset-official-return-credit-state ()
  "Reset run-local Phase-5B counters, lineages, and staging metadata."
  (setf *official-return-credit-approved-count* 0
        *official-return-credit-rejected-count* 0
        *official-return-credit-next-lineage-id* 0
        *official-return-credit-neutral-submissions* 0
        *official-return-credit-active-lineages* nil
        *official-return-credit-team-lineages*
          (make-hash-table :test #'eq)
        *online-staged-best-credit-priority* nil
        *online-staged-best-credit-lineage-id* nil))

(defun official-return-credit-continue-p (child-returns parent-returns)
  "Return true unless the Stage-1 paired evidence establishes futility."
  (multiple-value-bind (mean se)
      (official-guided-comparison-statistics child-returns parent-returns)
    (let ((margin (* +official-return-credit-standard-errors+ se)))
      (values (> (+ mean margin) 0.0d0) mean margin))))

(defun official-return-credit-approve-p (child-returns parent-returns)
  "Approve only a positive child/direct-parent paired uncertainty margin."
  (multiple-value-bind (mean se)
      (official-guided-comparison-statistics child-returns parent-returns)
    (let ((margin (* +official-return-credit-standard-errors+ se)))
      (values (> mean margin) mean margin))))

(defun make-official-return-credit-record
       (&key stage seeds child-returns parent-returns accepted
             behavioral-locality margin)
  "Build one structured Phase-5B direct-parent credit record."
  (append
   (make-official-guided-evaluation-record
    :stage stage
    :imitation-score nil
    :seeds seeds
    :candidate-returns child-returns
    :incumbent-returns parent-returns
    :accepted accepted)
   (list :credit-protocol +official-return-credit-protocol+
         :comparison :child-versus-direct-parent
         :margin margin
         :behavioral-locality (copy-tree behavioral-locality))))

(defun official-return-credit-behavior-changing-record-p (record)
  "Return true when RECORD changes Top-1 or ranked probe behavior."
  (and record
       (or (plusp (getf record :top1-hamming 0.0d0))
           (plusp (getf record :ranking-distance-mean 0.0d0)))))

(defun official-return-credit-lineage-for-team (team)
  "Return TEAM's inherited credit lineage identifier, if any."
  (and *official-return-credit-team-lineages*
       (gethash team *official-return-credit-team-lineages*)))

(defun official-return-credit-lineage-active-p (lineage-id)
  "Return true when LINEAGE-ID still owns a protected anchor budget."
  (and lineage-id
       (find lineage-id *official-return-credit-active-lineages*
             :key (lambda (record) (getf record :lineage-id))
             :test #'equal)))

(defun official-return-credit-candidate-priority (team)
  "Return Phase-5B admission priority for one direct mutation child.

Four is a changed child of an active lineage, three is another changed child,
two is an active-lineage neutral fallback, one is another neutral fallback,
and zero means no measurable direct parent is available."
  (let ((parent (behavioral-parent-for-team team)))
    (if (null parent)
        0
        (let* ((record (behavioral-lineage-for-team team))
               (changed
                 (official-return-credit-behavior-changing-record-p record))
               (lineage-id
                 (official-return-credit-lineage-for-team team))
               (active
                 (official-return-credit-lineage-active-p lineage-id)))
          (cond ((and changed active) 4)
                (changed 3)
                (active 2)
                (t 1))))))

(defun official-return-credit-candidate-entry (sorted)
  "Choose the strongest entry in the highest Phase-5B admission class."
  (let ((best nil)
        (best-priority 0))
    ;; SORTED is already descending by imitation, so ties retain its first row.
    (dolist (entry sorted best)
      (let ((priority
              (official-return-credit-candidate-priority (car entry))))
        (when (> priority best-priority)
          (setf best entry
                best-priority priority))))))

(defun official-return-credit-note-descendant (parent child)
  "Propagate PARENT's credit-lineage identity to CHILD."
  (when *official-return-credit-team-lineages*
    (let ((lineage-id
            (gethash parent *official-return-credit-team-lineages*)))
      (when lineage-id
        (setf (gethash child *official-return-credit-team-lineages*)
                lineage-id))))
  child)

(defun official-return-credit-prune-team-lineages ()
  "Retain lineage tags only for roots still in the live population."
  (when *official-return-credit-team-lineages*
    (let ((retained (make-hash-table :test #'eq)))
      (dolist (team (root-teams))
        (multiple-value-bind (lineage-id present-p)
            (gethash team *official-return-credit-team-lineages*)
          (when present-p
            (setf (gethash team retained) lineage-id))))
      (setf *official-return-credit-team-lineages* retained))))

(defun official-return-credit-next-id (generation)
  "Return a deterministic identifier for a newly approved lineage."
  (incf *official-return-credit-next-lineage-id*)
  (format nil "RETURN-CREDIT-~D-G~D"
          *official-return-credit-next-lineage-id* generation))

(defun official-return-credit-trim-active-lineages ()
  "Enforce the frozen maximum active-lineage budget and return evicted IDs."
  (let ((evicted nil))
    (loop while (> (length *official-return-credit-active-lineages*)
                   +official-return-credit-max-active-lineages+)
          do (let* ((oldest
                      (reduce
                       (lambda (left right)
                         (if (< (getf left :approved-generation 0)
                                (getf right :approved-generation 0))
                             left right))
                       *official-return-credit-active-lineages*))
                    (id (getf oldest :lineage-id)))
               (push id evicted)
               (setf *official-return-credit-active-lineages*
                       (remove oldest
                               *official-return-credit-active-lineages*
                               :test #'eq))))
    (nreverse evicted)))

(defun install-official-return-credit-anchor
       (candidate-path &key generation evaluation lineage-id
                              (count-approval-p t))
  "Load CANDIDATE-PATH as a bounded, independently owned lineage anchor.

An approval continuing an existing lineage replaces that lineage's protected
anchor; the previous root remains live but competes normally. The anchor is
not *BEST-TEAM* and cannot bypass fresh global Stage-3 promotion."
  (let* ((generation (or generation *generation* 0))
         (lineage-id
           (or lineage-id (official-return-credit-next-id generation)))
         (previous
           (find lineage-id *official-return-credit-active-lineages*
                 :key (lambda (record) (getf record :lineage-id))
                 :test #'equal))
         (anchor
           (official-return-credit-load-anchor candidate-path lineage-id))
         (record
           (list :lineage-id lineage-id
                 :team anchor
                 :team-id (team-id anchor)
                 :checkpoint-path (namestring (pathname candidate-path))
                 :created-generation
                   (if previous
                       (getf previous :created-generation generation)
                       generation)
                 :approved-generation generation
                 :approved-steps (1+ (if previous
                                         (getf previous :approved-steps 0)
                                         0))
                 :remaining-selection-cycles
                   +official-return-credit-protection-generations+
                 :credit-delta (and evaluation
                                    (getf evaluation :paired-mean))
                 :credit-margin (and evaluation
                                     (getf evaluation :margin)))))
    (setf *official-return-credit-active-lineages*
            (cons record
                  (remove lineage-id
                          *official-return-credit-active-lineages*
                          :key (lambda (item) (getf item :lineage-id))
                          :test #'equal)))
    (when count-approval-p
      (incf *official-return-credit-approved-count*))
    (values anchor lineage-id
            (official-return-credit-trim-active-lineages))))

(defun official-return-credit-protected-teams ()
  "Return live roots whose Phase-5B selection budget remains positive."
  (let ((roots (root-teams)))
    (loop for record in *official-return-credit-active-lineages*
          for team = (getf record :team)
          when (and team
                    (plusp (getf record :remaining-selection-cycles 0))
                    (member team roots :test #'eq))
            collect team)))

(defun official-return-credit-note-selection (selected-teams)
  "Spend one protection cycle for selected anchors and retire exhausted ones."
  (let ((roots (root-teams))
        (expired nil)
        (retained nil))
    (dolist (record *official-return-credit-active-lineages*)
      (let* ((team (getf record :team))
             (live-p (and team (member team roots :test #'eq))))
        (when (and team (member team selected-teams :test #'eq)
                   (plusp (getf record :remaining-selection-cycles 0)))
          (decf (getf record :remaining-selection-cycles)))
        (if (and live-p
                 (plusp (getf record :remaining-selection-cycles 0)))
            (push record retained)
            (push (getf record :lineage-id) expired))))
    (setf *official-return-credit-active-lineages* (nreverse retained))
    (nreverse expired)))

(defun persist-official-return-credit-outcome
       (generation evaluation anchor-id
        &key candidate-priority candidate-lineage-id installed-lineage-id
             evicted-lineage-ids)
  "Append one compact causal Phase-5B decision to the research journal."
  (when (behavioral-locality-active-p)
    (append-behavioral-locality-form
     (list :type :official-return-credit-outcome
           :protocol +official-return-credit-protocol+
           :generation generation
           :accepted (getf evaluation :accepted)
           :candidate-priority candidate-priority
           :candidate-lineage-id candidate-lineage-id
           :installed-lineage-id installed-lineage-id
           :anchor-id anchor-id
           :evicted-lineage-ids (copy-list evicted-lineage-ids)
           :active-lineages
             (mapcar #'official-return-credit-serialize-lineage
                     *official-return-credit-active-lineages*)
           :evaluation (copy-tree evaluation)))))
