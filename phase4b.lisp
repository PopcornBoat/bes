(in-package :cl-tpg)

;;; Phase 4b-A uses systematic DAgger disagreements to propose local routing
;;; variants.  It never edits an incumbent or a shared internal team.  A root
;;; is cloned, one cloned root learner's bid program is mutated through the
;;; native program operator, and the child must pass target-group, collateral,
;;; and behavioral-locality gates before entering normal survivor selection.

(defun phase4b-combined-repair-configured-p ()
  "Return true when the Phase-4b-C combined treatment is configured."
  (and *phase4b-combined-repair-enabled*
       *phase4b-routing-repair-enabled*
       *phase4b-specialist-composition-enabled*))

(defun phase4b-routing-repair-active-p ()
  "Return true when targeted routing variation is safe to run."
  (and *phase4b-routing-repair-enabled*
       *phase4b-disagreement-audit-enabled*
       *semantic-locality-control-enabled*
       *behavioral-locality-enabled*
       (official-guided-mode-p)
       (eq *terminal-action-format* :target-response-36)))

(defun initialize-phase4b-routing-repair-state (search-seed)
  "Initialize the independent counter-based Phase-4b-A scheduling stream."
  (unless (integerp search-seed)
    (error "Phase-4b-A requires an integer search seed, got ~S."
           search-seed))
  (setf *phase4b-routing-repair-rng-root*
          (official-guided-mix64
           (+ search-seed +phase4b-routing-repair-rng-salt+))
        *phase4b-routing-repair-rng-cursor* 0
        *phase4b-routing-repair-age* 0
        *phase4b-routing-repair-generation-records* nil))

(defun phase4b-routing-repair-state-copy ()
  "Return a serialization-safe copy of Phase-4b-A scheduling state."
  (and *phase4b-routing-repair-rng-root*
       (list :version 1
             :protocol +phase4b-routing-repair-protocol+
             :root *phase4b-routing-repair-rng-root*
             :cursor *phase4b-routing-repair-rng-cursor*
             :age *phase4b-routing-repair-age*)))

(defun phase4b-routing-repair-state-valid-p (state)
  "Return true when STATE can exactly resume Phase-4b-A scheduling."
  (and (listp state)
       (= (getf state :version 0) 1)
       (eq (getf state :protocol) +phase4b-routing-repair-protocol+)
       (integerp (getf state :root))
       (integerp (getf state :cursor))
       (not (minusp (getf state :cursor)))
       (integerp (getf state :age))
       (not (minusp (getf state :age)))))

(defun restore-phase4b-routing-repair-state (state)
  "Restore validated Phase-4b-A state without touching *RANDOM-STATE*."
  (unless (phase4b-routing-repair-state-valid-p state)
    (error "Invalid Phase-4b-A routing-repair state: ~S" state))
  (setf *phase4b-routing-repair-rng-root* (getf state :root)
        *phase4b-routing-repair-rng-cursor* (getf state :cursor)
        *phase4b-routing-repair-age* (getf state :age)
        *phase4b-routing-repair-generation-records* nil))

(defun phase4b-routing-random-below (limit)
  "Draw below LIMIT from the isolated counter-based repair stream."
  (unless (and (integerp limit) (plusp limit))
    (error "Phase-4b-A random bound must be positive, got ~S." limit))
  (unless *phase4b-routing-repair-rng-root*
    (error "Phase-4b-A routing-repair state is not initialized."))
  (prog1
      (mod (official-guided-mix64
            (+ *phase4b-routing-repair-rng-root*
               *phase4b-routing-repair-rng-cursor*))
           limit)
    (incf *phase4b-routing-repair-rng-cursor*)))

(defun phase4b-routing-repair-slot-p ()
  "Choose whether one offspring slot receives targeted variation."
  (< (/ (coerce (phase4b-routing-random-below 1000000) 'double-float)
        1000000.0d0)
     +phase4b-routing-repair-quota+))

(defun phase4b-systematic-routing-issues ()
  "Return current systematic Case-A/B1 issues; Case-B2 remains deferred."
  (remove-if-not
   (lambda (issue)
     (and (getf issue :systematic-p)
          (member (getf issue :case)
                  '(:case-a-routing :case-b1-reachable-support)
                  :test #'eq)))
   (getf (getf *last-dagger-diagnostics* :phase4b-repair-audit)
         :systematic-issues)))

(defun phase4b-weighted-issue (issues)
  "Select one issue proportional to its observed occurrence count."
  (let ((total (loop for issue in issues
                     sum (max 1 (getf issue :occurrences 1)))))
    (when (plusp total)
      (let ((draw (phase4b-routing-random-below total)))
        (dolist (issue issues (car (last issues)))
          (let ((weight (max 1 (getf issue :occurrences 1))))
            (if (< draw weight)
                (return issue)
                (decf draw weight))))))))

(defun phase4b-team-supports-pair-p (team pair)
  "Return true when TEAM's reachable genotype contains PAIR."
  (gethash pair (phase4b-behavior-terminal-support team)))

(defun phase4b-action-supports-pair-p (action pair)
  "Return true when root ACTION directly or transitively supports PAIR."
  (if (eq (action-type action) :atomic)
      (let ((payload (action-action action)))
        (and (target-response-36-action-p payload)
             (equal pair
                    (list (target-response-36-action-target payload)
                          (target-response-36-action-response payload)))))
      (phase4b-team-supports-pair-p (action-action action) pair)))

(defun phase4b-supporting-root-learner-indices (team pair)
  "Return root learner indices whose action path can reach PAIR."
  (loop for learner in (team-learners team)
        for index fixnum from 0
        when (phase4b-action-supports-pair-p
              (learner-action learner) pair)
          collect index))

(defun phase4b-row-matches-issue-p (dataset index issue)
  "Return true when DATASET row INDEX has ISSUE's phase and teacher pair."
  (let ((steps (dataset-steps dataset)))
    (and steps
         (eq (dagger-diagnostic-phase (aref steps index))
             (getf issue :phase))
         (equal (semantic-label-category-pair
                 (aref (actions dataset) index))
                (getf issue :teacher-pair)))))

(defun phase4b-parent-row-contexts (parent dataset issue)
  "Collect bounded current-generation rows where PARENT reproduces ISSUE."
  (let ((contexts nil)
        (teacher (getf issue :teacher-pair))
        (predicted (getf issue :predicted-pair))
        (case (getf issue :case)))
    (dotimes (index (dataset-size dataset) (nreverse contexts))
      (when (phase4b-row-matches-issue-p dataset index issue)
        (let* ((observation
                 (policy-observation
                  (aref (observations dataset) index)))
               (ranking (behavioral-ranking-pairs parent observation))
               (rank (position teacher ranking :test #'equal)))
          (when (and (equal (first ranking) predicted)
                     (ecase case
                       (:case-a-routing (not (null rank)))
                       (:case-b1-reachable-support (null rank))))
            (push (list :observation observation
                        :teacher-pair teacher
                        :parent-ranking ranking
                        :parent-rank
                          (or rank +semantic-ranking-limit+))
                  contexts)
            (when (>= (length contexts) 32)
              (return (nreverse contexts)))))))))

(defun phase4b-target-group-comparison (child contexts)
  "Compare CHILD with the parent rankings cached in CONTEXTS."
  (let ((count 0)
        (parent-rank-sum 0.0d0)
        (child-rank-sum 0.0d0)
        (rank-improvements 0)
        (rank-regressions 0)
        (top1-gains 0)
        (top1-losses 0))
    (dolist (context contexts)
      (let* ((teacher (getf context :teacher-pair))
             (parent-ranking (getf context :parent-ranking))
             (child-ranking
               (behavioral-ranking-pairs
                child (getf context :observation)))
             (parent-rank (getf context :parent-rank))
             (child-rank
               (or (position teacher child-ranking :test #'equal)
                   +semantic-ranking-limit+))
             (parent-exact (equal (first parent-ranking) teacher))
             (child-exact (equal (first child-ranking) teacher)))
        (incf count)
        (incf parent-rank-sum parent-rank)
        (incf child-rank-sum child-rank)
        (cond ((< child-rank parent-rank) (incf rank-improvements))
              ((> child-rank parent-rank) (incf rank-regressions)))
        (when (and child-exact (not parent-exact))
          (incf top1-gains))
        (when (and parent-exact (not child-exact))
          (incf top1-losses))))
    (let ((denominator (coerce (max 1 count) 'double-float)))
      (list :row-count count
            :parent-mean-rank (/ parent-rank-sum denominator)
            :child-mean-rank (/ child-rank-sum denominator)
            :rank-improvements rank-improvements
            :rank-regressions rank-regressions
            :top1-gains top1-gains
            :top1-losses top1-losses))))

(defun phase4b-target-comparison-improves-p (comparison)
  "Return true for a monotonic improvement on the selected error group."
  (and (>= (getf comparison :row-count 0)
           +phase4b-routing-repair-minimum-rows+)
       (zerop (getf comparison :top1-losses 0))
       (or (plusp (getf comparison :top1-gains 0))
           (and (plusp (getf comparison :rank-improvements 0))
                (< (getf comparison :child-mean-rank)
                   (getf comparison :parent-mean-rank))))))

(defun phase4b-probe-belongs-to-issue-p (probe issue)
  "Return true when PROBE belongs to ISSUE's teacher/phase group."
  (let ((step (getf probe :step)))
    (and (integerp step)
         (eq (dagger-diagnostic-phase step) (getf issue :phase))
         (equal (getf probe :teacher-pair)
                (getf issue :teacher-pair)))))

(defun phase4b-collateral-comparison (parent child issue)
  "Measure damage outside ISSUE's group on the versioned probe archive."
  (let ((considered 0)
        (exact-losses 0)
        (rank-regressions 0))
    (loop for probe in *behavioral-probe-archive*
          for before in (behavioral-policy-signature parent)
          for after in (behavioral-policy-signature child)
          unless (phase4b-probe-belongs-to-issue-p probe issue)
            do (incf considered)
               (when (and (equal (getf before :top1)
                                  (getf probe :teacher-pair))
                          (not (equal (getf after :top1)
                                      (getf probe :teacher-pair))))
                 (incf exact-losses))
               (when (> (getf after :teacher-rank)
                        (getf before :teacher-rank))
                 (incf rank-regressions)))
    (list :probe-count considered
          :exact-losses exact-losses
          :rank-regressions rank-regressions
          :rank-regression-rate
            (/ rank-regressions
               (coerce (max 1 considered) 'double-float)))))

(defun phase4b-collateral-acceptable-p (collateral locality-record)
  "Apply collateral and existing Phase-3 bounded-locality gates."
  (and (zerop (getf collateral :exact-losses 0))
       (<= (getf collateral :rank-regression-rate 0.0d0)
           +phase4b-routing-repair-max-collateral-rank-rate+)
       (<= (getf locality-record :top1-hamming 1.0d0) 0.20d0)
       (<= (getf locality-record :ranking-distance-mean 1.0d0) 0.20d0)))

(defun phase4b-record-routing-attempt (record)
  "Retain one serializable slot-level Phase-4b-A decision."
  (push (copy-tree record) *phase4b-routing-repair-generation-records*)
  record)

(defun phase4b-try-parent-issue (parent issue contexts learner-indices)
  "Try bounded root-program variants for one PARENT/ISSUE combination."
  (let ((learner-start
          (phase4b-routing-random-below (length learner-indices))))
    (loop for attempt from 1 to +phase4b-routing-repair-max-attempts+
          for learner-index =
            (nth (mod (+ learner-start (1- attempt))
                      (length learner-indices))
                 learner-indices)
          for child = (clone-team parent)
          do (let* ((learner (nth learner-index (team-learners child)))
                    (before (pprint-program (learner-program learner)))
                    (*active-mutation-events* nil))
               (mutate-program (learner-program learner))
               (let ((after (pprint-program (learner-program learner))))
                 (if (equal before after)
                     (discard-semantic-locality-candidate child)
                     (progn
                       (note-mutation-event :targeted-routing-repair)
                       (let* ((events (nreverse *active-mutation-events*))
                              (target
                                (phase4b-target-group-comparison
                                 child contexts))
                              (locality
                                (make-behavioral-mutation-record
                                 parent child events))
                              (collateral
                                (phase4b-collateral-comparison
                                 parent child issue)))
                         (if (and locality
                                  (phase4b-target-comparison-improves-p target)
                                  (phase4b-collateral-acceptable-p
                                   collateral locality))
                             (progn
                               (setf
                                (getf locality :control-protocol)
                                  +semantic-locality-control-protocol+
                                (getf locality :control-stage)
                                  :phase4b-routing-repair
                                (getf locality :control-age)
                                  *semantic-locality-control-age*
                                (getf locality :control-requested-tier)
                                  :targeted
                                (getf locality :control-tier) :bounded
                                (getf locality :control-effective-tier)
                                  :bounded
                                (getf locality :control-escalated-p) nil
                                (getf locality :control-attempts) attempt
                                (getf locality :control-fallback-p) nil
                                (getf locality :phase4b-issue)
                                  (copy-tree issue)
                                (getf locality :phase4b-root-learner-index)
                                  learner-index
                                (getf locality :phase4b-target-comparison)
                                  target
                                (getf locality :phase4b-collateral)
                                  collateral)
                               (register-behavioral-mutation-record
                                parent child locality)
                               (push (copy-tree locality)
                                     *semantic-locality-control-generation-records*)
                               (return-from phase4b-try-parent-issue
                                 (values child locality attempt learner-index)))
                             (discard-semantic-locality-candidate child))))))))
    (values nil nil +phase4b-routing-repair-max-attempts+ nil)))

(defun phase4b-attempt-routing-repair (parents &optional selected-issue)
  "Attempt one routing child, optionally for SELECTED-ISSUE, and return CHILD/PARENT."
  (let ((issues (if selected-issue
                    (list selected-issue)
                    (phase4b-systematic-routing-issues))))
    (unless (and issues *teacher-training-dataset*)
      (phase4b-record-routing-attempt
       (list :protocol +phase4b-routing-repair-protocol+
             :generation *generation* :accepted nil
             :reason :no-systematic-issues))
      (return-from phase4b-attempt-routing-repair (values nil nil)))
    (let* ((issue (or selected-issue (phase4b-weighted-issue issues)))
           (teacher-pair (getf issue :teacher-pair))
           (eligible
             (remove-if-not
              (lambda (team)
                (phase4b-team-supports-pair-p team teacher-pair))
              parents)))
      (unless eligible
        (phase4b-record-routing-attempt
         (list :protocol +phase4b-routing-repair-protocol+
               :generation *generation* :accepted nil
               :reason :no-supporting-parent :issue (copy-tree issue)))
        (return-from phase4b-attempt-routing-repair (values nil nil)))
      (let ((start (phase4b-routing-random-below (length eligible)))
            (checked 0))
        (loop for offset below (min 8 (length eligible))
              for parent = (nth (mod (+ start offset) (length eligible))
                                eligible)
              for contexts =
                (phase4b-parent-row-contexts
                 parent *teacher-training-dataset* issue)
              for learner-indices =
                (phase4b-supporting-root-learner-indices
                 parent teacher-pair)
              do (incf checked)
                 (when (and (>= (length contexts)
                                +phase4b-routing-repair-minimum-rows+)
                            learner-indices)
                   (multiple-value-bind
                         (child locality attempts learner-index)
                       (phase4b-try-parent-issue
                        parent issue contexts learner-indices)
                     (when child
                       (phase4b-record-routing-attempt
                        (list :protocol +phase4b-routing-repair-protocol+
                              :generation *generation*
                              :accepted t
                              :issue (copy-tree issue)
                              :parent-team-id (team-id parent)
                              :child-team-id (team-id child)
                              :parents-checked checked
                              :candidate-attempts attempts
                              :root-learner-index learner-index
                              :target-comparison
                                (copy-tree
                                 (getf locality
                                       :phase4b-target-comparison))
                              :collateral
                                (copy-tree
                                 (getf locality :phase4b-collateral))
                              :top1-hamming
                                (getf locality :top1-hamming)
                              :ranking-distance
                                (getf locality :ranking-distance-mean)))
                       (return-from phase4b-attempt-routing-repair
                         (values child parent))))))
        (phase4b-record-routing-attempt
         (list :protocol +phase4b-routing-repair-protocol+
               :generation *generation* :accepted nil
               :reason :no-acceptable-local-repair
               :issue (copy-tree issue)
               :parents-checked checked))
        (values nil nil)))))

(defun finish-phase4b-routing-repair-generation ()
  "Journal and summarize Phase-4b-A decisions, then advance its age."
  (when (phase4b-routing-repair-active-p)
    (let* ((records
             (nreverse *phase4b-routing-repair-generation-records*))
           (attempted (length records))
           (accepted
             (count-if (lambda (record) (getf record :accepted)) records)))
      (when attempted
        (emit-message
         (format nil
                 "Generation ~D Phase-4b-A routing repair: slots=~D accepted=~D fallback=~D."
                 *generation* attempted accepted (- attempted accepted)))
        (when (behavioral-locality-active-p)
          (append-behavioral-locality-form
           (list :type :phase4b-routing-repair-generation
                 :protocol +phase4b-routing-repair-protocol+
                 :generation *generation*
                 :age *phase4b-routing-repair-age*
                 :attempted attempted
                 :accepted accepted
                 :fallback (- attempted accepted)
                 :records records))))
      (incf *phase4b-routing-repair-age*)
      (setf *phase4b-routing-repair-generation-records* nil))))

;;; Phase 4b-B is a separate controlled treatment.  It consumes only
;;; systematic Case-B1 errors, where the behavior root omits the teacher pair
;;; from Top-8 even though the vocabulary exists.  A child first tries to link
;;; a current group-elite root as a reusable subgraph.  The candidate owns a
;;; new gateway learner; donor teams are never edited.  If no live donor is
;;; qualified, a direct terminal specialist is tried as a recorded fallback.
;;; Every candidate passes the same target, collateral, and locality gates as
;;; Phase 4b-A before normal lexicase and official evaluation can see it.

(defun phase4b-specialist-composition-active-p ()
  "Return true when Phase-4b-B composition is safe to run alone or in 4b-C."
  (and *phase4b-specialist-composition-enabled*
       (or (not *phase4b-routing-repair-enabled*)
           (phase4b-combined-repair-configured-p))
       *phase4b-disagreement-audit-enabled*
       *phase4-selection-enabled*
       *semantic-locality-control-enabled*
       *behavioral-locality-enabled*
       (official-guided-mode-p)
       (eq *terminal-action-format* :target-response-36)))

(defun initialize-phase4b-specialist-composition-state (search-seed)
  "Initialize the independent counter-based Phase-4b-B stream."
  (unless (integerp search-seed)
    (error "Phase-4b-B requires an integer search seed, got ~S."
           search-seed))
  (setf *phase4b-specialist-composition-rng-root*
          (official-guided-mix64
           (+ search-seed +phase4b-specialist-composition-rng-salt+))
        *phase4b-specialist-composition-rng-cursor* 0
        *phase4b-specialist-composition-age* 0
        *phase4b-specialist-composition-generation-records* nil))

(defun phase4b-specialist-composition-state-copy ()
  "Return a serialization-safe copy of Phase-4b-B scheduling state."
  (and *phase4b-specialist-composition-rng-root*
       (list :version 1
             :protocol +phase4b-specialist-composition-protocol+
             :root *phase4b-specialist-composition-rng-root*
             :cursor *phase4b-specialist-composition-rng-cursor*
             :age *phase4b-specialist-composition-age*)))

(defun phase4b-specialist-composition-state-valid-p (state)
  "Return true when STATE can exactly resume Phase-4b-B scheduling."
  (and (listp state)
       (= (getf state :version 0) 1)
       (eq (getf state :protocol)
           +phase4b-specialist-composition-protocol+)
       (integerp (getf state :root))
       (integerp (getf state :cursor))
       (not (minusp (getf state :cursor)))
       (integerp (getf state :age))
       (not (minusp (getf state :age)))))

(defun restore-phase4b-specialist-composition-state (state)
  "Restore validated Phase-4b-B state without touching *RANDOM-STATE*."
  (unless (phase4b-specialist-composition-state-valid-p state)
    (error "Invalid Phase-4b-B specialist-composition state: ~S" state))
  (setf *phase4b-specialist-composition-rng-root* (getf state :root)
        *phase4b-specialist-composition-rng-cursor* (getf state :cursor)
        *phase4b-specialist-composition-age* (getf state :age)
        *phase4b-specialist-composition-generation-records* nil))

(defun phase4b-specialist-composition-random-below (limit)
  "Draw below LIMIT from the isolated counter-based Phase-4b-B stream."
  (unless (and (integerp limit) (plusp limit))
    (error "Phase-4b-B random bound must be positive, got ~S." limit))
  (unless *phase4b-specialist-composition-rng-root*
    (error "Phase-4b-B specialist-composition state is not initialized."))
  (prog1
      (mod (official-guided-mix64
            (+ *phase4b-specialist-composition-rng-root*
               *phase4b-specialist-composition-rng-cursor*))
           limit)
    (incf *phase4b-specialist-composition-rng-cursor*)))

(defun phase4b-specialist-composition-slot-p ()
  "Choose whether one offspring slot receives Phase-4b-B variation."
  (< (/ (coerce
         (phase4b-specialist-composition-random-below 1000000)
         'double-float)
        1000000.0d0)
     +phase4b-specialist-composition-quota+))

(defun phase4b-systematic-composition-issues ()
  "Return systematic Case-B1 issues for the isolated composition pilot."
  (remove-if-not
   (lambda (issue)
     (and (getf issue :systematic-p)
          (eq (getf issue :case) :case-b1-reachable-support)))
   (getf (getf *last-dagger-diagnostics* :phase4b-repair-audit)
         :systematic-issues)))

(defun phase4b-weighted-composition-issue (issues)
  "Select one issue by occurrence count using the Phase-4b-B stream."
  (let ((total (loop for issue in issues
                     sum (max 1 (getf issue :occurrences 1)))))
    (when (plusp total)
      (let ((draw (phase4b-specialist-composition-random-below total)))
        (dolist (issue issues (car (last issues)))
          (let ((weight (max 1 (getf issue :occurrences 1))))
            (if (< draw weight)
                (return issue)
                (decf draw weight))))))))

(defun phase4b-composition-group-key (issue)
  "Return the most specific active Phase-4a group for ISSUE."
  (let* ((pair (getf issue :teacher-pair))
         (pair-key (list :teacher-pair (first pair) (second pair)))
         (phase-key (list :phase (getf issue :phase))))
    (cond
      ((find pair-key *phase4-case-groups*
             :key (lambda (group) (getf group :key)) :test #'equal)
       pair-key)
      ((find phase-key *phase4-case-groups*
             :key (lambda (group) (getf group :key)) :test #'equal)
       phase-key)
      (t nil))))

(defun phase4b-group-score-if-present (team key)
  "Return TEAM's current-generation group score and presence flag."
  (let ((table (and *phase4-team-group-scores*
                    (gethash team *phase4-team-group-scores*))))
    (if (and table key)
        (gethash key table)
        (values nil nil))))

(defun phase4b-group-qualified-donors (parents parent issue)
  "Return a bounded, stream-rotated set of live group-elite donor roots."
  (let* ((key (phase4b-composition-group-key issue))
         (scored
           (loop
             for team in parents
             unless (eq team parent)
               append
               (multiple-value-bind (score present-p)
                   (phase4b-group-score-if-present team key)
                 (when (and present-p
                            (not (creates-cycle-p parent team)))
                   (list (cons team score)))))))
    (unless scored
      (return-from phase4b-group-qualified-donors (values nil key)))
    (let* ((best (reduce #'max scored :key #'cdr))
           (epsilon (gethash key *phase4-group-epsilons* 0.0d0))
           (elite
             (remove-if
              (lambda (entry)
                (< (cdr entry)
                   (- best epsilon
                      +phase4-selection-numerical-tolerance+)))
              scored))
           (start
             (phase4b-specialist-composition-random-below (length elite))))
      (values
       (loop for offset below
               (min +phase4b-specialist-composition-max-donors+
                    (length elite))
             collect (nth (mod (+ start offset) (length elite)) elite))
       key))))

(defun phase4b-root-winning-learner (team observation)
  "Return TEAM's root-level winning learner under ordinary bid semantics."
  (let ((winner nil)
        (winning-bid nil)
        (register-buffer
          (make-array +num-registers+ :element-type 'double-float)))
    (dolist (learner (team-learners team) winner)
      (let ((value (bid learner observation register-buffer)))
        (when (or (null winner) (> value winning-bid))
          (setf winner learner
                winning-bid value))))))

(defun phase4b-assess-specialist-donor (entry contexts teacher-pair group-key)
  "Describe a group-elite donor that actually wins TEACHER-PAIR rows."
  (let* ((team (car entry))
         (group-score (cdr entry))
         (exact 0)
         (rank-sum 0.0d0)
         (gateway-counts (make-hash-table :test #'eq)))
    (dolist (context contexts)
      (let* ((observation (getf context :observation))
             (ranking (behavioral-ranking-pairs team observation))
             (rank (or (position teacher-pair ranking :test #'equal)
                       +semantic-ranking-limit+)))
        (incf rank-sum rank)
        (when (equal (first ranking) teacher-pair)
          (incf exact)
          (let ((gateway (phase4b-root-winning-learner team observation)))
            (when gateway
              (incf (gethash gateway gateway-counts 0)))))))
    (when (plusp exact)
      (let ((gateway
              (loop with best = nil
                    with best-count = -1
                    for learner in (team-learners team)
                    for count = (gethash learner gateway-counts 0)
                    when (> count best-count)
                      do (setf best learner best-count count)
                    finally (return best))))
        (when gateway
          (list :source-type :live-team-reference
                :team team
                :team-id (team-id team)
                :gateway gateway
                :group-key (copy-tree group-key)
                :group-score group-score
                :context-rows (length contexts)
                :exact-wins exact
                :exact-rate (/ exact (coerce (length contexts) 'double-float))
                :mean-teacher-rank
                  (/ rank-sum (coerce (length contexts) 'double-float))))))))

(defun phase4b-better-donor-p (left right)
  "Order donor assessments by exact coverage, rank, then group score."
  (or (> (getf left :exact-wins) (getf right :exact-wins))
      (and (= (getf left :exact-wins) (getf right :exact-wins))
           (or (< (getf left :mean-teacher-rank)
                  (getf right :mean-teacher-rank))
               (and (= (getf left :mean-teacher-rank)
                       (getf right :mean-teacher-rank))
                    (> (getf left :group-score)
                       (getf right :group-score)))))))

(defun phase4b-select-specialist-source (parents parent issue contexts)
  "Prefer the best bounded live donor; otherwise build a direct fallback."
  (multiple-value-bind (entries group-key)
      (phase4b-group-qualified-donors parents parent issue)
    (let ((assessments
            (remove nil
                    (mapcar
                     (lambda (entry)
                       (phase4b-assess-specialist-donor
                        entry contexts (getf issue :teacher-pair) group-key))
                     entries))))
      (if assessments
          (first (stable-sort assessments #'phase4b-better-donor-p))
          (let* ((observation (getf (first contexts) :observation))
                 (gateway (phase4b-root-winning-learner parent observation)))
            (and gateway
                 (list :source-type :direct-terminal-fallback
                       :team nil
                       :team-id nil
                       :gateway gateway
                       :group-key (copy-tree group-key)
                       :group-score nil
                       :context-rows (length contexts)
                       :exact-wins 0
                       :exact-rate 0.0d0
                       :mean-teacher-rank
                         (coerce +semantic-ranking-limit+
                                 'double-float))))))))

(defun phase4b-add-specialist-learner (child source teacher-pair attempt)
  "Add a donor reference or direct semantic terminal to CHILD."
  (when (>= (length (team-learners child)) *max-num-learners*)
    (return-from phase4b-add-specialist-learner nil))
  (let* ((gateway (getf source :gateway))
         (source-type (getf source :source-type))
         (program (clone-program (learner-program gateway)))
         (action
           (ecase source-type
             (:live-team-reference
              (let ((donor (getf source :team)))
                (when (creates-cycle-p child donor)
                  (return-from phase4b-add-specialist-learner nil))
                (add-reference donor)
                (make-action :type :reference :action donor)))
             (:direct-terminal-fallback
              (make-action
               :type :atomic
               :action
                 (make-target-response-36-action
                  :target (first teacher-pair)
                  :response (second teacher-pair))))))
         (learner (make-learner :program program :action action)))
    (push learner (team-learners child))
    (note-mutation-event
     (ecase source-type
       (:live-team-reference :specialist-team-reference-injection)
       (:direct-terminal-fallback :specialist-terminal-injection)))
    ;; Attempt one preserves the observed gateway exactly.  Later attempts use
    ;; the native program operator to seek a more discriminative entry bid.
    (when (> attempt 1)
      (mutate-program program))
    learner))

(defun phase4b-try-specialist-source
       (parent issue contexts source)
  "Try bounded gateway variants for one PARENT/ISSUE/SOURCE triple."
  (loop for attempt from 1 to +phase4b-specialist-composition-max-attempts+
        for child = (clone-team parent)
        do (let ((*active-mutation-events* nil))
             (if (null
                  (phase4b-add-specialist-learner
                   child source (getf issue :teacher-pair) attempt))
                 (discard-semantic-locality-candidate child)
                 (let* ((events (nreverse *active-mutation-events*))
                        (target
                          (phase4b-target-group-comparison child contexts))
                        (locality
                          (make-behavioral-mutation-record
                           parent child events))
                        (collateral
                          (phase4b-collateral-comparison parent child issue)))
                   (if (and locality
                            (phase4b-target-comparison-improves-p target)
                            (phase4b-collateral-acceptable-p
                             collateral locality))
                       (progn
                         (setf
                          (getf locality :control-protocol)
                            +semantic-locality-control-protocol+
                          (getf locality :control-stage)
                            :phase4b-specialist-composition
                          (getf locality :control-age)
                            *semantic-locality-control-age*
                          (getf locality :control-requested-tier) :targeted
                          (getf locality :control-tier) :bounded
                          (getf locality :control-effective-tier) :bounded
                          (getf locality :control-escalated-p) nil
                          (getf locality :control-attempts) attempt
                          (getf locality :control-fallback-p) nil
                          (getf locality :phase4b-issue) (copy-tree issue)
                          (getf locality :phase4b-composition-source)
                            (copy-tree
                             (loop for (key value) on source by #'cddr
                                   unless (member key '(:team :gateway)
                                                  :test #'eq)
                                     append (list key value)))
                          (getf locality :phase4b-target-comparison) target
                          (getf locality :phase4b-collateral) collateral)
                         (register-behavioral-mutation-record
                          parent child locality)
                         (push (copy-tree locality)
                               *semantic-locality-control-generation-records*)
                         (return-from phase4b-try-specialist-source
                           (values child locality attempt)))
                       (discard-semantic-locality-candidate child)))))
        finally
           (return (values nil nil
                           +phase4b-specialist-composition-max-attempts+))))

(defun phase4b-record-specialist-composition-attempt (record)
  "Retain one serializable slot-level Phase-4b-B decision."
  (push (copy-tree record)
        *phase4b-specialist-composition-generation-records*)
  record)

(defun phase4b-attempt-specialist-composition (parents &optional selected-issue)
  "Attempt one Case-B1 child, optionally for SELECTED-ISSUE, and return CHILD/PARENT."
  (let ((issues (if selected-issue
                    (list selected-issue)
                    (phase4b-systematic-composition-issues))))
    (unless (and issues *teacher-training-dataset*)
      (phase4b-record-specialist-composition-attempt
       (list :protocol +phase4b-specialist-composition-protocol+
             :generation *generation* :accepted nil
             :reason :no-systematic-case-b1))
      (return-from phase4b-attempt-specialist-composition
        (values nil nil)))
    (let* ((issue (or selected-issue
                      (phase4b-weighted-composition-issue issues)))
           (start
             (phase4b-specialist-composition-random-below (length parents)))
           (checked 0))
      (loop for offset below
              (min +phase4b-specialist-composition-max-parents+
                   (length parents))
            for parent = (nth (mod (+ start offset) (length parents)) parents)
            for contexts =
              (phase4b-parent-row-contexts
               parent *teacher-training-dataset* issue)
            do (incf checked)
               (when (>= (length contexts)
                         +phase4b-routing-repair-minimum-rows+)
                 (let ((source
                         (phase4b-select-specialist-source
                          parents parent issue contexts)))
                   (when source
                     (multiple-value-bind (child locality attempts)
                         (phase4b-try-specialist-source
                          parent issue contexts source)
                       (when child
                         (phase4b-record-specialist-composition-attempt
                          (list
                           :protocol
                             +phase4b-specialist-composition-protocol+
                           :generation *generation*
                           :accepted t
                           :issue (copy-tree issue)
                           :parent-team-id (team-id parent)
                           :child-team-id (team-id child)
                           :parents-checked checked
                           :candidate-attempts attempts
                           :source-type (getf source :source-type)
                           :donor-team-id (getf source :team-id)
                           :donor-group-key
                             (copy-tree (getf source :group-key))
                           :donor-group-score (getf source :group-score)
                           :donor-exact-wins (getf source :exact-wins)
                           :donor-exact-rate (getf source :exact-rate)
                           :donor-mean-teacher-rank
                             (getf source :mean-teacher-rank)
                           :target-comparison
                             (copy-tree
                              (getf locality
                                    :phase4b-target-comparison))
                           :collateral
                             (copy-tree
                              (getf locality :phase4b-collateral))
                           :top1-hamming
                             (getf locality :top1-hamming)
                           :ranking-distance
                             (getf locality :ranking-distance-mean)))
                         (return-from phase4b-attempt-specialist-composition
                           (values child parent))))))))
      (phase4b-record-specialist-composition-attempt
       (list :protocol +phase4b-specialist-composition-protocol+
             :generation *generation* :accepted nil
             :reason :no-acceptable-specialist-composition
             :issue (copy-tree issue)
             :parents-checked checked))
      (values nil nil))))

(defun finish-phase4b-specialist-composition-generation ()
  "Journal and summarize Phase-4b-B decisions, then advance its age."
  (when (phase4b-specialist-composition-active-p)
    (let* ((records
             (nreverse
              *phase4b-specialist-composition-generation-records*))
           (attempted (length records))
           (accepted
             (count-if (lambda (record) (getf record :accepted)) records))
           (references
             (count-if
              (lambda (record)
                (and (getf record :accepted)
                     (eq (getf record :source-type)
                         :live-team-reference)))
              records))
           (terminals (- accepted references)))
      (when attempted
        (emit-message
         (format nil
                 "Generation ~D Phase-4b-B specialist composition: slots=~D accepted=~D references=~D terminal-fallbacks=~D fallback=~D."
                 *generation* attempted accepted references terminals
                 (- attempted accepted)))
        (when (behavioral-locality-active-p)
          (append-behavioral-locality-form
           (list :type :phase4b-specialist-composition-generation
                 :protocol +phase4b-specialist-composition-protocol+
                 :generation *generation*
                 :age *phase4b-specialist-composition-age*
                 :attempted attempted
                 :accepted accepted
                 :reference-accepted references
                 :terminal-fallback-accepted terminals
                 :fallback (- attempted accepted)
                 :records records))))
      (incf *phase4b-specialist-composition-age*)
      (setf *phase4b-specialist-composition-generation-records* nil))))

;;; Phase 4b-C combines the two already measured operators without changing
;;; either one.  One shared ten-percent scheduler chooses a systematic issue;
;;; Case A receives bidder routing repair and Case B1 receives specialist
;;; composition.  The routing stream supplies the schedule and issue draw,
;;; while each operator retains its checkpointed internal draw stream.

(defun phase4b-combined-repair-active-p ()
  "Return true when the complete frozen Phase-4b-C contract is active."
  (and (phase4b-combined-repair-configured-p)
       (phase4b-routing-repair-active-p)
       (phase4b-specialist-composition-active-p)))

(defun phase4b-combined-repair-slot-p ()
  "Choose one shared Phase-4b-C slot using the checkpointed routing stream."
  (phase4b-routing-repair-slot-p))

(defun phase4b-combined-repair-kind (issue)
  "Map ISSUE to its frozen Phase-4b-C operator, or NIL when unsupported."
  (case (getf issue :case)
    (:case-a-routing :routing)
    (:case-b1-reachable-support :composition)
    (otherwise nil)))

(defun phase4b-record-combined-repair-attempt (record)
  "Retain one serializable Phase-4b-C dispatch decision."
  (push (copy-tree record) *phase4b-combined-repair-generation-records*)
  record)

(defun phase4b-attempt-combined-repair (parents)
  "Dispatch one systematic issue to the matching tested repair operator."
  (let ((issues (phase4b-systematic-routing-issues)))
    (unless (and issues *teacher-training-dataset*)
      (phase4b-record-combined-repair-attempt
       (list :protocol +phase4b-combined-repair-protocol+
             :generation *generation* :accepted nil
             :reason :no-systematic-issues))
      (return-from phase4b-attempt-combined-repair (values nil nil)))
    (let* ((issue (phase4b-weighted-issue issues))
           (kind (phase4b-combined-repair-kind issue)))
      (multiple-value-bind (child parent)
          (case kind
            (:routing (phase4b-attempt-routing-repair parents issue))
            (:composition
             (phase4b-attempt-specialist-composition parents issue))
            (otherwise (values nil nil)))
        (phase4b-record-combined-repair-attempt
         (list :protocol +phase4b-combined-repair-protocol+
               :generation *generation*
               :case (getf issue :case)
               :operator kind
               :accepted (not (null child))
               :issue (copy-tree issue)
               :child-team-id (and child (team-id child))
               :parent-team-id (and parent (team-id parent))))
        (values child parent)))))

(defun finish-phase4b-combined-repair-generation ()
  "Journal Phase-4b-C dispatch counts without changing operator decisions."
  (when (phase4b-combined-repair-active-p)
    (let* ((records (nreverse *phase4b-combined-repair-generation-records*))
           (attempted (length records))
           (accepted
             (count-if (lambda (record) (getf record :accepted)) records))
           (routing
             (count :routing records :key (lambda (record)
                                            (getf record :operator))))
           (composition
             (count :composition records :key (lambda (record)
                                                (getf record :operator)))))
      (when attempted
        (emit-message
         (format nil
                 "Generation ~D Phase-4b-C combined repair: slots=~D routing=~D composition=~D accepted=~D fallback=~D."
                 *generation* attempted routing composition accepted
                 (- attempted accepted)))
        (when (behavioral-locality-active-p)
          (append-behavioral-locality-form
           (list :type :phase4b-combined-repair-generation
                 :protocol +phase4b-combined-repair-protocol+
                 :generation *generation*
                 :age *phase4b-routing-repair-age*
                 :attempted attempted
                 :routing-attempted routing
                 :composition-attempted composition
                 :accepted accepted
                 :fallback (- attempted accepted)
                 :records records))))
      (setf *phase4b-combined-repair-generation-records* nil))))
