(in-package :cl-tpg)

;;; Coordinated repair addresses a composition failure left by the earlier
;;; single-issue operators.  It observes which teacher Top-k categories are
;;; repeatedly absent together, then adds several independently gated terminal
;;; learners to one child.  The teacher never participates at deployment: a
;;; surviving bundle is an ordinary serializable TPG genotype.

(defun coordinated-repair-bundle-active-p ()
  "Return true only under the complete coordinated-repair contract."
  (and *coordinated-repair-bundles-enabled*
       *targeted-disagreement-audit-enabled*
       *grouped-selection-enabled*
       *semantic-locality-control-enabled*
       *behavioral-locality-enabled*
       (official-guided-mode-p)
       (eq *terminal-action-format* :target-response-36)
       (eq *instruction-mutation-mode* :field-local)
       (member :eq (active-instruction-opcodes) :test #'eq)
       (plusp (active-read-only-register-count))))

(defun initialize-coordinated-repair-bundle-state (search-seed)
  "Initialize the independent counter-based bundle scheduling stream."
  (unless (integerp search-seed)
    (error "Coordinated repair requires an integer search seed, got ~S."
           search-seed))
  (setf *coordinated-repair-bundle-rng-root*
          (official-guided-mix64
           (+ search-seed +coordinated-repair-bundle-rng-salt+))
        *coordinated-repair-bundle-rng-cursor* 0
        *coordinated-repair-bundle-age* 0
        *coordinated-repair-bundle-generation-records* nil))

(defun coordinated-repair-bundle-state-copy ()
  "Return a serialization-safe copy of coordinated scheduling state."
  (and *coordinated-repair-bundle-rng-root*
       (list :version 1
             :protocol +coordinated-repair-bundle-protocol+
             :root *coordinated-repair-bundle-rng-root*
             :cursor *coordinated-repair-bundle-rng-cursor*
             :age *coordinated-repair-bundle-age*)))

(defun coordinated-repair-bundle-state-valid-p (state)
  "Return true when STATE can resume coordinated scheduling exactly."
  (and (listp state)
       (= (getf state :version 0) 1)
       (eq (getf state :protocol) +coordinated-repair-bundle-protocol+)
       (integerp (getf state :root))
       (integerp (getf state :cursor))
       (not (minusp (getf state :cursor)))
       (integerp (getf state :age))
       (not (minusp (getf state :age)))))

(defun restore-coordinated-repair-bundle-state (state)
  "Restore validated coordinated scheduling state."
  (unless (coordinated-repair-bundle-state-valid-p state)
    (error "Invalid coordinated-repair state: ~S" state))
  (setf *coordinated-repair-bundle-rng-root* (getf state :root)
        *coordinated-repair-bundle-rng-cursor* (getf state :cursor)
        *coordinated-repair-bundle-age* (getf state :age)
        *coordinated-repair-bundle-generation-records* nil))

(defun coordinated-repair-random-below (limit)
  "Draw below LIMIT without consuming the ordinary mutation RNG."
  (unless (and (integerp limit) (plusp limit))
    (error "Coordinated-repair random bound must be positive, got ~S." limit))
  (unless *coordinated-repair-bundle-rng-root*
    (error "Coordinated-repair scheduling state is not initialized."))
  (prog1
      (mod (official-guided-mix64
            (+ *coordinated-repair-bundle-rng-root*
               *coordinated-repair-bundle-rng-cursor*))
           limit)
    (incf *coordinated-repair-bundle-rng-cursor*)))

(defun coordinated-repair-bundle-slot-p ()
  "Choose at most one coordinated child per generation.

Bundle synthesis is deterministic and substantially more expensive than native
mutation.  The guard prevents identical children and repeated full-dataset
planning while retaining the per-slot probability contract."
  (and (not *coordinated-repair-bundle-attempted-this-generation*)
       (< (/ (coerce (coordinated-repair-random-below 1000000) 'double-float)
             1000000.0d0)
          +coordinated-repair-bundle-quota+)
       (setf *coordinated-repair-bundle-attempted-this-generation* t)))

(defun coordinated-repair-stat-priority (record)
  "Return a rank-sensitive persistence score for one missing category."
  (/ (coerce (getf record :occurrences) 'double-float)
     (max 1.0d0 (getf record :mean-teacher-rank))))

(defun coordinated-repair-update-stat
       (table key index episode-id teacher-rank)
  "Update one missing-category statistic in TABLE."
  (let ((record (or (gethash key table)
                    (list :occurrences 0 :rank-sum 0.0d0
                          :indices nil :episodes nil))))
    (incf (getf record :occurrences))
    (incf (getf record :rank-sum) teacher-rank)
    (push index (getf record :indices))
    (pushnew episode-id (getf record :episodes) :test #'equal)
    (setf (gethash key table) record)))

(defun coordinated-repair-parent-plan (parent dataset)
  "Find a persistent phase-local set of teacher categories missing together."
  (let ((stats (make-hash-table :test #'equal))
        (cooccurrence (make-hash-table :test #'equal))
        (steps (dataset-steps dataset))
        (episode-ids (dataset-episode-ids dataset)))
    (dotimes (index (dataset-size dataset))
      (let* ((phase
               (dagger-diagnostic-phase
                (if steps (aref steps index) index)))
             (teacher-ranking
               (aref (dataset-semantic-rankings dataset) index))
             (observation
               (policy-observation (aref (observations dataset) index)))
             (student-ranking (behavioral-ranking-pairs parent observation))
             (missing
               (targeted-missing-ranking-entries
                teacher-ranking student-ranking))
             (episode-id (and episode-ids (aref episode-ids index))))
        (dolist (entry missing)
          (coordinated-repair-update-stat
           stats (list phase (getf entry :pair)) index episode-id
           (getf entry :teacher-rank)))
        (dolist (left missing)
          (dolist (right missing)
            (unless (equal (getf left :pair) (getf right :pair))
              (incf (gethash
                     (list phase (getf left :pair) (getf right :pair))
                     cooccurrence 0)))))))
    (let ((records
            (loop for key being the hash-keys of stats
                  for value = (gethash key stats)
                  for occurrences = (getf value :occurrences)
                  for episodes = (remove nil (getf value :episodes))
                  when (and (>= occurrences
                                +targeted-systematic-minimum-occurrences+)
                            (or (null episode-ids)
                                (>= (length episodes)
                                    +targeted-systematic-minimum-episodes+)))
                    collect
                    (list :phase (first key)
                          :pair (copy-list (second key))
                          :occurrences occurrences
                          :episode-count (length episodes)
                          :mean-teacher-rank
                            (/ (getf value :rank-sum)
                               (coerce occurrences 'double-float))
                          :indices (nreverse (getf value :indices))))))
      (setf records
            (stable-sort records #'> :key #'coordinated-repair-stat-priority))
      (loop with best = nil
            for anchor in records
            for partners =
              (stable-sort
               (remove-if-not
                (lambda (candidate)
                  (and (eq (getf candidate :phase) (getf anchor :phase))
                       (not (equal (getf candidate :pair)
                                   (getf anchor :pair)))
                       (>= (gethash
                            (list (getf anchor :phase)
                                  (getf anchor :pair)
                                  (getf candidate :pair))
                            cooccurrence 0)
                           +targeted-systematic-minimum-occurrences+)))
                records)
               (lambda (left right)
                 (let ((left-count
                         (gethash
                          (list (getf anchor :phase)
                                (getf anchor :pair) (getf left :pair))
                          cooccurrence 0))
                       (right-count
                         (gethash
                          (list (getf anchor :phase)
                                (getf anchor :pair) (getf right :pair))
                          cooccurrence 0)))
                   (if (= left-count right-count)
                       (> (coordinated-repair-stat-priority left)
                          (coordinated-repair-stat-priority right))
                       (> left-count right-count)))))
            when partners
              do (let* ((members
                          (cons anchor
                                (subseq partners 0
                                        (min (1-
                                              +coordinated-repair-bundle-max-members+)
                                             (length partners)))))
                        (score
                          (reduce #'+ members
                                  :key #'coordinated-repair-stat-priority)))
                   (when (or (null best) (> score (getf best :score)))
                     (setf best
                           (list :phase (getf anchor :phase)
                                 :score score
                                 :members members
                                 :row-indices
                                   (remove-duplicates
                                    (mapcan
                                     (lambda (member)
                                       (copy-list (getf member :indices)))
                                     members)
                                    :test #'eql)))))
            finally (return best)))))

(defun coordinated-repair-contexts (parent dataset member)
  "Return cached parent-ranking contexts for one planned bundle member."
  (loop for index in (getf member :indices)
        for observation =
          (policy-observation (aref (observations dataset) index))
        for ranking = (behavioral-ranking-pairs parent observation)
        collect (list :index index
                      :observation observation
                      :teacher-pair (copy-list (getf member :pair))
                      :parent-ranking ranking
                      :parent-rank
                        (or (position (getf member :pair) ranking
                                      :test #'equal)
                            +semantic-ranking-limit+))))

(defun coordinated-repair-background-observations (dataset target-indices)
  "Return a deterministic bounded background outside TARGET-INDICES."
  (let ((targets (make-hash-table :test #'eql))
        (seen (make-hash-table :test #'equal))
        (candidates nil))
    (dolist (index target-indices)
      (setf (gethash index targets) t))
    (dotimes (index (dataset-size dataset))
      (unless (gethash index targets)
        (let* ((observation
                 (policy-observation (aref (observations dataset) index)))
               (key (coerce observation 'list)))
          (unless (gethash key seen)
            (setf (gethash key seen) t)
            (push observation candidates)))))
    (setf candidates (nreverse candidates))
    (loop for index in
            (behavioral-even-indices
             (length candidates)
             (min +coordinated-repair-bundle-background-limit+
                  (length candidates)))
          collect (nth index candidates))))

(defun coordinated-repair-threshold-candidates
       (team contexts desired-rank conjunction)
  "Derive robust bid bands from TEAM's actual target-row bid distribution."
  (let ((values nil))
    (dolist (context contexts)
      (let ((observation (getf context :observation)))
        (when (incumbent-conservative-conjunction-match-p
               conjunction observation)
          (let* ((bids
                   (stable-sort
                    (mapcar
                     (lambda (learner)
                       (bid learner observation
                            (make-array +num-registers+
                                        :element-type 'double-float)))
                     (team-learners team))
                    #'>))
                 (position
                   (min (max 0 (1- (round desired-rank)))
                        (length bids)))
                 (upper (and (plusp position)
                             (nth (1- position) bids)))
                 (lower (and (< position (length bids))
                             (nth position bids))))
            (push (cond
                    ((zerop position) (+ (first bids) 1.0d-6))
                    (lower (/ (+ upper lower) 2.0d0))
                    (t (- upper 1.0d-6)))
                  values)))))
    (when values
      (remove-duplicates
       (mapcar
        (lambda (probability)
          (max -999.0d0
               (min 999.0d0
                    (official-guided-quantile values probability))))
        '(0.0d0 0.25d0 0.5d0 0.75d0 1.0d0))
       :test #'=))))

(defun coordinated-repair-install-specialist
       (child pair conjunction threshold)
  "Append one gated direct terminal to CHILD."
  (when (< (length (team-learners child)) *max-num-learners*)
    (setf (team-learners child)
          (append
           (team-learners child)
           (list
            (make-learner
             :program
               (incumbent-conservative-gate-program conjunction threshold)
             :action
               (make-action
                :type :atomic
                :action
                  (make-target-response-36-action
                   :target (first pair) :response (second pair)))))))
    (note-mutation-event :coordinated-specialist-injection)
    t))

(defun coordinated-repair-pair-score (team dataset member)
  "Return reciprocal-rank and missing counts for MEMBER on its rows."
  (let ((score 0.0d0)
        (missing 0)
        (pair (getf member :pair)))
    (dolist (index (getf member :indices))
      (let* ((observation
               (policy-observation (aref (observations dataset) index)))
             (ranking (behavioral-ranking-pairs team observation))
             (rank (position pair ranking :test #'equal)))
        (if rank
            (incf score (/ 1.0d0 (1+ rank)))
            (incf missing))))
    (list :reciprocal-rank-sum score :missing missing)))

(defun coordinated-repair-better-member-candidate-p (left right)
  "Order one-member additions by rank gain, then lower collateral."
  (or (> (getf left :gain) (getf right :gain))
      (and (= (getf left :gain) (getf right :gain))
           (or (< (getf left :background-changes)
                  (getf right :background-changes))
               (and (= (getf left :background-changes)
                       (getf right :background-changes))
                    (< (abs (getf left :threshold))
                       (abs (getf right :threshold))))))))

(defun coordinated-repair-background-top1-changes
       (parent child observations)
  "Count raw semantic Top-1 changes on OBSERVATIONS."
  (count-if
   (lambda (observation)
     (not (equal (first (behavioral-ranking-pairs parent observation))
                 (first (behavioral-ranking-pairs child observation)))))
   observations))

(defun coordinated-repair-add-member
       (working parent dataset member background)
  "Return WORKING plus the best safe specialist for MEMBER, if any."
  (let* ((contexts (coordinated-repair-contexts working dataset member))
         (all-conjunctions
           (incumbent-conservative-conjunctions contexts background))
         (conjunctions
           (subseq all-conjunctions 0
                   (min +coordinated-repair-bundle-max-conjunctions+
                        (length all-conjunctions))))
         (before (coordinated-repair-pair-score working dataset member))
         (best nil))
    (dolist (conjunction conjunctions)
      (dolist (threshold
                (coordinated-repair-threshold-candidates
                 working contexts (getf member :mean-teacher-rank)
                 conjunction))
        (let ((candidate (clone-team working))
              (*active-mutation-events* nil))
          (if (not (coordinated-repair-install-specialist
                    candidate (getf member :pair) conjunction threshold))
              (discard-semantic-locality-candidate candidate)
              (let* ((after
                       (coordinated-repair-pair-score
                        candidate dataset member))
                     (gain
                       (- (getf after :reciprocal-rank-sum)
                          (getf before :reciprocal-rank-sum)))
                     (changes
                       (coordinated-repair-background-top1-changes
                        parent candidate background))
                     (record
                       (list :child candidate :gain gain
                             :missing-before (getf before :missing)
                             :missing-after (getf after :missing)
                             :background-changes changes
                             :conjunction conjunction
                             :threshold threshold)))
                (if (and (> gain 0.0d0) (zerop changes))
                    (if (or (null best)
                            (coordinated-repair-better-member-candidate-p
                             record best))
                        (progn
                          (when best
                            (discard-semantic-locality-candidate
                             (getf best :child)))
                          (setf best record))
                        (discard-semantic-locality-candidate candidate))
                    (discard-semantic-locality-candidate candidate)))))))
    best))

(defun coordinated-repair-target-summary (team dataset plan)
  "Return NDCG/exact/missing totals over PLAN's union of target rows."
  (let ((ndcg 0.0d0) (exact 0) (missing 0)
        (option-orders (effective-team-option-orders team)))
    (dolist (index (getf plan :row-indices))
      (let* ((teacher-ranking
               (aref (dataset-semantic-rankings dataset) index))
             (observation
               (policy-observation (aref (observations dataset) index)))
             (predictions
               (execute-team-semantic-ranked team observation))
             (pairs (mapcar #'semantic-action-category-pair predictions))
             (resolved
               (resolve-semantic-ranking
                predictions (aref (dataset-decoy-masks dataset) index)
                option-orders))
             (expected
               (semantic-label-category-pair
                (aref (actions dataset) index))))
        (incf ndcg (semantic-ranking-ndcg predictions teacher-ranking))
        (when (equal resolved expected) (incf exact))
        (dolist (member (getf plan :members))
          (when (and (member (getf member :pair) teacher-ranking :test #'equal)
                     (not (member (getf member :pair) pairs :test #'equal)))
            (incf missing)))))
    (list :rows (length (getf plan :row-indices))
          :ndcg-sum ndcg :exact exact :missing missing)))

(defun coordinated-repair-summary-improves-p (before after)
  "Return true when a bundle improves ranking/support without exact loss."
  (and (> (getf after :ndcg-sum) (getf before :ndcg-sum))
       (< (getf after :missing) (getf before :missing))
       (>= (getf after :exact) (getf before :exact))))

(defun coordinated-repair-build-child (parent dataset plan)
  "Build and screen one coordinated multi-specialist child."
  (let* ((background
           (coordinated-repair-background-observations
            dataset (getf plan :row-indices)))
         (working (clone-team parent))
         (installations nil)
         (events nil))
    (dolist (member (getf plan :members))
      (let ((candidate
              (coordinated-repair-add-member
               working parent dataset member background)))
        (when candidate
          (let ((next (getf candidate :child)))
            (unless (eq working parent)
              (discard-semantic-locality-candidate working))
            (setf working next)
            (push :coordinated-specialist-injection events)
            (push
             (list :pair (copy-list (getf member :pair))
                   :occurrences (getf member :occurrences)
                   :mean-teacher-rank (getf member :mean-teacher-rank)
                   :gain (getf candidate :gain)
                   :missing-before (getf candidate :missing-before)
                   :missing-after (getf candidate :missing-after)
                   :threshold (getf candidate :threshold)
                   :conjunction (copy-tree (getf candidate :conjunction)))
             installations)))))
    (when (< (length installations) +coordinated-repair-bundle-min-members+)
      (discard-semantic-locality-candidate working)
      (return-from coordinated-repair-build-child
        (values nil nil (nreverse installations))))
    (let* ((before (coordinated-repair-target-summary parent dataset plan))
           (after (coordinated-repair-target-summary working dataset plan))
           (locality
             (make-behavioral-mutation-record parent working (nreverse events)))
           (background-changes
             (coordinated-repair-background-top1-changes
              parent working background)))
      (if (and locality
               (coordinated-repair-summary-improves-p before after)
               (zerop background-changes)
               (<= (getf locality :top1-hamming 1.0d0) 0.20d0))
          (progn
            ;; Multi-action composition may intentionally exceed the old raw
            ;; ranking-distance bound.  Resolved behavior and exact collateral
            ;; remain protected above, and ordinary selection/promotion still
            ;; decides whether this child survives.
            (setf
             (getf locality :control-protocol)
               +semantic-locality-control-protocol+
             (getf locality :control-stage) :coordinated-repair-bundle
             (getf locality :control-age) *semantic-locality-control-age*
             (getf locality :control-requested-tier) :targeted
             (getf locality :control-tier) :composition
             (getf locality :control-effective-tier) :composition
             (getf locality :control-escalated-p) nil
             (getf locality :control-fallback-p) nil
             (getf locality :composition-locality-override) t
             (getf locality :coordinated-repair-plan) (copy-tree plan)
             (getf locality :coordinated-repair-installations)
               (nreverse installations)
             (getf locality :coordinated-repair-before) before
             (getf locality :coordinated-repair-after) after
             (getf locality :coordinated-repair-background-count)
               (length background)
             (getf locality :coordinated-repair-background-top1-changes)
               background-changes)
            (register-behavioral-mutation-record parent working locality)
            (push (copy-tree locality)
                  *semantic-locality-control-generation-records*)
            (values working locality
                    (getf locality :coordinated-repair-installations)))
          (progn
            (discard-semantic-locality-candidate working)
            (values nil nil (nreverse installations)))))))

(defun coordinated-repair-note-attempt (record)
  "Retain one serializable coordinated-repair decision."
  (push (copy-tree record) *coordinated-repair-bundle-generation-records*)
  record)

(defun coordinated-repair-attempt-bundle ()
  "Attempt one bundle rooted at the protected official incumbent."
  (let ((parent *best-team*)
        (dataset *teacher-training-dataset*))
    (unless (and parent dataset)
      (coordinated-repair-note-attempt
       (list :protocol +coordinated-repair-bundle-protocol+
             :generation *generation* :accepted nil
             :reason :missing-incumbent-or-dataset))
      (return-from coordinated-repair-attempt-bundle (values nil nil)))
    (let ((plan (coordinated-repair-parent-plan parent dataset)))
      (unless (and plan
                   (>= (length (getf plan :members))
                       +coordinated-repair-bundle-min-members+))
        (coordinated-repair-note-attempt
         (list :protocol +coordinated-repair-bundle-protocol+
               :generation *generation* :accepted nil
               :reason :no-persistent-co-missing-bundle))
        (return-from coordinated-repair-attempt-bundle (values nil nil)))
      (multiple-value-bind (child locality installations)
          (coordinated-repair-build-child parent dataset plan)
        (coordinated-repair-note-attempt
         (list :protocol +coordinated-repair-bundle-protocol+
               :generation *generation*
               :accepted (not (null child))
               :reason (and (null child) :no-safe-coordinated-child)
               :parent-team-id (team-id parent)
               :child-team-id (and child (team-id child))
               :phase (getf plan :phase)
               :planned-members
                 (mapcar (lambda (member)
                           (list :pair (copy-list (getf member :pair))
                                 :occurrences (getf member :occurrences)
                                 :mean-teacher-rank
                                   (getf member :mean-teacher-rank)))
                         (getf plan :members))
               :installations (copy-tree installations)
               :before (and locality
                            (copy-tree
                             (getf locality :coordinated-repair-before)))
               :after (and locality
                           (copy-tree
                            (getf locality :coordinated-repair-after)))
               :top1-hamming (and locality (getf locality :top1-hamming))
               :ranking-distance
                 (and locality (getf locality :ranking-distance-mean))))
        (values child (and child parent))))))

(defun finish-coordinated-repair-bundle-generation ()
  "Journal coordinated bundle outcomes and advance their scheduler age."
  (when (coordinated-repair-bundle-active-p)
    (let* ((records
             (nreverse *coordinated-repair-bundle-generation-records*))
           (attempted (length records))
           (accepted
             (count-if (lambda (record) (getf record :accepted)) records)))
      (when attempted
        (emit-message
         (format nil
                 "Generation ~D coordinated repair bundles: slots=~D accepted=~D fallback=~D."
                 *generation* attempted accepted (- attempted accepted)))
        (when (behavioral-locality-active-p)
          (append-behavioral-locality-form
           (list :type :coordinated-repair-bundle-generation
                 :protocol +coordinated-repair-bundle-protocol+
                 :generation *generation*
                 :age *coordinated-repair-bundle-age*
                 :attempted attempted :accepted accepted
                 :fallback (- attempted accepted)
                 :records records))))
      (incf *coordinated-repair-bundle-age*)
      (setf *coordinated-repair-bundle-generation-records* nil))))
