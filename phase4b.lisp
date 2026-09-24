(in-package :cl-tpg)

;;; Phase 4b-A uses systematic DAgger disagreements to propose local routing
;;; variants.  It never edits an incumbent or a shared internal team.  A root
;;; is cloned, one cloned root learner's bid program is mutated through the
;;; native program operator, and the child must pass target-group, collateral,
;;; and behavioral-locality gates before entering normal survivor selection.

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

(defun phase4b-attempt-routing-repair (parents)
  "Attempt one targeted child and return CHILD and PARENT as values."
  (let ((issues (phase4b-systematic-routing-issues)))
    (unless (and issues *teacher-training-dataset*)
      (phase4b-record-routing-attempt
       (list :protocol +phase4b-routing-repair-protocol+
             :generation *generation* :accepted nil
             :reason :no-systematic-issues))
      (return-from phase4b-attempt-routing-repair (values nil nil)))
    (let* ((issue (phase4b-weighted-issue issues))
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
