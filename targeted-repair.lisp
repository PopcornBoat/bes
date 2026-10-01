(in-package :cl-tpg)

;;; targeted routing repair uses systematic DAgger disagreements to propose local routing
;;; variants.  It never edits an incumbent or a shared internal team.  A root
;;; is cloned, one cloned root learner's bid program is mutated through the
;;; native program operator, and the child must pass target-group, collateral,
;;; and behavioral-locality gates before entering normal survivor selection.

(defun targeted-combined-repair-configured-p ()
  "Return true when the combined targeted repair combined treatment is configured."
  (and *targeted-combined-repair-enabled*
       *targeted-routing-repair-enabled*
       *targeted-specialist-composition-enabled*))

(defun targeted-routing-repair-active-p ()
  "Return true when targeted routing variation is safe to run."
  (and *targeted-routing-repair-enabled*
       *targeted-disagreement-audit-enabled*
       *semantic-locality-control-enabled*
       *behavioral-locality-enabled*
       (official-guided-mode-p)
       (eq *terminal-action-format* :target-response-36)))

(defun initialize-targeted-routing-repair-state (search-seed)
  "Initialize the independent counter-based targeted routing repair scheduling stream."
  (unless (integerp search-seed)
    (error "targeted routing repair requires an integer search seed, got ~S."
           search-seed))
  (setf *targeted-routing-repair-rng-root*
          (official-guided-mix64
           (+ search-seed +targeted-routing-repair-rng-salt+))
        *targeted-routing-repair-rng-cursor* 0
        *targeted-routing-repair-age* 0
        *targeted-routing-repair-generation-records* nil))

(defun targeted-routing-repair-state-copy ()
  "Return a serialization-safe copy of targeted routing repair scheduling state."
  (and *targeted-routing-repair-rng-root*
       (list :version 1
             :protocol +targeted-routing-repair-protocol+
             :root *targeted-routing-repair-rng-root*
             :cursor *targeted-routing-repair-rng-cursor*
             :age *targeted-routing-repair-age*)))

(defun targeted-routing-repair-state-valid-p (state)
  "Return true when STATE can exactly resume targeted routing repair scheduling."
  (and (listp state)
       (= (getf state :version 0) 1)
       (eq (getf state :protocol) +targeted-routing-repair-protocol+)
       (integerp (getf state :root))
       (integerp (getf state :cursor))
       (not (minusp (getf state :cursor)))
       (integerp (getf state :age))
       (not (minusp (getf state :age)))))

(defun restore-targeted-routing-repair-state (state)
  "Restore validated targeted routing repair state without touching *RANDOM-STATE*."
  (unless (targeted-routing-repair-state-valid-p state)
    (error "Invalid targeted routing repair routing-repair state: ~S" state))
  (setf *targeted-routing-repair-rng-root* (getf state :root)
        *targeted-routing-repair-rng-cursor* (getf state :cursor)
        *targeted-routing-repair-age* (getf state :age)
        *targeted-routing-repair-generation-records* nil))

(defun targeted-routing-random-below (limit)
  "Draw below LIMIT from the isolated counter-based repair stream."
  (unless (and (integerp limit) (plusp limit))
    (error "targeted routing repair random bound must be positive, got ~S." limit))
  (unless *targeted-routing-repair-rng-root*
    (error "targeted routing repair routing-repair state is not initialized."))
  (prog1
      (mod (official-guided-mix64
            (+ *targeted-routing-repair-rng-root*
               *targeted-routing-repair-rng-cursor*))
           limit)
    (incf *targeted-routing-repair-rng-cursor*)))

(defun targeted-routing-repair-slot-p ()
  "Choose whether one offspring slot receives targeted variation."
  (< (/ (coerce (targeted-routing-random-below 1000000) 'double-float)
        1000000.0d0)
     +targeted-routing-repair-quota+))

(defun targeted-systematic-routing-issues ()
  "Return current systematic Case-A/B1 issues; Case-B2 remains deferred."
  (remove-if-not
   (lambda (issue)
     (and (getf issue :systematic-p)
          (member (getf issue :case)
                  '(:case-a-routing :case-b1-reachable-support)
                  :test #'eq)))
   (getf (getf *last-dagger-diagnostics* :targeted-repair-audit)
         :systematic-issues)))

(defun targeted-weighted-issue (issues)
  "Select one issue proportional to its observed occurrence count."
  (let ((total (loop for issue in issues
                     sum (max 1 (getf issue :occurrences 1)))))
    (when (plusp total)
      (let ((draw (targeted-routing-random-below total)))
        (dolist (issue issues (car (last issues)))
          (let ((weight (max 1 (getf issue :occurrences 1))))
            (if (< draw weight)
                (return issue)
                (decf draw weight))))))))

(defun targeted-team-supports-pair-p (team pair)
  "Return true when TEAM's reachable genotype contains PAIR."
  (gethash pair (targeted-behavior-terminal-support team)))

(defun targeted-action-supports-pair-p (action pair)
  "Return true when root ACTION directly or transitively supports PAIR."
  (if (eq (action-type action) :atomic)
      (let ((payload (action-action action)))
        (and (target-response-36-action-p payload)
             (equal pair
                    (list (target-response-36-action-target payload)
                          (target-response-36-action-response payload)))))
      (targeted-team-supports-pair-p (action-action action) pair)))

(defun targeted-supporting-root-learner-indices (team pair)
  "Return root learner indices whose action path can reach PAIR."
  (loop for learner in (team-learners team)
        for index fixnum from 0
        when (targeted-action-supports-pair-p
              (learner-action learner) pair)
          collect index))

(defun targeted-row-matches-issue-p (dataset index issue)
  "Return true when DATASET row INDEX has ISSUE's phase and teacher pair."
  (let ((steps (dataset-steps dataset)))
    (and steps
         (eq (dagger-diagnostic-phase (aref steps index))
             (getf issue :phase))
         (equal (semantic-label-category-pair
                 (aref (actions dataset) index))
                (getf issue :teacher-pair)))))

(defun targeted-parent-row-contexts (parent dataset issue)
  "Collect bounded current-generation rows where PARENT reproduces ISSUE."
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
                       (:case-b1-reachable-support (null rank))))
            (push (list :observation observation
                        :teacher-pair teacher
                        :parent-ranking ranking
                        :parent-rank
                          (or rank +semantic-ranking-limit+))
                  contexts)
            (when (>= (length contexts) 32)
              (return (nreverse contexts)))))))))

(defun targeted-target-group-comparison (child contexts)
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

(defun targeted-target-comparison-improves-p (comparison)
  "Return true for a monotonic improvement on the selected error group."
  (and (>= (getf comparison :row-count 0)
           +targeted-routing-repair-minimum-rows+)
       (zerop (getf comparison :top1-losses 0))
       (or (plusp (getf comparison :top1-gains 0))
           (and (plusp (getf comparison :rank-improvements 0))
                (< (getf comparison :child-mean-rank)
                   (getf comparison :parent-mean-rank))))))

(defun targeted-probe-belongs-to-issue-p (probe issue)
  "Return true when PROBE belongs to ISSUE's teacher/phase group."
  (let ((step (getf probe :step)))
    (and (integerp step)
         (eq (dagger-diagnostic-phase step) (getf issue :phase))
         (equal (getf probe :teacher-pair)
                (getf issue :teacher-pair)))))

(defun targeted-collateral-comparison (parent child issue)
  "Measure damage outside ISSUE's group on the versioned probe archive."
  (let ((considered 0)
        (exact-losses 0)
        (rank-regressions 0))
    (loop for probe in *behavioral-probe-archive*
          for before in (behavioral-policy-signature parent)
          for after in (behavioral-policy-signature child)
          unless (targeted-probe-belongs-to-issue-p probe issue)
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

(defun targeted-collateral-acceptable-p (collateral locality-record)
  "Apply collateral and existing semantic-locality bounded-locality gates."
  (and (zerop (getf collateral :exact-losses 0))
       (<= (getf collateral :rank-regression-rate 0.0d0)
           +targeted-routing-repair-max-collateral-rank-rate+)
       (<= (getf locality-record :top1-hamming 1.0d0) 0.20d0)
       (<= (getf locality-record :ranking-distance-mean 1.0d0) 0.20d0)))

(defun targeted-record-routing-attempt (record)
  "Retain one serializable slot-level targeted routing repair decision."
  (push (copy-tree record) *targeted-routing-repair-generation-records*)
  record)

(defun targeted-try-parent-issue (parent issue contexts learner-indices)
  "Try bounded root-program variants for one PARENT/ISSUE combination."
  (let ((learner-start
          (targeted-routing-random-below (length learner-indices))))
    (loop for attempt from 1 to +targeted-routing-repair-max-attempts+
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
                                (targeted-target-group-comparison
                                 child contexts))
                              (locality
                                (make-behavioral-mutation-record
                                 parent child events))
                              (collateral
                                (targeted-collateral-comparison
                                 parent child issue)))
                         (if (and locality
                                  (targeted-target-comparison-improves-p target)
                                  (targeted-collateral-acceptable-p
                                   collateral locality))
                             (progn
                               (setf
                                (getf locality :control-protocol)
                                  +semantic-locality-control-protocol+
                                (getf locality :control-stage)
                                  :targeted-routing-repair
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
                                (getf locality :targeted-issue)
                                  (copy-tree issue)
                                (getf locality :targeted-root-learner-index)
                                  learner-index
                                (getf locality :targeted-target-comparison)
                                  target
                                (getf locality :targeted-collateral)
                                  collateral)
                               (register-behavioral-mutation-record
                                parent child locality)
                               (push (copy-tree locality)
                                     *semantic-locality-control-generation-records*)
                               (return-from targeted-try-parent-issue
                                 (values child locality attempt learner-index)))
                             (discard-semantic-locality-candidate child))))))))
    (values nil nil +targeted-routing-repair-max-attempts+ nil)))

(defun targeted-attempt-routing-repair (parents &optional selected-issue)
  "Attempt one routing child, optionally for SELECTED-ISSUE, and return CHILD/PARENT."
  (let ((issues (if selected-issue
                    (list selected-issue)
                    (targeted-systematic-routing-issues))))
    (unless (and issues *teacher-training-dataset*)
      (targeted-record-routing-attempt
       (list :protocol +targeted-routing-repair-protocol+
             :generation *generation* :accepted nil
             :reason :no-systematic-issues))
      (return-from targeted-attempt-routing-repair (values nil nil)))
    (let* ((issue (or selected-issue (targeted-weighted-issue issues)))
           (teacher-pair (getf issue :teacher-pair))
           (eligible
             (remove-if-not
              (lambda (team)
                (targeted-team-supports-pair-p team teacher-pair))
              parents)))
      (unless eligible
        (targeted-record-routing-attempt
         (list :protocol +targeted-routing-repair-protocol+
               :generation *generation* :accepted nil
               :reason :no-supporting-parent :issue (copy-tree issue)))
        (return-from targeted-attempt-routing-repair (values nil nil)))
      (let ((start (targeted-routing-random-below (length eligible)))
            (checked 0))
        (loop for offset below (min 8 (length eligible))
              for parent = (nth (mod (+ start offset) (length eligible))
                                eligible)
              for contexts =
                (targeted-parent-row-contexts
                 parent *teacher-training-dataset* issue)
              for learner-indices =
                (targeted-supporting-root-learner-indices
                 parent teacher-pair)
              do (incf checked)
                 (when (and (>= (length contexts)
                                +targeted-routing-repair-minimum-rows+)
                            learner-indices)
                   (multiple-value-bind
                         (child locality attempts learner-index)
                       (targeted-try-parent-issue
                        parent issue contexts learner-indices)
                     (when child
                       (targeted-record-routing-attempt
                        (list :protocol +targeted-routing-repair-protocol+
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
                                       :targeted-target-comparison))
                              :collateral
                                (copy-tree
                                 (getf locality :targeted-collateral))
                              :top1-hamming
                                (getf locality :top1-hamming)
                              :ranking-distance
                                (getf locality :ranking-distance-mean)))
                       (return-from targeted-attempt-routing-repair
                         (values child parent))))))
        (targeted-record-routing-attempt
         (list :protocol +targeted-routing-repair-protocol+
               :generation *generation* :accepted nil
               :reason :no-acceptable-local-repair
               :issue (copy-tree issue)
               :parents-checked checked))
        (values nil nil)))))

(defun finish-targeted-routing-repair-generation ()
  "Journal and summarize targeted routing repair decisions, then advance its age."
  (when (targeted-routing-repair-active-p)
    (let* ((records
             (nreverse *targeted-routing-repair-generation-records*))
           (attempted (length records))
           (accepted
             (count-if (lambda (record) (getf record :accepted)) records)))
      (when attempted
        (emit-message
         (format nil
                 "Generation ~D targeted routing repair routing repair: slots=~D accepted=~D fallback=~D."
                 *generation* attempted accepted (- attempted accepted)))
        (when (behavioral-locality-active-p)
          (append-behavioral-locality-form
           (list :type :targeted-routing-repair-generation
                 :protocol +targeted-routing-repair-protocol+
                 :generation *generation*
                 :age *targeted-routing-repair-age*
                 :attempted attempted
                 :accepted accepted
                 :fallback (- attempted accepted)
                 :records records))))
      (incf *targeted-routing-repair-age*)
      (setf *targeted-routing-repair-generation-records* nil))))

;;; specialist composition is a separate controlled treatment.  It consumes only
;;; systematic Case-B1 errors, where the behavior root omits the teacher pair
;;; from Top-8 even though the vocabulary exists.  A child first tries to link
;;; a current group-elite root as a reusable subgraph.  The candidate owns a
;;; new gateway learner; donor teams are never edited.  If no live donor is
;;; qualified, a direct terminal specialist is tried as a recorded fallback.
;;; Every candidate passes the same target, collateral, and locality gates as
;;; targeted routing repair before normal lexicase and official evaluation can see it.

(defun targeted-specialist-composition-active-p ()
  "Return true when specialist composition composition is safe to run alone or in 4b-C."
  (and *targeted-specialist-composition-enabled*
       (or (not *targeted-routing-repair-enabled*)
           (targeted-combined-repair-configured-p))
       *targeted-disagreement-audit-enabled*
       *grouped-selection-enabled*
       *semantic-locality-control-enabled*
       *behavioral-locality-enabled*
       (official-guided-mode-p)
       (eq *terminal-action-format* :target-response-36)))

(defun initialize-targeted-specialist-composition-state (search-seed)
  "Initialize the independent counter-based specialist composition stream."
  (unless (integerp search-seed)
    (error "specialist composition requires an integer search seed, got ~S."
           search-seed))
  (setf *targeted-specialist-composition-rng-root*
          (official-guided-mix64
           (+ search-seed +targeted-specialist-composition-rng-salt+))
        *targeted-specialist-composition-rng-cursor* 0
        *targeted-specialist-composition-age* 0
        *targeted-specialist-composition-generation-records* nil))

(defun targeted-specialist-composition-state-copy ()
  "Return a serialization-safe copy of specialist composition scheduling state."
  (and *targeted-specialist-composition-rng-root*
       (list :version 1
             :protocol +targeted-specialist-composition-protocol+
             :root *targeted-specialist-composition-rng-root*
             :cursor *targeted-specialist-composition-rng-cursor*
             :age *targeted-specialist-composition-age*)))

(defun targeted-specialist-composition-state-valid-p (state)
  "Return true when STATE can exactly resume specialist composition scheduling."
  (and (listp state)
       (= (getf state :version 0) 1)
       (eq (getf state :protocol)
           +targeted-specialist-composition-protocol+)
       (integerp (getf state :root))
       (integerp (getf state :cursor))
       (not (minusp (getf state :cursor)))
       (integerp (getf state :age))
       (not (minusp (getf state :age)))))

(defun restore-targeted-specialist-composition-state (state)
  "Restore validated specialist composition state without touching *RANDOM-STATE*."
  (unless (targeted-specialist-composition-state-valid-p state)
    (error "Invalid specialist composition specialist-composition state: ~S" state))
  (setf *targeted-specialist-composition-rng-root* (getf state :root)
        *targeted-specialist-composition-rng-cursor* (getf state :cursor)
        *targeted-specialist-composition-age* (getf state :age)
        *targeted-specialist-composition-generation-records* nil))

(defun targeted-specialist-composition-random-below (limit)
  "Draw below LIMIT from the isolated counter-based specialist composition stream."
  (unless (and (integerp limit) (plusp limit))
    (error "specialist composition random bound must be positive, got ~S." limit))
  (unless *targeted-specialist-composition-rng-root*
    (error "specialist composition specialist-composition state is not initialized."))
  (prog1
      (mod (official-guided-mix64
            (+ *targeted-specialist-composition-rng-root*
               *targeted-specialist-composition-rng-cursor*))
           limit)
    (incf *targeted-specialist-composition-rng-cursor*)))

(defun targeted-specialist-composition-slot-p ()
  "Choose whether one offspring slot receives specialist composition variation."
  (< (/ (coerce
         (targeted-specialist-composition-random-below 1000000)
         'double-float)
        1000000.0d0)
     +targeted-specialist-composition-quota+))

(defun targeted-systematic-composition-issues ()
  "Return systematic Case-B1 issues for the isolated composition pilot."
  (remove-if-not
   (lambda (issue)
     (and (getf issue :systematic-p)
          (eq (getf issue :case) :case-b1-reachable-support)))
   (getf (getf *last-dagger-diagnostics* :targeted-repair-audit)
         :systematic-issues)))

(defun targeted-weighted-composition-issue (issues)
  "Select one issue by occurrence count using the specialist composition stream."
  (let ((total (loop for issue in issues
                     sum (max 1 (getf issue :occurrences 1)))))
    (when (plusp total)
      (let ((draw (targeted-specialist-composition-random-below total)))
        (dolist (issue issues (car (last issues)))
          (let ((weight (max 1 (getf issue :occurrences 1))))
            (if (< draw weight)
                (return issue)
                (decf draw weight))))))))

(defun targeted-composition-group-key (issue)
  "Return the most specific active grouped selection group for ISSUE."
  (let* ((pair (getf issue :teacher-pair))
         (pair-key (list :teacher-pair (first pair) (second pair)))
         (phase-key (list :phase (getf issue :phase))))
    (cond
      ((find pair-key *grouped-case-groups*
             :key (lambda (group) (getf group :key)) :test #'equal)
       pair-key)
      ((find phase-key *grouped-case-groups*
             :key (lambda (group) (getf group :key)) :test #'equal)
       phase-key)
      (t nil))))

(defun targeted-group-score-if-present (team key)
  "Return TEAM's current-generation group score and presence flag."
  (let ((table (and *grouped-team-group-scores*
                    (gethash team *grouped-team-group-scores*))))
    (if (and table key)
        (gethash key table)
        (values nil nil))))

(defun targeted-group-qualified-donors (parents parent issue)
  "Return a bounded, stream-rotated set of live group-elite donor roots."
  (let* ((key (targeted-composition-group-key issue))
         (scored
           (loop
             for team in parents
             unless (eq team parent)
               append
               (multiple-value-bind (score present-p)
                   (targeted-group-score-if-present team key)
                 (when (and present-p
                            (not (creates-cycle-p parent team)))
                   (list (cons team score)))))))
    (unless scored
      (return-from targeted-group-qualified-donors (values nil key)))
    (let* ((best (reduce #'max scored :key #'cdr))
           (epsilon (gethash key *grouped-group-epsilons* 0.0d0))
           (elite
             (remove-if
              (lambda (entry)
                (< (cdr entry)
                   (- best epsilon
                      +grouped-selection-numerical-tolerance+)))
              scored))
           (start
             (targeted-specialist-composition-random-below (length elite))))
      (values
       (loop for offset below
               (min +targeted-specialist-composition-max-donors+
                    (length elite))
             collect (nth (mod (+ start offset) (length elite)) elite))
       key))))

(defun targeted-root-winning-learner (team observation)
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

(defun targeted-assess-specialist-donor (entry contexts teacher-pair group-key)
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
          (let ((gateway (targeted-root-winning-learner team observation)))
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

(defun targeted-better-donor-p (left right)
  "Order donor assessments by exact coverage, rank, then group score."
  (or (> (getf left :exact-wins) (getf right :exact-wins))
      (and (= (getf left :exact-wins) (getf right :exact-wins))
           (or (< (getf left :mean-teacher-rank)
                  (getf right :mean-teacher-rank))
               (and (= (getf left :mean-teacher-rank)
                       (getf right :mean-teacher-rank))
                    (> (getf left :group-score)
                       (getf right :group-score)))))))

(defun targeted-select-specialist-source (parents parent issue contexts)
  "Prefer the best bounded live donor; otherwise build a direct fallback."
  (multiple-value-bind (entries group-key)
      (targeted-group-qualified-donors parents parent issue)
    (let ((assessments
            (remove nil
                    (mapcar
                     (lambda (entry)
                       (targeted-assess-specialist-donor
                        entry contexts (getf issue :teacher-pair) group-key))
                     entries))))
      (if assessments
          (first (stable-sort assessments #'targeted-better-donor-p))
          (let* ((observation (getf (first contexts) :observation))
                 (gateway (targeted-root-winning-learner parent observation)))
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

(defun targeted-add-specialist-learner (child source teacher-pair attempt)
  "Add a donor reference or direct semantic terminal to CHILD."
  (when (>= (length (team-learners child)) *max-num-learners*)
    (return-from targeted-add-specialist-learner nil))
  (let* ((gateway (getf source :gateway))
         (source-type (getf source :source-type))
         (program (clone-program (learner-program gateway)))
         (action
           (ecase source-type
             (:live-team-reference
              (let ((donor (getf source :team)))
                (when (creates-cycle-p child donor)
                  (return-from targeted-add-specialist-learner nil))
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

(defun targeted-try-specialist-source
       (parent issue contexts source)
  "Try bounded gateway variants for one PARENT/ISSUE/SOURCE triple."
  (loop for attempt from 1 to +targeted-specialist-composition-max-attempts+
        for child = (clone-team parent)
        do (let ((*active-mutation-events* nil))
             (if (null
                  (targeted-add-specialist-learner
                   child source (getf issue :teacher-pair) attempt))
                 (discard-semantic-locality-candidate child)
                 (let* ((events (nreverse *active-mutation-events*))
                        (target
                          (targeted-target-group-comparison child contexts))
                        (locality
                          (make-behavioral-mutation-record
                           parent child events))
                        (collateral
                          (targeted-collateral-comparison parent child issue)))
                   (if (and locality
                            (targeted-target-comparison-improves-p target)
                            (targeted-collateral-acceptable-p
                             collateral locality))
                       (progn
                         (setf
                          (getf locality :control-protocol)
                            +semantic-locality-control-protocol+
                          (getf locality :control-stage)
                            :targeted-specialist-composition
                          (getf locality :control-age)
                            *semantic-locality-control-age*
                          (getf locality :control-requested-tier) :targeted
                          (getf locality :control-tier) :bounded
                          (getf locality :control-effective-tier) :bounded
                          (getf locality :control-escalated-p) nil
                          (getf locality :control-attempts) attempt
                          (getf locality :control-fallback-p) nil
                          (getf locality :targeted-issue) (copy-tree issue)
                          (getf locality :targeted-composition-source)
                            (copy-tree
                             (loop for (key value) on source by #'cddr
                                   unless (member key '(:team :gateway)
                                                  :test #'eq)
                                     append (list key value)))
                          (getf locality :targeted-target-comparison) target
                          (getf locality :targeted-collateral) collateral)
                         (register-behavioral-mutation-record
                          parent child locality)
                         (push (copy-tree locality)
                               *semantic-locality-control-generation-records*)
                         (return-from targeted-try-specialist-source
                           (values child locality attempt)))
                       (discard-semantic-locality-candidate child)))))
        finally
           (return (values nil nil
                           +targeted-specialist-composition-max-attempts+))))

(defun targeted-record-specialist-composition-attempt (record)
  "Retain one serializable slot-level specialist composition decision."
  (push (copy-tree record)
        *targeted-specialist-composition-generation-records*)
  record)

(defun targeted-attempt-specialist-composition (parents &optional selected-issue)
  "Attempt one Case-B1 child, optionally for SELECTED-ISSUE, and return CHILD/PARENT."
  (let ((issues (if selected-issue
                    (list selected-issue)
                    (targeted-systematic-composition-issues))))
    (unless (and issues *teacher-training-dataset*)
      (targeted-record-specialist-composition-attempt
       (list :protocol +targeted-specialist-composition-protocol+
             :generation *generation* :accepted nil
             :reason :no-systematic-case-b1))
      (return-from targeted-attempt-specialist-composition
        (values nil nil)))
    (let* ((issue (or selected-issue
                      (targeted-weighted-composition-issue issues)))
           (start
             (targeted-specialist-composition-random-below (length parents)))
           (checked 0))
      (loop for offset below
              (min +targeted-specialist-composition-max-parents+
                   (length parents))
            for parent = (nth (mod (+ start offset) (length parents)) parents)
            for contexts =
              (targeted-parent-row-contexts
               parent *teacher-training-dataset* issue)
            do (incf checked)
               (when (>= (length contexts)
                         +targeted-routing-repair-minimum-rows+)
                 (let ((source
                         (targeted-select-specialist-source
                          parents parent issue contexts)))
                   (when source
                     (multiple-value-bind (child locality attempts)
                         (targeted-try-specialist-source
                          parent issue contexts source)
                       (when child
                         (targeted-record-specialist-composition-attempt
                          (list
                           :protocol
                             +targeted-specialist-composition-protocol+
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
                                    :targeted-target-comparison))
                           :collateral
                             (copy-tree
                              (getf locality :targeted-collateral))
                           :top1-hamming
                             (getf locality :top1-hamming)
                           :ranking-distance
                             (getf locality :ranking-distance-mean)))
                         (return-from targeted-attempt-specialist-composition
                           (values child parent))))))))
      (targeted-record-specialist-composition-attempt
       (list :protocol +targeted-specialist-composition-protocol+
             :generation *generation* :accepted nil
             :reason :no-acceptable-specialist-composition
             :issue (copy-tree issue)
             :parents-checked checked))
      (values nil nil))))

(defun finish-targeted-specialist-composition-generation ()
  "Journal and summarize specialist composition decisions, then advance its age."
  (when (targeted-specialist-composition-active-p)
    (let* ((records
             (nreverse
              *targeted-specialist-composition-generation-records*))
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
                 "Generation ~D specialist composition specialist composition: slots=~D accepted=~D references=~D terminal-fallbacks=~D fallback=~D."
                 *generation* attempted accepted references terminals
                 (- attempted accepted)))
        (when (behavioral-locality-active-p)
          (append-behavioral-locality-form
           (list :type :targeted-specialist-composition-generation
                 :protocol +targeted-specialist-composition-protocol+
                 :generation *generation*
                 :age *targeted-specialist-composition-age*
                 :attempted attempted
                 :accepted accepted
                 :reference-accepted references
                 :terminal-fallback-accepted terminals
                 :fallback (- attempted accepted)
                 :records records))))
      (incf *targeted-specialist-composition-age*)
      (setf *targeted-specialist-composition-generation-records* nil))))

;;; combined targeted repair combines the two already measured operators without changing
;;; either one.  One shared ten-percent scheduler chooses a systematic issue;
;;; Case A receives bidder routing repair and Case B1 receives specialist
;;; composition.  The routing stream supplies the schedule and issue draw,
;;; while each operator retains its checkpointed internal draw stream.

(defun targeted-combined-repair-active-p ()
  "Return true when the complete frozen combined targeted repair contract is active."
  (and (targeted-combined-repair-configured-p)
       (targeted-routing-repair-active-p)
       (targeted-specialist-composition-active-p)))

(defun targeted-combined-repair-slot-p ()
  "Choose one shared combined targeted repair slot using the checkpointed routing stream."
  (targeted-routing-repair-slot-p))

(defun targeted-combined-repair-kind (issue)
  "Map ISSUE to its frozen combined targeted repair operator, or NIL when unsupported."
  (case (getf issue :case)
    (:case-a-routing :routing)
    (:case-b1-reachable-support :composition)
    (otherwise nil)))

(defun targeted-record-combined-repair-attempt (record)
  "Retain one serializable combined targeted repair dispatch decision."
  (push (copy-tree record) *targeted-combined-repair-generation-records*)
  record)

(defun targeted-attempt-combined-repair (parents)
  "Dispatch one systematic issue to the matching tested repair operator."
  (let ((issues (targeted-systematic-routing-issues)))
    (unless (and issues *teacher-training-dataset*)
      (targeted-record-combined-repair-attempt
       (list :protocol +targeted-combined-repair-protocol+
             :generation *generation* :accepted nil
             :reason :no-systematic-issues))
      (return-from targeted-attempt-combined-repair (values nil nil)))
    (let* ((issue (targeted-weighted-issue issues))
           (kind (targeted-combined-repair-kind issue)))
      (multiple-value-bind (child parent)
          (case kind
            (:routing (targeted-attempt-routing-repair parents issue))
            (:composition
             (targeted-attempt-specialist-composition parents issue))
            (otherwise (values nil nil)))
        (targeted-record-combined-repair-attempt
         (list :protocol +targeted-combined-repair-protocol+
               :generation *generation*
               :case (getf issue :case)
               :operator kind
               :accepted (not (null child))
               :issue (copy-tree issue)
               :child-team-id (and child (team-id child))
               :parent-team-id (and parent (team-id parent))))
        (values child parent)))))

(defun finish-targeted-combined-repair-generation ()
  "Journal combined targeted repair dispatch counts without changing operator decisions."
  (when (targeted-combined-repair-active-p)
    (let* ((records (nreverse *targeted-combined-repair-generation-records*))
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
                 "Generation ~D combined targeted repair combined repair: slots=~D routing=~D composition=~D accepted=~D fallback=~D."
                 *generation* attempted routing composition accepted
                 (- attempted accepted)))
        (when (behavioral-locality-active-p)
          (append-behavioral-locality-form
           (list :type :targeted-combined-repair-generation
                 :protocol +targeted-combined-repair-protocol+
                 :generation *generation*
                 :age *targeted-routing-repair-age*
                 :attempted attempted
                 :routing-attempted routing
                 :composition-attempted composition
                 :accepted accepted
                 :fallback (- attempted accepted)
                 :records records))))
      (setf *targeted-combined-repair-generation-records* nil))))
