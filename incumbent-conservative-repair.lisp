(in-package :cl-tpg)

;;; Incumbent-anchored conservative repair is a controlled successor to
;;; population-parent single-predicate injection.  It creates only a new direct
;;; Semantic-36 specialist, gates it with two exact categorical conditions, and
;;; calibrates its winning bid against the frozen incumbent.  The candidate
;;; still enters ordinary grouped selection and the unchanged official paired
;;; racing/promotion protocol; the incumbent itself is never mutated.

(defun incumbent-conservative-allowed-phase-p (phase)
  "Return true for the two empirically safer repair phases."
  (member phase '(:early :steps-10-29) :test #'eq))

(defun incumbent-conservative-row-context (team dataset index)
  "Return one missing-Top-8 incumbent disagreement context, or NIL."
  (let ((steps (dataset-steps dataset)))
    (when steps
      (let ((phase (dagger-diagnostic-phase (aref steps index))))
        (when (incumbent-conservative-allowed-phase-p phase)
          (let* ((observation
                   (policy-observation (aref (observations dataset) index)))
                 (teacher
                   (semantic-label-category-pair
                    (aref (actions dataset) index)))
                 (ranking (behavioral-ranking-pairs team observation)))
            (when (and ranking
                       (null (position teacher ranking :test #'equal)))
              (list :index index
                    :phase phase
                    :observation observation
                    :teacher-pair teacher
                    :predicted-pair (first ranking)
                    :parent-ranking ranking
                    :parent-rank +semantic-ranking-limit+))))))))

(defun incumbent-conservative-issue-groups (team dataset)
  "Group systematic incumbent Top-8 omissions by phase and semantic pair."
  (let ((groups (make-hash-table :test #'equal))
        (episodes (make-hash-table :test #'equal))
        (episode-ids (dataset-episode-ids dataset)))
    (dotimes (index (dataset-size dataset))
      (let ((context
              (incumbent-conservative-row-context team dataset index)))
        (when context
          (let ((key (list (getf context :phase)
                           (getf context :teacher-pair)
                           (getf context :predicted-pair))))
            (push context (gethash key groups))
            (when episode-ids
              (pushnew (aref episode-ids index)
                       (gethash key episodes) :test #'equal))))))
    (stable-sort
     (loop for key being the hash-keys of groups
           for all-contexts = (nreverse (gethash key groups))
           for contexts = (subseq all-contexts
                                   0 (min 32 (length all-contexts)))
           for episode-count = (length (gethash key episodes))
           when (and (>= (length all-contexts)
                         +targeted-systematic-minimum-occurrences+)
                     (or (null episode-ids)
                         (>= episode-count
                             +targeted-systematic-minimum-episodes+)))
             collect
             (list :issue
                     (list :case :incumbent-top8-missing
                           :phase (first key)
                           :teacher-pair (second key)
                           :predicted-pair (third key)
                           :teacher-rank nil
                           :occurrences (length all-contexts)
                           :episode-count episode-count
                           :systematic-p t)
                   :contexts contexts
                   :target-indices
                     (mapcar (lambda (context) (getf context :index))
                             all-contexts))
           )
     #'> :key (lambda (group)
                (getf (getf group :issue) :occurrences)))))

(defun incumbent-conservative-weighted-group (groups)
  "Select one incumbent error group by deterministic occurrence weighting."
  (let ((total
          (loop for group in groups
                sum (getf (getf group :issue) :occurrences))))
    (when (plusp total)
      (let ((draw (teacher-guided-predicate-random-below total)))
        (dolist (group groups (car (last groups)))
          (let ((weight (getf (getf group :issue) :occurrences)))
            (if (< draw weight)
                (return group)
                (decf draw weight))))))))

(defun incumbent-conservative-observation-key (observation)
  "Return a stable EQUAL key for one policy observation vector."
  (coerce observation 'list))

(defun incumbent-conservative-background-observations
       (dataset issue target-contexts &optional all-target-indices)
  "Return a broad deterministic background from current on-policy rows.

Target contexts are excluded by row identity.  Current DAgger rows are used
before the small probe archive so the gate is screened against substantially
more of the current trajectory distribution."
  (let ((target-indices (make-hash-table :test #'eql))
        (candidate-seen (make-hash-table :test #'equal))
        (candidates nil))
    (if all-target-indices
        (dolist (index all-target-indices)
          (setf (gethash index target-indices) t))
        (dolist (context target-contexts)
          (setf (gethash (getf context :index) target-indices) t)))
    (dotimes (index (dataset-size dataset))
      (unless (gethash index target-indices)
        (let* ((observation
                 (policy-observation (aref (observations dataset) index)))
               (key (incumbent-conservative-observation-key observation)))
          (unless (gethash key candidate-seen)
            (setf (gethash key candidate-seen) t)
            (push observation candidates)))))
    (setf candidates (nreverse candidates))
    (let* ((count
             (min +incumbent-conservative-background-limit+
                  (length candidates)))
           (selected
             (loop for index in (behavioral-even-indices
                                 (length candidates) count)
                   collect (nth index candidates)))
           (selected-seen (make-hash-table :test #'equal)))
      (dolist (observation selected)
        (setf (gethash (incumbent-conservative-observation-key observation)
                       selected-seen)
              t))
      (dolist (probe *behavioral-probe-archive*)
        (let* ((observation (getf probe :observation))
               (key (incumbent-conservative-observation-key observation)))
          (unless (gethash key selected-seen)
            (setf (gethash key selected-seen) t)
            (push observation selected))))
      (values (nreverse selected) issue))))

(defun incumbent-conservative-atom-match-p (atom observation)
  (= (aref observation (getf atom :observation-index))
     (getf atom :value)))

(defun incumbent-conservative-atomic-predicates (contexts background)
  "Return high-precision atoms used to form bounded conjunctions."
  (let ((targets (mapcar (lambda (context)
                           (getf context :observation))
                         contexts))
        (records nil))
    (dotimes (index *num-observations*)
      (dotimes (ror-index (active-read-only-register-count))
        (let* ((value (aref (active-read-only-register-values) ror-index))
               (atom (list :observation-index index
                           :ror-index ror-index
                           :value value))
               (target-hits
                 (count-if (lambda (observation)
                             (incumbent-conservative-atom-match-p
                              atom observation))
                           targets))
               (background-hits
                 (count-if (lambda (observation)
                             (incumbent-conservative-atom-match-p
                              atom observation))
                           background)))
          (when (>= target-hits +targeted-routing-repair-minimum-rows+)
            (setf (getf atom :target-hits) target-hits
                  (getf atom :background-hits) background-hits)
            (push atom records)))))
    (subseq
     (stable-sort
      records
      (lambda (left right)
        (or (< (getf left :background-hits)
               (getf right :background-hits))
            (and (= (getf left :background-hits)
                    (getf right :background-hits))
                 (> (getf left :target-hits)
                    (getf right :target-hits))))))
     0 (min +incumbent-conservative-atomic-candidates+
            (length records)))))

(defun incumbent-conservative-conjunction-match-p
       (conjunction observation)
  (and (incumbent-conservative-atom-match-p
        (getf conjunction :left) observation)
       (incumbent-conservative-atom-match-p
        (getf conjunction :right) observation)))

(defun incumbent-conservative-conjunctions (contexts background)
  "Return precise two-atom gates, preferring no background matches."
  (let* ((targets (mapcar (lambda (context)
                            (getf context :observation))
                          contexts))
         (atoms (incumbent-conservative-atomic-predicates
                 contexts background))
         (records nil))
    (loop for tail on atoms
          for left = (first tail)
          do (dolist (right (rest tail))
               (let* ((record (list :left left :right right))
                      (target-hits
                        (count-if
                         (lambda (observation)
                           (incumbent-conservative-conjunction-match-p
                            record observation))
                         targets))
                      (background-hits
                        (count-if
                         (lambda (observation)
                           (incumbent-conservative-conjunction-match-p
                            record observation))
                         background)))
                 (when (>= target-hits
                           +targeted-routing-repair-minimum-rows+)
                   (setf (getf record :target-hits) target-hits
                         (getf record :target-count) (length targets)
                         (getf record :coverage)
                           (/ target-hits
                              (coerce (max 1 (length targets)) 'double-float))
                         (getf record :background-hits) background-hits
                         (getf record :background-count) (length background)
                         (getf record :collision-rate)
                           (/ background-hits
                              (coerce (max 1 (length background))
                                      'double-float)))
                   (push record records)))))
    (subseq
     (stable-sort
      records
      (lambda (left right)
        (or (< (getf left :background-hits)
               (getf right :background-hits))
            (and (= (getf left :background-hits)
                    (getf right :background-hits))
                 (> (getf left :target-hits)
                    (getf right :target-hits))))))
     0 (min +incumbent-conservative-max-conjunctions+
            (length records)))))

(defun incumbent-conservative-root-winning-bid (team observation)
  "Return TEAM root's current winning bid for OBSERVATION."
  (let ((winner nil)
        (buffer (make-array +num-registers+ :element-type 'double-float)))
    (dolist (learner (team-learners team) winner)
      (let ((value (bid learner observation buffer)))
        (when (or (null winner) (> value winner))
          (setf winner value))))))

(defun incumbent-conservative-gate-threshold
       (parent contexts conjunction &optional background)
  "Return a bid that wins target rows without winning matching background.

The specialist is appended after incumbent learners, so equality preserves the
incumbent.  A safe threshold therefore lies above at least one target winning
bid and at or below the minimum winning bid of every matching background row."
  (let* ((target-bids
          (loop for context in contexts
                for observation = (getf context :observation)
                when (incumbent-conservative-conjunction-match-p
                      conjunction observation)
                  collect
                  (incumbent-conservative-root-winning-bid
                   parent observation)))
         (background-bids
           (loop for observation in background
                 when (incumbent-conservative-conjunction-match-p
                       conjunction observation)
                   collect
                   (incumbent-conservative-root-winning-bid
                    parent observation)))
         (ceiling (and background-bids (reduce #'min background-bids)))
         (eligible
           (remove-if-not
            (lambda (bid)
              (and (< bid 999.0d0)
                   (or (null ceiling) (< bid ceiling))))
            target-bids)))
    (when eligible
      (let ((threshold
              (max -999.0d0
                   (min 999.0d0
                        (+ (official-guided-quantile
                            eligible +incumbent-conservative-bid-quantile+)
                           1.0d-6)))))
        (when (or (null ceiling) (<= threshold ceiling))
          threshold)))))

(defun incumbent-conservative-gate-program (conjunction threshold)
  "Return a compact AND gate with -1000 off and calibrated on bid."
  (let ((program
          (make-program
           :instructions (make-array 0 :fill-pointer 0 :adjustable t)))
        (left (getf conjunction :left))
        (right (getf conjunction :right)))
    (dolist
        (instruction
          (list
           (teacher-guided-instruction
            1 :eq :obs (getf left :observation-index)
            :ror (getf left :ror-index))
           (teacher-guided-instruction
            2 :eq :obs (getf right :observation-index)
            :ror (getf right :ror-index))
           (teacher-guided-instruction 1 :mul :reg 1 :reg 2)
           ;; Compute (AND - 1) * 1000 + AND * threshold.  Splitting the
           ;; expression avoids the per-instruction +/-1000 saturation that
           ;; would corrupt AND * (threshold + 1000) for positive thresholds.
           (teacher-guided-instruction
            +bid-register+ :add :reg 1 :const -1.0d0)
           (teacher-guided-instruction
            +bid-register+ :mul :reg +bid-register+ :const 1000.0d0)
           (teacher-guided-instruction
            1 :mul :reg 1 :const threshold)
           (teacher-guided-instruction
            +bid-register+ :add :reg +bid-register+ :reg 1)))
      (teacher-guided-append-instruction program instruction))
    program))

(defun incumbent-conservative-install-specialist
       (child teacher-pair conjunction threshold)
  "Add one direct conjunctive specialist without editing incumbent learners."
  (when (< (length (team-learners child)) *max-num-learners*)
    (let ((learner
            (make-learner
             :program
               (incumbent-conservative-gate-program conjunction threshold)
             :action
               (make-action
                :type :atomic
                :action
                  (make-target-response-36-action
                   :target (first teacher-pair)
                   :response (second teacher-pair))))))
      ;; Stable tie-breaking gives the calibrated +epsilon bid its intended win.
      ;; Keep incumbent learners first so an off-gate bid of -1000 cannot steal
      ;; states where every incumbent learner is also saturated at -1000.
      (setf (team-learners child)
            (append (team-learners child) (list learner)))
      (note-mutation-event :incumbent-conjunctive-specialist-injection)
      (list :mode :new-terminal
            :learner-index (1- (length (team-learners child)))
            :threshold threshold))))

(defun incumbent-conservative-expanded-collateral
       (parent child background)
  "Measure exact Top-1 changes on the broad current on-policy background."
  (let ((changed 0))
    (dolist (observation background)
      (unless (equal (first (behavioral-ranking-pairs parent observation))
                     (first (behavioral-ranking-pairs child observation)))
        (incf changed)))
    (list :background-count (length background)
          :top1-changed changed
          :top1-change-rate
            (/ changed (coerce (max 1 (length background)) 'double-float)))))

(defun incumbent-conservative-candidate-better-p (left right)
  "Prefer more target gains, then fewer collisions and lower disruption."
  (let ((lt (getf left :target))
        (rt (getf right :target))
        (lc (getf left :expanded-collateral))
        (rc (getf right :expanded-collateral))
        (ll (getf left :locality))
        (rl (getf right :locality)))
    (or (> (getf lt :top1-gains) (getf rt :top1-gains))
        (and (= (getf lt :top1-gains) (getf rt :top1-gains))
             (or (< (getf lc :top1-changed) (getf rc :top1-changed))
                 (and (= (getf lc :top1-changed)
                         (getf rc :top1-changed))
                      (< (+ (getf ll :top1-hamming)
                            (getf ll :ranking-distance-mean))
                         (+ (getf rl :top1-hamming)
                            (getf rl :ranking-distance-mean)))))))))

(defun incumbent-conservative-register-child
       (child parent locality issue conjunction threshold expanded-collateral)
  "Register CHILD for one evaluated selection and official nomination."
  (unless *teacher-guided-predicate-live-records*
    (setf *teacher-guided-predicate-live-records*
          (make-hash-table :test #'eq)))
  (setf (gethash child *teacher-guided-predicate-live-records*)
        (list :protocol +incumbent-conservative-repair-protocol+
              :generation-created *generation*
              :parent-team-id (team-id parent)
              :child-team-id (team-id child)
              :issue (copy-tree issue)
              :conjunction (copy-tree conjunction)
              :threshold threshold
              :target-comparison
                (copy-tree
                 (getf locality :teacher-guided-target-comparison))
              :collateral (copy-tree expanded-collateral)
              :top1-hamming (getf locality :top1-hamming)
              :ranking-distance (getf locality :ranking-distance-mean)))
  child)

(defun incumbent-conservative-attempt-repair ()
  "Create one bounded conjunctive repair of the frozen official incumbent."
  (let ((parent *best-team*)
        (dataset *teacher-training-dataset*))
    (unless (and parent dataset)
      (teacher-guided-note-attempt
       (list :protocol +incumbent-conservative-repair-protocol+
             :generation *generation* :accepted nil
             :reason :missing-incumbent-or-dataset))
      (return-from incumbent-conservative-attempt-repair
        (values nil nil)))
    (let* ((groups (incumbent-conservative-issue-groups parent dataset))
           (group (and groups
                       (incumbent-conservative-weighted-group groups))))
      (unless group
        (teacher-guided-note-attempt
         (list :protocol +incumbent-conservative-repair-protocol+
               :generation *generation* :accepted nil
               :reason :no-systematic-incumbent-top8-omission))
        (return-from incumbent-conservative-attempt-repair
          (values nil nil)))
      (let* ((issue (getf group :issue))
             (contexts (getf group :contexts)))
        (multiple-value-bind (background ignored)
            (incumbent-conservative-background-observations
             dataset issue contexts (getf group :target-indices))
          (declare (ignore ignored))
          (let ((conjunctions
                  (incumbent-conservative-conjunctions
                   contexts background))
                (best nil)
                (attempts 0)
                (rejections
                  (list :no-threshold 0 :learner-capacity 0
                        :missing-locality 0 :target-not-improved 0
                        :probe-collateral 0 :expanded-top1-collateral 0)))
            (dolist (conjunction conjunctions)
              (incf attempts)
              (let ((threshold
                      (incumbent-conservative-gate-threshold
                       parent contexts conjunction background)))
                (if (null threshold)
                    (incf (getf rejections :no-threshold))
                  (let ((child (clone-team parent))
                        (*active-mutation-events* nil))
                    (let ((installation
                            (incumbent-conservative-install-specialist
                             child (getf issue :teacher-pair)
                             conjunction threshold)))
                      (if (null installation)
                          (progn
                            (incf (getf rejections :learner-capacity))
                            (discard-semantic-locality-candidate child))
                          (let* ((events (nreverse *active-mutation-events*))
                                 (target
                                   (targeted-target-group-comparison
                                    child contexts))
                                 (locality
                                   (make-behavioral-mutation-record
                                    parent child events))
                                 (probe-collateral
                                   (targeted-collateral-comparison
                                    parent child issue))
                                 (expanded
                                   (incumbent-conservative-expanded-collateral
                                    parent child background))
                                 (candidate
                                   (list :child child :conjunction conjunction
                                         :threshold threshold
                                         :installation installation
                                         :target target :locality locality
                                         :probe-collateral probe-collateral
                                         :expanded-collateral expanded)))
                            (unless locality
                              (incf (getf rejections :missing-locality)))
                            (unless (targeted-target-comparison-improves-p
                                     target)
                              (incf (getf rejections :target-not-improved)))
                            (unless (and locality
                                         (targeted-collateral-acceptable-p
                                          probe-collateral locality))
                              (incf (getf rejections :probe-collateral)))
                            (unless (zerop (getf expanded :top1-changed))
                              (incf (getf rejections
                                          :expanded-top1-collateral)))
                            (if (and locality
                                     (targeted-target-comparison-improves-p
                                      target)
                                     (targeted-collateral-acceptable-p
                                      probe-collateral locality)
                                     (zerop (getf expanded :top1-changed)))
                                (if (or (null best)
                                        (incumbent-conservative-candidate-better-p
                                         candidate best))
                                    (progn
                                      (when best
                                        (discard-semantic-locality-candidate
                                         (getf best :child)))
                                      (setf best candidate))
                                    (discard-semantic-locality-candidate child))
                                (discard-semantic-locality-candidate child)))))))))
            (if (null best)
                (progn
                  (teacher-guided-note-attempt
                   (list :protocol +incumbent-conservative-repair-protocol+
                         :generation *generation* :accepted nil
                         :reason :no-safe-conjunctive-specialist
                         :issue (copy-tree issue)
                         :conjunction-attempts attempts
                         :background-count (length background)
                         :rejections (copy-list rejections)))
                  (values nil nil))
                (let* ((child (getf best :child))
                       (locality (getf best :locality))
                       (expanded (getf best :expanded-collateral)))
                  (setf
                   (getf locality :control-protocol)
                     +semantic-locality-control-protocol+
                   (getf locality :control-stage)
                     :incumbent-conjunctive-repair
                   (getf locality :control-age) *semantic-locality-control-age*
                   (getf locality :control-requested-tier) :targeted
                   (getf locality :control-tier) :local
                   (getf locality :control-effective-tier) :local
                   (getf locality :control-escalated-p) nil
                   (getf locality :control-attempts) attempts
                   (getf locality :control-fallback-p) nil
                   (getf locality :teacher-guided-issue) (copy-tree issue)
                   (getf locality :teacher-guided-conjunction)
                     (copy-tree (getf best :conjunction))
                   (getf locality :teacher-guided-installation)
                     (copy-tree (getf best :installation))
                   (getf locality :teacher-guided-target-comparison)
                     (copy-tree (getf best :target))
                   (getf locality :teacher-guided-collateral)
                     (copy-tree (getf best :probe-collateral))
                   (getf locality :incumbent-expanded-collateral)
                     (copy-tree expanded))
                  (register-behavioral-mutation-record parent child locality)
                  (push (copy-tree locality)
                        *semantic-locality-control-generation-records*)
                  (incumbent-conservative-register-child
                   child parent locality issue (getf best :conjunction)
                   (getf best :threshold) expanded)
                  (teacher-guided-note-attempt
                   (list :protocol +incumbent-conservative-repair-protocol+
                         :generation *generation* :accepted t
                         :issue (copy-tree issue)
                         :parent-team-id (team-id parent)
                         :child-team-id (team-id child)
                         :conjunction-attempts attempts
                         :conjunction
                           (copy-tree (getf best :conjunction))
                         :threshold (getf best :threshold)
                         :target-comparison
                           (copy-tree (getf best :target))
                         :expanded-collateral (copy-tree expanded)
                         :top1-hamming (getf locality :top1-hamming)
                         :ranking-distance
                           (getf locality :ranking-distance-mean)))
                  (values child parent)))))))))
