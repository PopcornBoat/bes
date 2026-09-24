(in-package :cl-tpg)

(defun seed-or-random-seed (seed)
  "The start-search TCP packet will either contain :random or an integer seed.
   If an integer is provided, return it as is. If it is :random, return a random integer."
  (if (eq seed :random)
      (random 9999999999)
      seed))

(defun make-initial-population ()
  "Set the population to an initial set of random candidate solutions."
  (setf *teams* (loop repeat *population-size*
			   collect (make-team))))

(defun accuracy (team dataset)
  (let ((predictions (execute-team-on-dataset team dataset))
	(actuals (actions dataset)))
    (/ (loop for actual across actuals
	  for predicted in predictions
	     count (= actual predicted))
       (length actuals))))

(defun semantic-response-index (response)
  "Return the dataset integer for a decoded semantic RESPONSE, or NIL."
  (case response
    (:analyse 0)
    (:remove 1)
    (:restore 2)
    (:decoy 3)
    (otherwise nil)))

(defun semantic-action-label-matches-p
       (prediction label &optional decoy-mask option-orders)
  "Compare PREDICTION with a canonical (target response option) LABEL.

GLOBAL requires only the target. Host non-Decoy labels require target and
response. A new factored Decoy is resolved through the policy-owned order (or
the agreement default) and the row's DECOY-MASK; a legacy prediction with an
explicit option retains its old comparison. This mirrors the online bridge
contract."
  (destructuring-bind (target response option) label
    (and (= (semantic-action-target prediction) target)
         (or (= target +global-target+)
             (let ((predicted-response
                     (semantic-response-index
                      (semantic-action-response prediction))))
               (and predicted-response
                    (= predicted-response response)
                    (or (/= response 3)
                        (let ((predicted-option
                                (or (semantic-action-option prediction)
                                    (first-available-decoy-option
                                     target decoy-mask option-orders))))
                          (and (integerp predicted-option)
                               (= predicted-option option))))))))))

(defun semantic-label-category-pair (label)
  "Collapse a legacy dataset triple to its ranked target/response label."
  (destructuring-bind (target response option) label
    (declare (ignore option))
    (if (= target +global-target+)
        (list +global-target+ 0)
        (list target response))))

(defun resolve-semantic-ranking (predictions decoy-mask option-orders)
  "Return the first executable target/response pair from PREDICTIONS.

Decoy availability is evaluated from the row mask. If the first choice is an
exhausted Decoy, later candidates are tried without another TPG call. Restore
is intentionally skipped only while falling back, matching the fixed teacher's
next-best rule. Exhausting the ranking safely returns GLOBAL Monitor."
  (loop for prediction in predictions
        for rank fixnum from 0
        for pair = (semantic-action-category-pair prediction)
        for target = (first pair)
        for response = (second pair)
        do (cond
             ((= target +global-target+)
              (return pair))
             ((= response 3)
              (when (integerp
                     (first-available-decoy-option
                      target decoy-mask option-orders))
                (return pair)))
             ((and (> rank 0) (= response 2))
              nil)
             (t
              (return pair)))
        finally (return (list +global-target+ 0))))

(defun semantic-ranking-ndcg (predictions teacher-ranking)
  "Return NDCG for PREDICTIONS under the teacher's frequency-derived order."
  (let* ((teacher-count (length teacher-ranking))
         (relevance (make-hash-table :test #'equal))
         (dcg 0.0d0)
         (ideal 0.0d0))
    (loop for pair in teacher-ranking
          for rank fixnum from 0
          do (setf (gethash pair relevance) (- teacher-count rank))
             (incf ideal
                   (/ (coerce (- teacher-count rank) 'double-float)
                      (log (+ rank 2.0d0) 2.0d0))))
    (loop for prediction in predictions
          for rank fixnum from 0
          for value = (gethash (semantic-action-category-pair prediction)
                               relevance
                               0)
          when (> value 0)
            do (incf dcg
                     (/ (coerce value 'double-float)
                        (log (+ rank 2.0d0) 2.0d0))))
    (if (zerop ideal) 0.0d0 (/ dcg ideal))))

(defun semantic-accuracy (team dataset &optional indices)
  "Return strict hierarchical semantic accuracy for TEAM on DATASET.

When INDICES is supplied, evaluate only those rows. Sampling remains outside
this function so an entire population can share exactly the same batch."
  (let ((correct 0)
        (count 0)
        (observations (observations dataset))
        (labels (actions dataset))
        (decoy-masks (dataset-decoy-masks dataset)))
    (labels ((score-row (index)
               ;; Reference scoring can cover tens of thousands of rows. Check
               ;; periodically so a stop request does not wait for the complete
               ;; held-out dataset to finish.
               (when (and *search-active*
                          (zerop (logand count 255)))
                 (abort-search-if-requested))
                (when (semantic-action-label-matches-p
                       (execute-team-semantic
                        team
                        (policy-observation (aref observations index)))
                      (aref labels index)
                      (aref decoy-masks index)
                      (effective-team-option-orders team))
                 (incf correct))
               (incf count)))
      (if indices
          (loop for index across indices do (score-row index))
          (dotimes (index (dataset-size dataset))
            (score-row index))))
    (if (zerop count)
        0.0d0
        (/ (coerce correct 'double-float)
           (coerce count 'double-float)))))

(defun phase4-selection-active-p ()
  "Return true only for the frozen official-guided Phase-4a treatment."
  (and *phase4-selection-enabled* (official-guided-mode-p)))

(defun initialize-phase4-selection-state (search-seed)
  "Initialize the isolated counter-based survivor-selection stream."
  (unless (integerp search-seed)
    (error "Phase-4a selection requires an integer search seed, got ~S."
           search-seed))
  (setf *phase4-selection-rng-root*
          (official-guided-mix64
           (+ search-seed +phase4-selection-rng-salt+))
        *phase4-selection-rng-cursor* 0
        *phase4-selection-age* 0))

(defun phase4-selection-state-copy ()
  "Return a serialization-safe copy of the isolated selection stream."
  (and *phase4-selection-rng-root*
       (list :version 1
             :protocol +phase4-selection-protocol+
             :root *phase4-selection-rng-root*
             :cursor *phase4-selection-rng-cursor*
             :age *phase4-selection-age*)))

(defun phase4-selection-state-valid-p (state)
  "Return true when STATE can exactly resume Phase-4a selection draws."
  (and (listp state)
       (= (getf state :version 0) 1)
       (eq (getf state :protocol) +phase4-selection-protocol+)
       (integerp (getf state :root))
       (integerp (getf state :cursor))
       (not (minusp (getf state :cursor)))
       (integerp (getf state :age))
       (not (minusp (getf state :age)))))

(defun restore-phase4-selection-state (state)
  "Restore a validated Phase-4a selection stream without touching *RANDOM-STATE*."
  (unless (phase4-selection-state-valid-p state)
    (error "Invalid Phase-4a selection state: ~S" state))
  (setf *phase4-selection-rng-root* (getf state :root)
        *phase4-selection-rng-cursor* (getf state :cursor)
        *phase4-selection-age* (getf state :age))
  state)

(defun phase4-selection-random-below (limit)
  "Return a deterministic integer below LIMIT from the isolated stream."
  (unless (and (integerp limit) (plusp limit))
    (error "Phase-4a random limit must be positive, got ~S." limit))
  (unless *phase4-selection-rng-root*
    (error "Phase-4a selection RNG is not initialized."))
  (prog1
      (mod (official-guided-mix64
            (+ *phase4-selection-rng-root*
               *phase4-selection-rng-cursor*))
           limit)
    (incf *phase4-selection-rng-cursor*)))

(defun phase4-shuffled-copy (sequence)
  "Return a selection-stream-shuffled vector copy of SEQUENCE."
  (let ((result (coerce sequence 'vector)))
    (loop for index from (1- (length result)) downto 1
          for swap = (phase4-selection-random-below (1+ index))
          do (rotatef (aref result index) (aref result swap)))
    result))

(defun reset-phase4-selection-runtime ()
  "Clear generation-local and lifecycle diagnostics without changing RNG state."
  (setf *phase4-case-groups* nil
        *phase4-row-group-keys* nil
        *phase4-team-group-scores* (make-hash-table :test #'eq)
        *phase4-team-group-exact-rates* (make-hash-table :test #'eq)
        *phase4-team-row-behaviors* (make-hash-table :test #'eq)
        *phase4-group-epsilons* (make-hash-table :test #'equal)
        *phase4-group-medians* (make-hash-table :test #'equal)
        *phase4-active-specialists* (make-hash-table :test #'eq)
        *phase4-specialist-history* nil
        *phase4-selection-generation-record* nil))

(defun phase4-step-group-key (step)
  "Map one recorded step to the frozen Phase-4a phase case."
  (cond
    ((and (integerp step) (<= 3 step 9)) '(:phase :steps-3-9))
    ((and (integerp step) (<= 10 step 29)) '(:phase :steps-10-29))
    ((and (integerp step) (<= 30 step 49)) '(:phase :steps-30-49))
    ((and (integerp step) (<= 50 step 99)) '(:phase :steps-50-99))
    (t nil)))

(defun phase4-teacher-pair-group-key (label)
  "Return the target/response case key for semantic LABEL."
  (let ((pair (semantic-label-category-pair label)))
    (list :teacher-pair (first pair) (second pair))))

(defun phase4-group-key-string (key)
  "Return a deterministic sortable representation for a group KEY."
  (with-standard-io-syntax
    (prin1-to-string key)))

(defun prepare-phase4-selection-generation (dataset)
  "Freeze this generation's Phase-4a cases from existing DAgger metadata."
  (when (phase4-selection-active-p)
    (unless (dataset-episode-metadata-p dataset)
      (error "Phase-4a requires DAgger episode/step metadata."))
    (let* ((count (dataset-size dataset))
           (steps (dataset-steps dataset))
           (labels (actions dataset))
           (indices-by-key (make-hash-table :test #'equal))
           (pair-counts (make-hash-table :test #'equal))
           (row-groups (make-array count :initial-element nil)))
      (dotimes (index count)
        (let ((phase-key (phase4-step-group-key (aref steps index)))
              (pair-key (phase4-teacher-pair-group-key
                         (aref labels index))))
          (when phase-key
            (push index (gethash phase-key indices-by-key)))
          (incf (gethash pair-key pair-counts 0))))
      (maphash
       (lambda (key pair-count)
         (when (>= pair-count +phase4-minimum-pair-group-size+)
           (dotimes (index count)
             (when (equal key
                          (phase4-teacher-pair-group-key
                           (aref labels index)))
               (push index (gethash key indices-by-key))))))
       pair-counts)
      (let ((keys
              (sort (alexandria:hash-table-keys indices-by-key)
                    #'string< :key #'phase4-group-key-string)))
        (setf *phase4-case-groups*
              (loop for key in keys
                    for indices = (coerce
                                   (nreverse (gethash key indices-by-key))
                                   'vector)
                    when (plusp (length indices))
                      collect (list :key key :indices indices)))
        (dolist (group *phase4-case-groups*)
          (let ((key (getf group :key)))
            (loop for index across (getf group :indices)
                  do (push key (aref row-groups index)))))
        (dotimes (index count)
          (setf (aref row-groups index)
                (nreverse (aref row-groups index))))
        (setf *phase4-row-group-keys* row-groups
              *phase4-team-group-scores* (make-hash-table :test #'eq)
              *phase4-team-group-exact-rates* (make-hash-table :test #'eq)
              *phase4-team-row-behaviors* (make-hash-table :test #'eq)
              *phase4-group-epsilons* (make-hash-table :test #'equal)
              *phase4-group-medians* (make-hash-table :test #'equal)
              *phase4-selection-generation-record* nil)
        (unless *phase4-case-groups*
          (error "Phase-4a produced no active case groups."))
        (emit-message
         (format nil "Generation ~D Phase-4a cases: ~{~S~^, ~}."
                 *generation* (mapcar (lambda (group) (getf group :key))
                                      *phase4-case-groups*)))))))

(defun phase4-groups-intersect-p (left right)
  "Return true when two group-key lists share an EQUAL key."
  (some (lambda (key) (member key right :test #'equal)) left))

(defun phase4-note-routing-observation (row-groups visited terminal-team)
  "Accumulate observational specialist routing for one evaluated row."
  (when (and *phase4-active-specialists* row-groups)
    (dolist (team visited)
      (let ((record (gethash team *phase4-active-specialists*)))
        (when (and record
                   (phase4-groups-intersect-p
                    row-groups (getf record :specialty-groups)))
          (incf (getf record :visited-count 0))
          (when (eq team terminal-team)
            (incf (getf record :terminal-winning-count 0))))))))

(defun semantic-ranking-behavior-code (resolved predictions)
  "Return an exact compact integer for one resolved/ranked semantic behavior."
  (let ((code (1+ (or (semantic-36-pair-index
                       (first resolved) (second resolved))
                      +num-semantic-36-actions+))))
    (dolist (prediction predictions code)
      (let* ((pair (semantic-action-category-pair prediction))
             (index (semantic-36-pair-index (first pair) (second pair))))
        (setf code
              (+ (* code (+ 2 +num-semantic-36-actions+))
                 (1+ (or index +num-semantic-36-actions+))))))))

(defun semantic-ranked-row-evaluation (team dataset index option-orders)
  "Return row score, exact behavior, preferred path, and terminal team."
  (let* ((teacher-ranking
           (aref (dataset-semantic-rankings dataset) index))
         (prediction-limit
           (min +semantic-ranking-limit+
                (max 1 (length teacher-ranking))))
         (observation
           (policy-observation (aref (observations dataset) index))))
    (multiple-value-bind (predictions visited terminal-team)
        (execute-team-semantic-ranked team observation prediction-limit)
      (let* ((resolved
               (resolve-semantic-ranking
                predictions
                (aref (dataset-decoy-masks dataset) index)
                option-orders))
             (expected
               (semantic-label-category-pair
                (aref (actions dataset) index)))
             (exact-p (equal resolved expected)))
        (values
         (+ (if exact-p
                +ranked-behavior-fitness-weight+
                0.0d0)
            (* +ranked-order-fitness-weight+
               (semantic-ranking-ndcg predictions teacher-ranking)))
         (semantic-ranking-behavior-code resolved predictions)
         visited
         terminal-team
         exact-p)))))

(defun semantic-ranked-row-score (team dataset index option-orders)
  "Return the ranked imitation contribution for one DATASET row."
  (nth-value 0
    (semantic-ranked-row-evaluation team dataset index option-orders)))

(defun phase4-ranked-training-fitness (team dataset)
  "Evaluate every row once and retain grouped scores and routing diagnostics."
  (unless *phase4-case-groups*
    (error "Phase-4a case groups were not prepared before evaluation."))
  (let* ((count (dataset-size dataset))
         (option-orders (effective-team-option-orders team))
         (behaviors (make-array count :element-type 'integer))
         (sums (make-hash-table :test #'equal))
         (exact-counts (make-hash-table :test #'equal))
         (counts (make-hash-table :test #'equal))
         (total 0.0d0))
    (dotimes (index count)
      (when (and *search-active* (zerop (logand index 255)))
        (abort-search-if-requested))
      (multiple-value-bind
            (row-score behavior visited terminal-team exact-p)
          (semantic-ranked-row-evaluation team dataset index option-orders)
        (setf (aref behaviors index) behavior)
        (incf total row-score)
        (let ((row-groups (aref *phase4-row-group-keys* index)))
          (dolist (key row-groups)
            (incf (gethash key sums 0.0d0) row-score)
            (when exact-p
              (incf (gethash key exact-counts 0)))
            (incf (gethash key counts 0)))
          (phase4-note-routing-observation
           row-groups visited terminal-team))))
    (let ((group-scores (make-hash-table :test #'equal))
          (group-exact-rates (make-hash-table :test #'equal)))
      (dolist (group *phase4-case-groups*)
        (let* ((key (getf group :key))
               (group-count (gethash key counts 0)))
          (unless (plusp group-count)
            (error "Active Phase-4a case ~S has no scored rows." key))
          (setf (gethash key group-scores)
                (/ (gethash key sums 0.0d0)
                   (coerce group-count 'double-float))
                (gethash key group-exact-rates)
                (/ (coerce (gethash key exact-counts 0) 'double-float)
                   (coerce group-count 'double-float)))))
      (setf (gethash team *phase4-team-group-scores*) group-scores
            (gethash team *phase4-team-group-exact-rates*) group-exact-rates
            (gethash team *phase4-team-row-behaviors*) behaviors))
    (if (zerop count)
        0.0d0
        (/ total (coerce count 'double-float)))))

(defun semantic-ranked-fitness (team dataset &optional indices)
  "Score independent rows by executable behavior plus teacher ranking agreement."
  (let ((score 0.0d0)
        (count 0)
        (option-orders (effective-team-option-orders team)))
    (labels ((score-row (index)
               (when (and *search-active*
                          (zerop (logand count 255)))
                 (abort-search-if-requested))
               (incf score
                     (semantic-ranked-row-score
                      team dataset index option-orders))
               (incf count)))
      (if indices
          (loop for index across indices do (score-row index))
          (dotimes (index (dataset-size dataset))
            (score-row index))))
    (if (zerop count)
        0.0d0
        (/ score (coerce count 'double-float)))))

(defun semantic-ranked-sequence-fitness
       (team dataset &optional episode-indices)
  "Score complete ordered episodes while preserving learner registers.

Registers start at zero for every episode. Under the fixed opening protocol,
rows before the first TPG-owned step neither execute programs nor contribute to
fitness, exactly matching online rollout behavior."
  (ensure-recurrent-dataset-compatible dataset "Recurrent semantic dataset")
  (let ((score 0.0d0)
        (count 0)
        (ranges (dataset-episode-ranges dataset))
        (option-orders (effective-team-option-orders team)))
    (labels ((score-episode (episode-index)
               (let ((range (aref ranges episode-index)))
                 (call-with-fresh-policy-episode
                  (lambda ()
                    (loop for index from (car range) below (cdr range)
                          when (recurrent-policy-row-p dataset index)
                            do (when (and *search-active*
                                          (zerop (logand count 255)))
                                 (abort-search-if-requested))
                               (incf score
                                     (semantic-ranked-row-score
                                      team dataset index option-orders))
                               (incf count)))))))
      (if episode-indices
          (loop for episode-index across episode-indices
                do (score-episode episode-index))
          (dotimes (episode-index (length ranges))
            (score-episode episode-index))))
    (if (zerop count)
        0.0d0
        (/ score (coerce count 'double-float)))))

(defun semantic-dataset-fitness (team dataset &optional indices)
  "Dispatch semantic fitness according to the dataset protocol generation."
  (ecase (dataset-action-format dataset)
    (:semantic
     (semantic-accuracy team dataset indices))
    (:semantic-ranked
     (semantic-ranked-fitness team dataset indices))))

(defun make-uniform-dataset-indices (dataset)
  "Return an unbalanced uniform sample without replacement, or NIL for all rows."
  (let ((size (dataset-size dataset)))
    (unless (> size 0)
      (error "Cannot sample an empty semantic dataset."))
    (unless (and (integerp *batch-size*) (> *batch-size* 0))
      (error "*BATCH-SIZE* must be a positive integer."))
    (when (< *batch-size* size)
      (let ((chosen (make-hash-table :test #'eql))
            (indices (make-array *batch-size* :element-type 'fixnum)))
        (loop until (= (hash-table-count chosen) *batch-size*)
              do (setf (gethash (random size) chosen) t))
        (let ((position 0))
          (maphash (lambda (index ignored)
                     (declare (ignore ignored))
                     (setf (aref indices position) index)
                     (incf position))
                   chosen))
        (sort indices #'<)))))

(defun dataset-episode-policy-row-count (dataset episode-index)
  "Return the number of policy-owned rows in one DATASET episode."
  (let ((range (aref (dataset-episode-ranges dataset) episode-index)))
    (loop for index from (car range) below (cdr range)
          count (recurrent-policy-row-p dataset index))))

(defun make-uniform-dataset-episode-indices (dataset)
  "Sample complete episodes up to the configured transition budget.

The returned episodes are sorted into source order. Sampling can exceed the
row budget by the final complete episode; no recurrent context is truncated."
  (ensure-recurrent-dataset-compatible dataset "Recurrent offline dataset")
  (unless (and (integerp *batch-size*) (> *batch-size* 0))
    (error "*BATCH-SIZE* must be a positive integer."))
  (let* ((ranges (dataset-episode-ranges dataset))
         (episode-count (length ranges))
         (total-policy-rows
           (loop for episode-index below episode-count
                 sum (dataset-episode-policy-row-count
                      dataset episode-index))))
    (when (< *batch-size* total-policy-rows)
      (let ((candidates
              (make-array episode-count
                          :element-type 'fixnum
                          :initial-contents
                          (loop for index below episode-count collect index)))
            (selected nil)
            (selected-rows 0))
        (loop for position from 0 below episode-count
              while (< selected-rows *batch-size*)
              for selected-position =
                (+ position (random (- episode-count position)))
              do (rotatef (aref candidates position)
                          (aref candidates selected-position))
                 (let ((episode-index (aref candidates position)))
                   (push episode-index selected)
                   (incf selected-rows
                         (dataset-episode-policy-row-count
                          dataset episode-index))))
        (coerce (sort selected #'<) 'vector)))))

(defun semantic-offline-training-fitness (team)
  "Evaluate TEAM on the generation-shared row or complete-episode batch."
  (unless *offline-training-dataset*
    (error "Semantic offline training dataset is not configured."))
  (if *recurrent-policy-enabled*
      (progn
        (unless *offline-fitness-batch-episode-indices*
          (setf *offline-fitness-batch-episode-indices*
                (or (make-uniform-dataset-episode-indices
                     *offline-training-dataset*)
                    :all)))
        (semantic-ranked-sequence-fitness
         team
         *offline-training-dataset*
         (unless (eq *offline-fitness-batch-episode-indices* :all)
           *offline-fitness-batch-episode-indices*)))
      (progn
        (unless *offline-fitness-batch-indices*
          (setf *offline-fitness-batch-indices*
                (or (make-uniform-dataset-indices
                     *offline-training-dataset*)
                    :all)))
        (semantic-dataset-fitness
         team
         *offline-training-dataset*
         (unless (eq *offline-fitness-batch-indices* :all)
           *offline-fitness-batch-indices*)))))

(defun semantic-offline-reference-fitness (team)
  "Evaluate TEAM on the complete fixed held-out semantic dataset."
  (unless *offline-reference-dataset*
    (error "Semantic offline reference dataset is not configured."))
  (if *recurrent-policy-enabled*
      (semantic-ranked-sequence-fitness team *offline-reference-dataset*)
      (semantic-dataset-fitness team *offline-reference-dataset*)))

(defun semantic-validation-dataset-path (training-path)
  "Infer the sibling validation path from a semantic training dataset path."
  (let* ((path (pathname training-path))
         (name (pathname-name path))
         (suffix "_train")
         (validation-name
           (if (and (>= (length name) (length suffix))
                    (string= suffix
                             (subseq name (- (length name)
                                             (length suffix)))))
               (concatenate 'string
                            (subseq name 0 (- (length name) (length suffix)))
                            "_val")
               (concatenate 'string name "_val"))))
    (make-pathname :name validation-name :defaults path)))

(defun dataset-file-fingerprint (dataset)
  "Return a portable name/byte-size identity for DATASET's source file."
  (let ((path (pathname (dataset-source-path dataset))))
    (list :name (file-namestring path)
          :bytes (with-open-file
                     (stream path
                             :direction :input
                             :element-type '(unsigned-byte 8))
                   (file-length stream)))))

(defun arithmetic-mean (values)
  "Return the arithmetic mean of VALUES as a double-float."
  (if (null values)
      0.0d0
      (let ((sum
        (coerce
         (reduce #'+
                 values
                 :initial-value 0.0d0)
         'double-float)))

        (/ sum
           (coerce (length values)
                   'double-float)))))

(defun numeric-median (values)
  "Return the median of VALUES as a double-float."
  (if (null values)
      0.0d0
      (let* ((sorted (sort (copy-list values) #'<))
             (n (length sorted))
             (middle (floor n 2)))
        (if (oddp n)
            (coerce (nth middle sorted)
                    'double-float)
            (/ (coerce (+ (nth (1- middle) sorted)
                          (nth middle sorted))
                       'double-float)
               2.0d0)))))

(defun abort-search-if-requested ()
  "Leave the current search promptly after a stop request.

The non-local exit is caught by RUN-SEARCH or RUN-SEARCH-FROM-BEST-TEAM.  It is
not an error and therefore is not converted into a bad-team fitness result."
  (unless *running*
    (throw 'search-stop-requested nil)))

(defun make-online-fitness-episode-seeds
       (&optional root-seed (episode-count *online-fitness-episodes*))
  "Return one seed per online-fitness episode.

With ROOT-SEED, derive a reproducible seed bank without consuming the search
random state. Without it, consume the search random state so each generation
receives a new batch."
  (unless (and (integerp episode-count) (> episode-count 0))
    (error "Episode count must be a positive integer, got ~S." episode-count))

  (let ((*random-state*
          (if root-seed
              (sb-ext:seed-random-state root-seed)
              *random-state*)))
    (loop repeat episode-count
          collect (random 9999999))))

(defun online-fitness-episodes-for-generation (generation)
  "Return the active online training episode count for GENERATION.

Requesting five episodes enables the reproducible 5 -> 10 -> 20 curriculum.
Any other launch value remains fixed for controlled comparison runs."
  (if (= *configured-online-fitness-episodes* 5)
      (loop with result = 5
            for (start . episodes) in +online-fitness-episode-schedule+
            when (>= generation start) do (setf result episodes)
            finally (return result))
      *configured-online-fitness-episodes*))

(defun update-online-fitness-stage ()
  "Apply and report the episode stage used by this online CAGE2 generation."
  (when (and (eq *current-search-mode* :online)
             (cl-gym:cage2-environment-p *current-gym-environment-name*))
    (let ((episodes (online-fitness-episodes-for-generation *generation*)))
      (unless (= episodes *online-fitness-episodes*)
        (setf *online-fitness-episodes* episodes)
        (emit-message
         (format nil
                 "Online fitness stage changed: generation=~D episodes=~D."
                 *generation*
                 episodes))))))

(defun cage2-fitness-on-seeds (team gym-environment-name episode-seeds)
  "Evaluate TEAM on the exact CAGE2 EPISODE-SEEDS and return mean reward."
  (arithmetic-mean
   (loop for episode-seed in episode-seeds
         do (abort-search-if-requested)
         collect
         (cl-gym:rollout team gym-environment-name episode-seed))))

(defun cage2-reference-scores (team gym-environment-name)
  "Return TEAM rewards on the protected fixed 100-episode seed bank."
  (let ((seeds
          (make-online-fitness-episode-seeds
           +cage2-evaluation-seed+
           +cage2-online-reference-episodes+)))
    (loop for episode-seed in seeds
          do (abort-search-if-requested)
          collect (cl-gym:rollout team gym-environment-name episode-seed))))

(defun cage2-reference-fitness (team gym-environment-name)
  "Evaluate TEAM on the protected fixed CAGE2 reference bank."
  (arithmetic-mean (cage2-reference-scores team gym-environment-name)))

(defun sample-standard-error (values)
  "Return the sample standard error of numeric VALUES."
  (if (< (length values) 2)
      0.0d0
      (let* ((mean (arithmetic-mean values))
             (n (length values))
             (sum-of-squares
               (loop for value in values
                     for delta = (- (coerce value 'double-float) mean)
                     sum (* delta delta) into total
                     finally (return (coerce total 'double-float))))
             (variance
               (/ sum-of-squares (coerce (1- n) 'double-float))))
        (/ (sqrt variance) (sqrt (coerce n 'double-float))))))

(defun online-reference-promotion-p (candidate-scores incumbent-scores)
  "Require a positive paired one-standard-error improvement over INCUMBENT."
  (if (null incumbent-scores)
      t
      (let* ((differences (mapcar #'- candidate-scores incumbent-scores))
             (mean-difference (arithmetic-mean differences))
             (margin
               (* +cage2-online-promotion-standard-errors+
                  (sample-standard-error differences))))
        (values (> mean-difference margin) mean-difference margin))))

(defun online-candidate-screen-worthy-p (candidate-scores incumbent-scores)
  "Return true unless the first-stage paired sample already shows futility.

The screen is deliberately permissive: it continues to the complete reference
bank whenever the paired mean plus one standard error is positive. The final
promotion still requires the stricter positive one-standard-error improvement."
  (let* ((differences (mapcar #'- candidate-scores incumbent-scores))
         (mean-difference (arithmetic-mean differences))
         (uncertainty
           (* +online-candidate-screen-standard-errors+
              (sample-standard-error differences))))
    (values (> (+ mean-difference uncertainty) 0.0d0)
            mean-difference
            uncertainty)))

(defun read-readable-object (path)
  "Read one printed Common Lisp object from PATH using standard syntax."
  (with-open-file (stream path :direction :input)
    (with-standard-io-syntax
      (read stream))))

(defun write-readable-object-atomically (object path)
  "Write OBJECT beside PATH and atomically publish the completed file."
  (let* ((destination (pathname path))
         (temporary
           (make-pathname
            :name (format nil ".~A-~D"
                          (or (pathname-name destination) "result")
                          (get-universal-time))
            :type "tmp"
            :defaults destination)))
    (ensure-directories-exist destination)
    (unwind-protect
         (progn
           (with-open-file (stream temporary
                                   :direction :output
                                   :if-exists :supersede
                                   :if-does-not-exist :create)
             (with-standard-io-syntax
               (let ((*print-circle* t)
                     (*print-readably* t)
                     (*print-pretty* nil))
                 (write object :stream stream))))
           (uiop:rename-file-overwriting-target temporary destination))
      (when (probe-file temporary)
        (delete-file temporary)))
    destination))

(defun online-candidate-evaluation-enabled-p ()
  "Return true when CAGE2 online search has a replayable incumbent bank."
  (and (eq *current-search-mode* :online)
       *current-gym-environment-name*
       (cl-gym:cage2-environment-p *current-gym-environment-name*)
       *checkpoint-directory*
       *best-fitness*
       (= (length *online-best-reference-scores*)
          +cage2-online-reference-episodes+)))

(defun reset-online-candidate-evaluation-state ()
  "Discard local staged-evaluator state before a fresh or resumed search."
  (when (and *online-candidate-process*
             (ignore-errors
               (uiop:process-alive-p *online-candidate-process*)))
    (ignore-errors
      (uiop:terminate-process *online-candidate-process*)))
  (setf *online-candidate-process* nil
        *online-candidate-job* nil
        *online-candidate-next-submit-generation*
          (+ *generation* +online-candidate-evaluation-interval+)
        *online-staged-best-team* nil
        *online-staged-best-fitness* nil
        *online-staged-best-generation* nil
        *online-staged-best-lineage* nil
        *online-staged-best-parent-team* nil))

(defun online-candidate-directory ()
  "Return the private staged-evaluation directory for this checkpoint run."
  (checkpoint-path *checkpoint-directory* ".online-candidates/"))

(defun online-candidate-path (generation kind type)
  "Return one unique artifact path for GENERATION, KIND, and pathname TYPE."
  (merge-pathnames
   (make-pathname
    :name (format nil "generation-~D-~A" generation kind)
    :type type)
   (uiop:ensure-directory-pathname (online-candidate-directory))))

(defun write-online-candidate-checkpoint (team training-fitness generation path)
  "Write frozen TEAM to the evaluator's private candidate checkpoint PATH."
  (write-best-team-checkpoint
   team
   training-fitness
   path
   :generation generation
   :gym-environment-name *current-gym-environment-name*
   :online-fitness-episodes *online-fitness-episodes*
   :search-seed *current-search-seed*
   :fitness-evaluation-protocol +cage2-online-fitness-protocol+
   :dataset-name *current-dataset-name*
   :dataset-fingerprint *current-dataset-fingerprint*
   :action-agreement-signature (action-agreement-signature)
   :online-reference-episodes +cage2-online-reference-episodes+
   :mixed-training-lineage *mixed-training-lineage*
   :hamming-space-enabled *hamming-space-enabled*
   :hamming-dataset-fingerprint *current-hamming-dataset-fingerprint*
   :num-observations *num-observations*
   :decoy-order-mode *decoy-order-mode*
   :cage2-opening-mode *cage2-opening-mode*
   :recurrent-policy-enabled *recurrent-policy-enabled*
   :teacher-backend *teacher-backend*))

(defun note-online-generation-candidate (team fitness)
  "Retain the strongest training winner seen in the current submission window."
  (when (or (null *online-staged-best-fitness*)
            (> fitness *online-staged-best-fitness*))
    (let ((parent (behavioral-parent-for-team team)))
      (setf *online-staged-best-team*
              (deep-copy-team-via-serialization team)
            *online-staged-best-fitness* fitness
            *online-staged-best-generation* *generation*
            *online-staged-best-lineage*
              (behavioral-lineage-for-team team)
            *online-staged-best-parent-team*
              (and parent
                   (deep-copy-team-via-serialization parent))))))

(defun launch-online-candidate-evaluation ()
  "Publish the accumulated candidate and start its independent SBCL worker."
  (let* ((generation *online-staged-best-generation*)
         (training-fitness *online-staged-best-fitness*)
         (candidate-path
           (online-candidate-path generation "candidate" "lisp"))
         (request-path
           (online-candidate-path generation "request" "lisp"))
         (result-path
           (online-candidate-path generation "result" "lisp"))
         (log-path
           (online-candidate-path generation "worker" "log"))
         (worker-script
           (merge-pathnames
            "scripts/run-online-candidate-evaluation.lisp"
            (asdf:system-source-directory :cl-tpg))))
    (unless (and generation *online-staged-best-team*)
      (error "Cannot submit an empty online candidate window."))
    (write-online-candidate-checkpoint
     *online-staged-best-team* training-fitness generation candidate-path)
    (write-readable-object-atomically
     (list :version 1
           :candidate-path (namestring candidate-path)
           :result-path (namestring result-path)
           :candidate-generation generation
           :candidate-training-fitness training-fitness
           :incumbent-fitness *best-fitness*
           :incumbent-scores (copy-list *online-best-reference-scores*)
           :gym-environment-name *current-gym-environment-name*
           :num-observations *num-observations*
           :num-actions *num-actions*
           :decoy-order-mode *decoy-order-mode*
           :cage2-opening-mode *cage2-opening-mode*
           :recurrent-policy-enabled *recurrent-policy-enabled*
           :teacher-backend *teacher-backend*
           :hamming-space-enabled *hamming-space-enabled*
           :hamming-dataset-name *hamming-dataset-name*
           :reference-episodes +cage2-online-reference-episodes+
           :screen-episodes +online-candidate-screen-episodes+)
     request-path)
    (setf *online-candidate-process*
            (uiop:launch-program
             (list "sbcl"
                   "--dynamic-space-size" "4096"
                   "--noinform" "--non-interactive"
                   "--load" (namestring worker-script)
                   "--end-toplevel-options"
                   (namestring request-path))
             :input nil
             :output log-path
             :error-output :output
             :if-output-exists :supersede
             :ignore-error-status t)
          *online-candidate-job*
            (list :generation generation
                  :training-fitness training-fitness
                  :candidate-path candidate-path
                  :request-path request-path
                  :result-path result-path
                  :log-path log-path
                  :incumbent-fitness *best-fitness*)
          *online-candidate-next-submit-generation*
            (+ *generation* +online-candidate-evaluation-interval+)
          *online-staged-best-team* nil
          *online-staged-best-fitness* nil
          *online-staged-best-generation* nil
          *online-staged-best-lineage* nil
          *online-staged-best-parent-team* nil)
    (emit-message
     (format nil
             "Generation ~D submitted to independent online evaluator: training-fitness=~A screen=~D reference=~D."
             generation training-fitness
             +online-candidate-screen-episodes+
             +cage2-online-reference-episodes+))))

(defun staged-incumbent-current-p (result)
  "Reject a worker result if the in-memory incumbent changed meanwhile."
  (fitness-values-equivalent-p
   (getf result :incumbent-fitness)
   *best-fitness*))

(defun consume-online-candidate-result (result)
  "Apply one completed worker RESULT on the main search thread."
  (let ((generation (getf result :candidate-generation))
        (candidate-path (getf *online-candidate-job* :candidate-path)))
    (cond
      ((eq (getf result :status) :error)
       (emit-message
        (format nil
                "Independent evaluator failed for generation ~D: ~A"
                generation (getf result :message))))
      ((not (staged-incumbent-current-p result))
       (emit-message
        (format nil
                "Independent evaluator discarded stale generation ~D result: evaluated-incumbent=~A current-incumbent=~A."
                generation (getf result :incumbent-fitness) *best-fitness*)))
      ((not (getf result :accepted))
       (emit-message
        (format nil
                "Independent evaluator rejected generation ~D at ~A: candidate=~A incumbent=~A paired-delta=~,4F margin=~,4F."
                generation
                (getf result :stage)
                (getf result :candidate-fitness)
                (getf result :incumbent-fitness)
                (getf result :paired-delta)
                (getf result :margin))))
      (t
       (let ((candidate-team (load-best-team candidate-path)))
         (ensure-team-observation-compatible
          candidate-team *num-observations*)
         (setf *best-team* candidate-team
               *best-fitness* (getf result :candidate-fitness)
               *online-best-reference-scores*
                 (copy-list (getf result :candidate-scores)))
         (emit-message
          (format nil
                  "NEW GLOBAL BEST: generation=~D independent-reference-fitness=~A training-fitness=~A paired-delta=~,4F required-margin=~,4F."
                  generation
                  *best-fitness*
                  (getf result :candidate-training-fitness)
                  (getf result :paired-delta)
                  (getf result :margin)))
         ;; Record the generation that produced the accepted graph, not the
         ;; later generation at which the main thread noticed the result.
         (let ((*generation* generation))
           (save-best-team)))))))

(defun poll-online-candidate-evaluation ()
  "Consume a completed staged evaluator result without blocking evolution."
  (when *online-candidate-job*
    (let ((result-path (getf *online-candidate-job* :result-path)))
      (cond
        ((probe-file result-path)
         (handler-case
             (consume-online-candidate-result
              (read-readable-object result-path))
           (error (condition)
             (emit-message
              (format nil
                      "Could not consume independent evaluator result: ~A"
                      condition))))
         (setf *online-candidate-process* nil
               *online-candidate-job* nil))
        ((and *online-candidate-process*
              (not (ignore-errors
                     (uiop:process-alive-p
                      *online-candidate-process*))))
         (emit-message
          (format nil
                  "Independent evaluator exited without a result; see ~A"
                  (namestring
                   (getf *online-candidate-job* :log-path))))
         (setf *online-candidate-process* nil
               *online-candidate-job* nil))))))

(defun maybe-launch-online-candidate-evaluation ()
  "Submit the accumulated window when its deadline arrives and no worker runs."
  (when (and (online-candidate-evaluation-enabled-p)
             (null *online-candidate-job*)
             *online-staged-best-team*
             (>= *generation*
                 *online-candidate-next-submit-generation*))
    (launch-online-candidate-evaluation)))

(defun run-online-candidate-evaluation (request-path)
  "Worker entry point for a staged online candidate evaluation REQUEST-PATH."
  (let* ((request (read-readable-object request-path))
         (result-path (pathname (getf request :result-path)))
         (started (get-universal-time)))
    (labels ((publish (result)
               (write-readable-object-atomically
                (append result
                        (list :elapsed-seconds
                              (- (get-universal-time) started)))
                result-path)))
      (handler-case
          (let* ((*running* t)
                 (*search-active* nil)
                 (*current-search-mode* :online)
                 (*current-gym-environment-name*
                   (getf request :gym-environment-name))
                 (*num-observations* (getf request :num-observations))
                 (*num-actions* (getf request :num-actions))
                 (*decoy-order-mode* (getf request :decoy-order-mode))
                 (*cage2-opening-mode* (getf request :cage2-opening-mode))
                 (*teacher-backend* (getf request :teacher-backend :model))
                 (*recurrent-policy-enabled*
                   (not (null (getf request :recurrent-policy-enabled))))
                 (*hamming-space-enabled*
                   (getf request :hamming-space-enabled))
                 (*hamming-dataset-name*
                   (getf request :hamming-dataset-name))
                 (*factored-actions-enabled* t)
                 (reference-count (getf request :reference-episodes))
                 (screen-count (getf request :screen-episodes))
                 (incumbent-scores (getf request :incumbent-scores))
                 (team (load-best-team (getf request :candidate-path)))
                 (seeds
                   (make-online-fitness-episode-seeds
                    +cage2-evaluation-seed+ reference-count)))
            (unless (= reference-count (length incumbent-scores))
              (error "Incumbent score count ~D does not match reference count ~D."
                     (length incumbent-scores) reference-count))
            (unless (<= 1 screen-count reference-count)
              (error "Invalid staged screen size ~S for ~D references."
                     screen-count reference-count))
            (configure-hamming-observation-space)
            (ensure-team-observation-compatible team *num-observations*)
            (let* ((screen-scores
                     (loop for seed in seeds
                           repeat screen-count
                           collect
                           (cl-gym:rollout
                            team *current-gym-environment-name* seed)))
                   (incumbent-screen
                     (subseq incumbent-scores 0 screen-count)))
              (multiple-value-bind
                    (continue-p screen-delta screen-uncertainty)
                  (online-candidate-screen-worthy-p
                   screen-scores incumbent-screen)
                (if (not continue-p)
                    (publish
                     (list :status :complete
                           :accepted nil
                           :stage :screen
                           :candidate-generation
                             (getf request :candidate-generation)
                           :candidate-training-fitness
                             (getf request :candidate-training-fitness)
                           :candidate-fitness
                             (arithmetic-mean screen-scores)
                           :incumbent-fitness
                             (getf request :incumbent-fitness)
                           :paired-delta screen-delta
                           :margin screen-uncertainty
                           :evaluated-episodes screen-count))
                    (let* ((remaining-scores
                             (loop for seed in (nthcdr screen-count seeds)
                                   collect
                                   (cl-gym:rollout
                                    team
                                    *current-gym-environment-name*
                                    seed)))
                           (candidate-scores
                             (append screen-scores remaining-scores)))
                      (multiple-value-bind (accepted delta margin)
                          (online-reference-promotion-p
                           candidate-scores incumbent-scores)
                        (publish
                         (list :status :complete
                               :accepted accepted
                               :stage :reference
                               :candidate-generation
                                 (getf request :candidate-generation)
                               :candidate-training-fitness
                                 (getf request :candidate-training-fitness)
                               :candidate-fitness
                                 (arithmetic-mean candidate-scores)
                               :candidate-scores candidate-scores
                               :incumbent-fitness
                                 (getf request :incumbent-fitness)
                               :paired-delta delta
                               :margin margin
                               :screen-delta screen-delta
                               :screen-uncertainty screen-uncertainty
                               :evaluated-episodes reference-count))))))))
        (error (condition)
          (publish
           (list :status :error
                 :accepted nil
                 :candidate-generation
                   (getf request :candidate-generation)
                 :incumbent-fitness
                   (getf request :incumbent-fitness)
                 :message (princ-to-string condition)))))))
  t)

(defun official-guided-candidate-evaluation-enabled-p ()
  "Return true when Phase 1 has an incumbent that challengers may race."
  (and (official-guided-mode-p)
       *checkpoint-directory*
       *best-team*
       (plusp *official-guided-incumbent-version*)))

(defun official-guided-candidate-directory ()
  "Return the private worker directory for Phase-1 challenger artifacts."
  (checkpoint-path *checkpoint-directory* ".official-guided-candidates/"))

(defun official-guided-candidate-path (artifact-id kind type)
  "Return one unique Phase-1 artifact path for ARTIFACT-ID."
  (merge-pathnames
   (make-pathname
    :name (format nil "generation-~A-~A" artifact-id kind)
    :type type)
   (uiop:ensure-directory-pathname
    (official-guided-candidate-directory))))

(defun write-official-guided-team-checkpoint
       (team imitation-score generation path)
  "Write one fully independent graph for the Phase-1 worker."
  (write-best-team-checkpoint
   team imitation-score path
   :generation generation
   :gym-environment-name *current-gym-environment-name*
   :online-fitness-episodes *online-fitness-episodes*
   :search-seed *current-search-seed*
   :fitness-evaluation-protocol +official-guided-fitness-protocol+
   :action-agreement-signature (action-agreement-signature)
   :online-reference-episodes
     (third +official-guided-promotion-stages+)
   :mixed-training-lineage *mixed-training-lineage*
   :hamming-space-enabled nil
   :num-observations *num-observations*
   :decoy-order-mode *decoy-order-mode*
   :cage2-opening-mode *cage2-opening-mode*
   :recurrent-policy-enabled nil
   :teacher-backend *teacher-backend*))

(defun launch-official-guided-candidate-evaluation ()
  "Freeze candidate/incumbent graphs and launch official paired evaluation."
  (let* ((generation *online-staged-best-generation*)
         (imitation-score *online-staged-best-fitness*)
         ;; Warm-start resume resets the displayed generation counter.  Include
         ;; the incumbent version and wall-clock second so a resumed search can
         ;; never consume a stale result left by an earlier generation number.
         (artifact-id
           (format nil "~D-v~D-t~D"
                   generation *official-guided-incumbent-version*
                   (get-universal-time)))
         (candidate-path
           (official-guided-candidate-path artifact-id "candidate" "lisp"))
         (incumbent-path
           (official-guided-candidate-path artifact-id "incumbent" "lisp"))
         (parent-path
           (and *online-staged-best-parent-team*
                (official-guided-candidate-path
                 artifact-id "direct-parent" "lisp")))
         (request-path
           (official-guided-candidate-path artifact-id "request" "lisp"))
         (result-path
           (official-guided-candidate-path artifact-id "result" "lisp"))
         (log-path
           (official-guided-candidate-path artifact-id "worker" "log"))
         (worker-script
           (merge-pathnames
            "scripts/run-official-guided-candidate-evaluation.lisp"
            (asdf:system-source-directory :cl-tpg)))
         (racing-seeds
           (official-guided-take-seeds
            :racing +official-guided-racing-episodes+))
         (promotion-seeds
           (official-guided-take-seeds
            :promotion (car (last +official-guided-promotion-stages+))))
         (reference-seeds (official-guided-take-reference-seeds)))
    (unless (and generation *online-staged-best-team* *best-team*)
      (error "Cannot submit an empty official-guided challenger."))
    (write-official-guided-team-checkpoint
     *online-staged-best-team* imitation-score generation candidate-path)
    (write-official-guided-team-checkpoint
     *best-team* *best-fitness* generation incumbent-path)
    (when parent-path
      (write-official-guided-team-checkpoint
       *online-staged-best-parent-team*
       imitation-score generation parent-path))
    (write-readable-object-atomically
     (list :version 1
           :candidate-path (namestring candidate-path)
           :incumbent-path (namestring incumbent-path)
           :direct-parent-path (and parent-path (namestring parent-path))
           :result-path (namestring result-path)
           :candidate-generation generation
           :candidate-imitation-score imitation-score
           :incumbent-version *official-guided-incumbent-version*
           :gym-environment-name *current-gym-environment-name*
           :num-observations *num-observations*
           :num-actions *num-actions*
           :decoy-order-mode *decoy-order-mode*
           :cage2-opening-mode *cage2-opening-mode*
           :teacher-backend *teacher-backend*
           :behavioral-locality
             (copy-tree *online-staged-best-lineage*)
           :racing-seeds racing-seeds
           :promotion-seeds promotion-seeds
           :promotion-stages
             (copy-list +official-guided-promotion-stages+)
           :reference-seeds reference-seeds)
     request-path)
    (persist-official-guided-runtime-state)
    (setf *online-candidate-process*
            (uiop:launch-program
             (list "sbcl"
                   "--dynamic-space-size" "4096"
                   "--noinform" "--non-interactive"
                   "--load" (namestring worker-script)
                   "--end-toplevel-options"
                   (namestring request-path))
             :input nil
             :output log-path
             :error-output :output
             :if-output-exists :supersede
             :ignore-error-status t)
          *online-candidate-job*
            (list :mode :official-guided
                  :generation generation
                  :candidate-path candidate-path
                  :request-path request-path
                  :result-path result-path
                  :log-path log-path
                  :incumbent-version *official-guided-incumbent-version*)
          *online-candidate-next-submit-generation*
            (+ *generation* +online-candidate-evaluation-interval+)
          *online-staged-best-team* nil
          *online-staged-best-fitness* nil
          *online-staged-best-generation* nil
          *online-staged-best-lineage* nil
          *online-staged-best-parent-team* nil)
    (emit-message
     (format nil
             "Generation ~D submitted to official-guided evaluator: imitation=~,4F racing=~D promotion-stages=~S reference-monitor=~D."
             generation imitation-score (length racing-seeds)
             +official-guided-promotion-stages+ (length reference-seeds)))))

(defun official-guided-incumbent-current-p (result)
  "Reject results produced against a superseded incumbent."
  (= (getf result :incumbent-version -1)
     *official-guided-incumbent-version*))

(defun consume-official-guided-candidate-result (result)
  "Apply one completed Phase-1 worker result on the main search thread."
  (let* ((generation (getf result :candidate-generation))
         (candidate-path (getf *online-candidate-job* :candidate-path))
         (record (getf result :evaluation-record)))
    (setf *official-guided-last-evaluation* (copy-tree record))
    (persist-behavioral-official-outcome
     generation (getf record :behavioral-locality) record)
    (cond
      ((eq (getf result :status) :error)
       (emit-message
        (format nil "Official-guided evaluator failed for generation ~D: ~A"
                generation (getf result :message))))
      ((not (official-guided-incumbent-current-p result))
       (emit-message
        (format nil
                "Official-guided evaluator discarded stale generation ~D: evaluated-incumbent-version=~D current=~D."
                generation (getf result :incumbent-version)
                *official-guided-incumbent-version*)))
      ((not (getf result :accepted))
       (emit-message
        (format nil
                "Official-guided challenger rejected: generation=~D stage=~A episodes=~D paired-delta=~,4F margin=~,4F corr=~A paired-var=~,4F independent-var=~,4F."
                generation
                (getf record :stage)
                (getf record :episode-count 0)
                (getf record :paired-mean 0.0d0)
                (getf result :margin 0.0d0)
                (or (getf record :same-seed-correlation) :undefined)
                (getf record :paired-variance 0.0d0)
                (getf record :unpaired-variance 0.0d0))))
      ((not (eq (getf record :stage) :promotion-stage-3))
       (emit-message
        (format nil
                "Official-guided accepted result rejected defensively: generation=~D stage=~A; only final Stage-3 evidence may overwrite the incumbent checkpoint."
                generation (getf record :stage))))
      (t
       (let* ((loaded (load-best-team candidate-path))
              (frozen (deep-copy-team-via-serialization loaded)))
         (ensure-team-observation-compatible frozen *num-observations*)
         (incf *official-guided-incumbent-version*)
         (setf *best-team* frozen
               *best-fitness* (getf record :official-mean)
               *official-guided-best-evaluation* (copy-tree record))
         (emit-message
          (format nil
                  "NEW GLOBAL BEST: generation=~D official-mean=~,4F imitation=~,4F paired-delta=~,4F margin=~,4F episodes=~D."
                  generation *best-fitness*
                  (getf record :imitation-score 0.0d0)
                  (getf record :paired-mean 0.0d0)
                  (getf result :margin 0.0d0)
                  (getf record :episode-count)))
         (let ((*generation* generation))
           (save-best-team)))))
    (when (getf result :reference-monitoring)
      (emit-message
       (format nil "Official reference monitoring (selection-free): ~S"
               (getf result :reference-monitoring))))
    (persist-official-guided-runtime-state)))

(defun poll-official-guided-candidate-evaluation ()
  "Consume one completed Phase-1 worker result without blocking evolution."
  (when *online-candidate-job*
    (let ((result-path (getf *online-candidate-job* :result-path)))
      (cond
        ((probe-file result-path)
         (handler-case
             (consume-official-guided-candidate-result
              (read-readable-object result-path))
           (error (condition)
             (emit-message
              (format nil "Could not consume official-guided result: ~A"
                      condition))))
         (setf *online-candidate-process* nil
               *online-candidate-job* nil))
        ((and *online-candidate-process*
              (not (ignore-errors
                     (uiop:process-alive-p *online-candidate-process*))))
         (emit-message
          (format nil "Official-guided evaluator exited without a result; see ~A"
                  (namestring (getf *online-candidate-job* :log-path))))
         (setf *online-candidate-process* nil
               *online-candidate-job* nil))))))

(defun maybe-launch-official-guided-candidate-evaluation ()
  "Submit the accumulated imitation challenger at the fixed interval."
  (when (and (official-guided-candidate-evaluation-enabled-p)
             (null *online-candidate-job*)
             *online-staged-best-team*
             (>= *generation* *online-candidate-next-submit-generation*))
    (launch-official-guided-candidate-evaluation)))

(defun official-guided-paired-rollouts
       (candidate incumbent environment-name seeds)
  "Evaluate CANDIDATE and INCUMBENT from the same initial seed list."
  (let ((candidate-scores nil)
        (incumbent-scores nil))
    (dolist (seed seeds)
      (push (cl-gym:rollout candidate environment-name seed) candidate-scores)
      (push (cl-gym:rollout incumbent environment-name seed) incumbent-scores))
    (values (nreverse candidate-scores) (nreverse incumbent-scores))))

(defun behavioral-locality-sample-directory ()
  "Return the private directory for passive Phase-2 worker artifacts."
  (checkpoint-path *checkpoint-directory* ".behavioral-locality-samples/"))

(defun behavioral-locality-sample-path (artifact-id kind type)
  "Return one unique passive-sample artifact path."
  (merge-pathnames
   (make-pathname
    :name (format nil "sample-~A-~A" artifact-id kind)
    :type type)
   (uiop:ensure-directory-pathname
    (behavioral-locality-sample-directory))))

(defun cleanup-behavioral-locality-sample-job (job)
  "Remove successful worker artifacts while retaining the compact journal."
  (dolist (path (getf job :artifact-paths))
    (when (and path (probe-file path))
      (ignore-errors (delete-file path)))))

(defun launch-behavioral-locality-sample-evaluation (candidate)
  "Freeze one sampled child/parent pair and start a selection-free worker."
  (let* ((generation *generation*)
         (cursor *behavioral-locality-sample-cursor*)
         (stratum (getf candidate :stratum))
         (artifact-id
           (format nil "~D-c~D-t~D" generation cursor (get-universal-time)))
         (child-path
           (behavioral-locality-sample-path artifact-id "child" "lisp"))
         (parent-path
           (behavioral-locality-sample-path artifact-id "parent" "lisp"))
         (request-path
           (behavioral-locality-sample-path artifact-id "request" "lisp"))
         (result-path
           (behavioral-locality-sample-path artifact-id "result" "lisp"))
         (outcome-path
           (behavioral-locality-sample-path artifact-id "outcome" "lisp"))
         (log-path
           (behavioral-locality-sample-path artifact-id "worker" "log"))
         (worker-script
           (merge-pathnames
            "scripts/run-behavioral-locality-evaluation.lisp"
            (asdf:system-source-directory :cl-tpg)))
         (seeds (behavioral-locality-sample-seeds cursor))
         (sample-id artifact-id))
    (write-official-guided-team-checkpoint
     (getf candidate :child) 0.0d0 generation child-path)
    (write-official-guided-team-checkpoint
     (getf candidate :parent) 0.0d0 generation parent-path)
    (write-readable-object-atomically
     (list :version 1
           :sample-id sample-id
           :generation generation
           :stratum stratum
           :child-path (namestring child-path)
           :parent-path (namestring parent-path)
           :result-path (namestring result-path)
           :outcome-path (namestring outcome-path)
           :gym-environment-name *current-gym-environment-name*
           :num-observations *num-observations*
           :num-actions *num-actions*
           :decoy-order-mode *decoy-order-mode*
           :cage2-opening-mode *cage2-opening-mode*
           :teacher-backend *teacher-backend*
           :seeds seeds
           :behavioral-locality (copy-tree (getf candidate :record)))
     request-path)
    ;; Cursor/count state is persisted before launch, so a crash cannot reuse
    ;; this diagnostic seed block.  It remains independent of Phase-1 streams.
    (note-behavioral-locality-stratum-sample stratum)
    (persist-official-guided-runtime-state)
    (setf *behavioral-locality-sample-process*
            (uiop:launch-program
             (list "sbcl"
                   "--dynamic-space-size" "4096"
                   "--noinform" "--non-interactive"
                   "--load" (namestring worker-script)
                   "--end-toplevel-options"
                   (namestring request-path))
             :input nil
             :output log-path
             :error-output :output
             :if-output-exists :supersede
             :ignore-error-status t)
          *behavioral-locality-sample-job*
            (list :sample-id sample-id
                  :stratum stratum
                  :result-path result-path
                  :log-path log-path
                  :artifact-paths
                    (list child-path parent-path request-path result-path
                          log-path)))
    (emit-message
     (format nil
             "Generation ~D passive locality sample submitted: id=~A stratum=~A episodes=~D."
             generation sample-id stratum (length seeds)))))

(defun poll-behavioral-locality-sample-evaluation ()
  "Observe worker completion without feeding its result into evolution."
  (when *behavioral-locality-sample-job*
    (let ((result-path
            (getf *behavioral-locality-sample-job* :result-path)))
      (cond
        ((probe-file result-path)
         (handler-case
             (let ((result (read-readable-object result-path)))
               (if (eq (getf result :status) :complete)
                   (progn
                     (emit-message
                      (format nil
                              "Passive locality sample completed: id=~A stratum=~A paired-delta=~,4F episodes=~D."
                              (getf result :sample-id)
                              (getf result :stratum)
                              (getf result :paired-mean 0.0d0)
                              (getf result :episode-count 0)))
                     (cleanup-behavioral-locality-sample-job
                      *behavioral-locality-sample-job*))
                   (emit-message
                    (format nil
                            "Passive locality sample failed: ~A; artifacts retained at ~A."
                            (getf result :message)
                            (getf *behavioral-locality-sample-job* :log-path)))))
           (error (condition)
             (emit-message
              (format nil "Could not consume passive locality result: ~A"
                      condition))))
         (setf *behavioral-locality-sample-process* nil
               *behavioral-locality-sample-job* nil))
        ((and *behavioral-locality-sample-process*
              (not (ignore-errors
                     (uiop:process-alive-p
                      *behavioral-locality-sample-process*))))
         (emit-message
          (format nil
                  "Passive locality worker exited without a result; artifacts retained at ~A."
                  (getf *behavioral-locality-sample-job* :log-path)))
         (setf *behavioral-locality-sample-process* nil
               *behavioral-locality-sample-job* nil))))))

(defun maybe-run-behavioral-locality-sampling ()
  "Poll and, when idle, launch one passive stratified official sample."
  (when (behavioral-locality-active-p)
    (handler-case
        (progn
          (poll-behavioral-locality-sample-evaluation)
          (when (null *behavioral-locality-sample-job*)
            (let ((candidate
                    (select-behavioral-locality-sampling-candidate)))
              (when candidate
                (launch-behavioral-locality-sample-evaluation candidate)))))
      (error (condition)
        ;; Diagnostics must never terminate or change the evolutionary search.
        (emit-message
         (format nil "Passive locality sampling skipped after error: ~A"
                 condition))))
    (setf *behavioral-locality-sampling-candidates* nil)))

(defun run-behavioral-locality-sample-evaluation (request-path)
  "Run one frozen child/direct-parent diagnostic comparison in a worker."
  (let* ((request (read-readable-object request-path))
         (result-path (pathname (getf request :result-path)))
         (started (get-universal-time)))
    (labels ((publish (result)
               (write-readable-object-atomically
                (append result
                        (list :elapsed-seconds
                              (- (get-universal-time) started)))
                result-path)))
      (handler-case
          (let* ((*running* t)
                 (*search-active* nil)
                 (*current-search-mode* :official-guided)
                 (*current-gym-environment-name*
                   (getf request :gym-environment-name))
                 (*num-observations* (getf request :num-observations))
                 (*num-actions* (getf request :num-actions))
                 (*decoy-order-mode* (getf request :decoy-order-mode))
                 (*cage2-opening-mode* (getf request :cage2-opening-mode))
                 (*teacher-backend* (getf request :teacher-backend :heuristic))
                 (*recurrent-policy-enabled* nil)
                 (*hamming-space-enabled* nil)
                 (*factored-actions-enabled* t)
                 (child (load-best-team (getf request :child-path)))
                 (parent (load-best-team (getf request :parent-path)))
                 (seeds (getf request :seeds)))
            (ensure-team-observation-compatible child *num-observations*)
            (ensure-team-observation-compatible parent *num-observations*)
            (multiple-value-bind (child-returns parent-returns)
                (official-guided-paired-rollouts
                 child parent *current-gym-environment-name* seeds)
              (let* ((evaluation
                       (append
                        (make-official-guided-evaluation-record
                         :stage :locality-sample
                         :imitation-score nil
                         :seeds seeds
                         :candidate-returns child-returns
                         :incumbent-returns parent-returns
                         :accepted nil)
                        (list :behavioral-locality
                              (copy-tree
                               (getf request :behavioral-locality)))))
                     (outcome
                       (list :type :locality-sample-outcome
                             :protocol +behavioral-locality-protocol+
                             :sample-id (getf request :sample-id)
                             :generation (getf request :generation)
                             :stratum (getf request :stratum)
                             :evaluation evaluation)))
                ;; Each sample owns an immutable atomic outcome file.  This is
                ;; safe even if an orphaned pre-resume worker finishes late.
                (write-readable-object-atomically
                 outcome (getf request :outcome-path))
                (publish
                 (list :status :complete
                       :sample-id (getf request :sample-id)
                       :stratum (getf request :stratum)
                       :paired-mean (getf evaluation :paired-mean)
                       :episode-count (getf evaluation :episode-count))))))
        (error (condition)
          (publish
           (list :status :error
                 :sample-id (getf request :sample-id)
                 :stratum (getf request :stratum)
                 :message (princ-to-string condition)))))))
  t)

(defun run-official-guided-candidate-evaluation (request-path)
  "Worker entry point for frozen Phase-1 official challenger evaluation."
  (let* ((request (read-readable-object request-path))
         (result-path (pathname (getf request :result-path)))
         (started (get-universal-time))
         (parent-child-record nil))
    (labels
        ((publish (result)
           (write-readable-object-atomically
            (append result
                    (list :elapsed-seconds
                          (- (get-universal-time) started)))
            result-path))
         (make-record (stage seeds candidate-scores incumbent-scores accepted)
           (append
            (make-official-guided-evaluation-record
             :stage stage
             :imitation-score (getf request :candidate-imitation-score)
             :seeds seeds
             :candidate-returns candidate-scores
             :incumbent-returns incumbent-scores
             :accepted accepted)
            (list :behavioral-locality
                    (copy-tree (getf request :behavioral-locality))
                  :parent-child-evaluation
                    (copy-tree parent-child-record)))))
      (handler-case
          (let* ((*running* t)
                 (*search-active* nil)
                 (*current-search-mode* :official-guided)
                 (*current-gym-environment-name*
                   (getf request :gym-environment-name))
                 (*num-observations* (getf request :num-observations))
                 (*num-actions* (getf request :num-actions))
                 (*decoy-order-mode* (getf request :decoy-order-mode))
                 (*cage2-opening-mode* (getf request :cage2-opening-mode))
                 (*teacher-backend* (getf request :teacher-backend :model))
                 (*recurrent-policy-enabled* nil)
                 (*hamming-space-enabled* nil)
                 (*factored-actions-enabled* t)
                 (candidate (load-best-team (getf request :candidate-path)))
                 (incumbent (load-best-team (getf request :incumbent-path)))
                 (direct-parent-path (getf request :direct-parent-path))
                 (direct-parent
                   (and direct-parent-path
                        (load-best-team direct-parent-path)))
                 (racing-seeds (getf request :racing-seeds))
                 (promotion-seeds (getf request :promotion-seeds))
                 (promotion-stages (getf request :promotion-stages))
                 (reference-seeds (getf request :reference-seeds)))
            (ensure-team-observation-compatible candidate *num-observations*)
            (ensure-team-observation-compatible incumbent *num-observations*)
            (when direct-parent
              (ensure-team-observation-compatible
               direct-parent *num-observations*))
            (multiple-value-bind (race-candidate race-incumbent)
                (official-guided-paired-rollouts
                 candidate incumbent *current-gym-environment-name* racing-seeds)
              (when direct-parent
                (let ((parent-scores
                        (loop for seed in racing-seeds
                              collect
                              (cl-gym:rollout
                               direct-parent
                               *current-gym-environment-name*
                               seed))))
                  (setf parent-child-record
                        (make-official-guided-parent-child-evaluation-record
                         race-candidate parent-scores racing-seeds
                         (getf request :behavioral-locality)))))
              (multiple-value-bind (continue-p race-delta race-margin)
                  (official-guided-continue-p race-candidate race-incumbent)
                (declare (ignore race-delta))
                (let ((race-record
                        (make-record :racing racing-seeds
                                     race-candidate race-incumbent nil)))
                  (unless continue-p
                    (publish
                     (list :status :complete :accepted nil
                           :candidate-generation
                             (getf request :candidate-generation)
                           :incumbent-version
                             (getf request :incumbent-version)
                           :margin race-margin
                           :evaluation-record race-record))
                    (return-from run-official-guided-candidate-evaluation t))
                  (let ((candidate-scores nil)
                        (incumbent-scores nil)
                        (evaluated-seeds nil)
                        (previous-count 0))
                    (dolist (stage-count promotion-stages)
                      (let ((stage-seeds
                              (subseq promotion-seeds
                                      previous-count stage-count)))
                        (multiple-value-bind (new-candidate new-incumbent)
                            (official-guided-paired-rollouts
                             candidate incumbent
                             *current-gym-environment-name* stage-seeds)
                          (setf candidate-scores
                                (nconc candidate-scores new-candidate)
                                incumbent-scores
                                (nconc incumbent-scores new-incumbent)
                                evaluated-seeds
                                (nconc evaluated-seeds (copy-list stage-seeds))
                                previous-count stage-count)))
                      (let ((final-p
                              (= stage-count (car (last promotion-stages))))
                            (stage
                              (ecase stage-count
                                (12 :promotion-stage-1)
                                (40 :promotion-stage-2)
                                (100 :promotion-stage-3))))
                        (if final-p
                            (multiple-value-bind (accepted delta margin)
                                (official-guided-promote-p
                                 candidate-scores incumbent-scores)
                              (declare (ignore delta))
                              (let* ((record
                                       (make-record stage evaluated-seeds
                                                    candidate-scores
                                                    incumbent-scores accepted))
                                     (reference-monitoring
                                       (when accepted
                                         (multiple-value-bind
                                               (reference-candidate
                                                reference-incumbent)
                                             (official-guided-paired-rollouts
                                              candidate incumbent
                                              *current-gym-environment-name*
                                              reference-seeds)
                                           (make-record
                                            :reference-monitoring
                                            reference-seeds
                                            reference-candidate
                                            reference-incumbent nil)))))
                                (publish
                                 (list :status :complete
                                       :accepted accepted
                                       :candidate-generation
                                         (getf request :candidate-generation)
                                       :incumbent-version
                                         (getf request :incumbent-version)
                                       :margin margin
                                       :racing-record race-record
                                       :evaluation-record record
                                       :reference-monitoring
                                         reference-monitoring))))
                            (multiple-value-bind (continue-p delta margin)
                                (official-guided-continue-p
                                 candidate-scores incumbent-scores)
                              (declare (ignore delta))
                              (unless continue-p
                                (publish
                                 (list :status :complete :accepted nil
                                       :candidate-generation
                                         (getf request :candidate-generation)
                                       :incumbent-version
                                         (getf request :incumbent-version)
                                       :margin margin
                                       :racing-record race-record
                                       :evaluation-record
                                         (make-record
                                          stage evaluated-seeds
                                          candidate-scores incumbent-scores nil)))
                                (return-from
                                    run-official-guided-candidate-evaluation
                                  t)))))))))))
        (error (condition)
          (publish
           (list :status :error :accepted nil
                 :candidate-generation (getf request :candidate-generation)
                 :incumbent-version (getf request :incumbent-version)
                 :message (princ-to-string condition)))))))
  t)

(defun online-fitness (team gym-environment-name)
  "Evaluate TEAM over *ONLINE-FITNESS-EPISODES* complete episodes.

Within one CAGE2 population evaluation, every candidate uses the same episode
seed list. EVALUATE clears the list before each generation, so later
generations receive new episodes instead of repeatedly training on the seed-153
reference batch."
  (unless (and (integerp *online-fitness-episodes*)
               (> *online-fitness-episodes* 0))
    (error "*ONLINE-FITNESS-EPISODES* must be a positive integer."))

  (if (cl-gym:cage2-environment-p gym-environment-name)
      (cage2-fitness-on-seeds
       team
       gym-environment-name
       (or *online-fitness-episode-seeds*
           (setf *online-fitness-episode-seeds*
                 (make-online-fitness-episode-seeds))))
      (arithmetic-mean
       (loop repeat *online-fitness-episodes*
             do (abort-search-if-requested)
             collect
             (cl-gym:rollout team
                             gym-environment-name
                             (random 9999999))))))
            	  
(defun make-fitness-function (&key gym-environment-name dataset-name)
  (cond
    (gym-environment-name
     (setf *factored-actions-enabled*
             (not (null (cl-gym:cage2-environment-p gym-environment-name)))
           *offline-training-dataset* nil
           *offline-reference-dataset* nil
           *teacher-training-dataset* nil
           *teacher-reference-dataset* nil
           *offline-fitness-batch-indices* nil
           *offline-fitness-batch-episode-indices* nil
           *teacher-dagger-replay-rows* nil
           *teacher-dagger-replay-episodes* nil
           *teacher-dagger-random-state* nil
           *current-dataset-fingerprint* nil)
     (when (cl-gym:cage2-environment-p gym-environment-name)
       (configure-cage2-terminal-action-format)
       (when (eq *terminal-action-format* :target-response-36)
         (setf *teacher-backend* :heuristic)))
     (configure-hamming-observation-space)
     (setf *fitness-fn*
           (lambda (team)
             (online-fitness team gym-environment-name))))

    (dataset-name
     (let ((dataset (load-dataset dataset-name)))
       (setf *teacher-training-dataset* nil
             *teacher-reference-dataset* nil
             *teacher-dagger-replay-rows* nil
             *teacher-dagger-replay-episodes* nil
             *teacher-dagger-random-state* nil)
       (setf *factored-actions-enabled*
             (not (null (semantic-dataset-p dataset))))
       (if (semantic-dataset-p dataset)
           (let* ((reference-path
                    (semantic-validation-dataset-path
                     (dataset-source-path dataset)))
                  (reference-file (probe-file reference-path)))
             (unless reference-file
               (error "Semantic validation dataset not found: ~A"
                      (namestring reference-path)))
             (let ((reference-dataset (load-dataset reference-file)))
               (unless (eq (dataset-action-format reference-dataset)
                           (dataset-action-format dataset))
                 (error "Semantic validation path contains a legacy dataset: ~A"
                        (namestring reference-file)))
               (when *recurrent-policy-enabled*
                 (unless (eq (dataset-action-format dataset) :semantic-ranked)
                   (error
                    "Recurrent offline training requires a ranked-v2 semantic dataset."))
                 (ensure-recurrent-dataset-compatible
                  dataset "Recurrent offline training dataset")
                 (ensure-recurrent-dataset-compatible
                  reference-dataset "Recurrent offline reference dataset"))
                (setf *offline-training-dataset* dataset
                     *offline-reference-dataset* reference-dataset
                     *offline-fitness-batch-indices* nil
                     *offline-fitness-batch-episode-indices* nil
                     *current-dataset-fingerprint*
                       (list :training (dataset-file-fingerprint dataset)
                             :reference
                             (dataset-file-fingerprint reference-dataset))
                      *fitness-fn* #'semantic-offline-training-fitness)))
           (progn
             (setf *offline-training-dataset* nil
                   *offline-reference-dataset* nil
                   *offline-fitness-batch-indices* nil
                   *offline-fitness-batch-episode-indices* nil
                   *current-dataset-fingerprint* nil)
              (setf *fitness-fn*
                    (lambda (team)
                      (accuracy team dataset)))))
       (configure-hamming-observation-space
        (and (semantic-dataset-p dataset)
             dataset))))

    (t
     (error "Neither GYM-ENVIRONMENT-NAME nor DATASET-NAME was supplied."))))

(defun configure-fitness-function (mode gym-environment-name dataset-name)
  "Configure *FITNESS-FN* according to MODE."
  (setf *behavioral-locality-enabled* (eq mode :official-guided)
        ;; This branch is the frozen Phase-3 treatment; Phase 2 remains the control.
        *semantic-locality-control-enabled* (eq mode :official-guided)
        *phase4-selection-enabled* (eq mode :official-guided)
        *phase4b-disagreement-audit-enabled* (eq mode :official-guided)
        *phase4b-routing-repair-enabled* (eq mode :official-guided))
  (ecase mode
    (:online
     (make-fitness-function :gym-environment-name gym-environment-name))
    (:offline
     (make-fitness-function :dataset-name dataset-name))
    (:teacher-forcing
     (configure-teacher-forcing-fitness gym-environment-name))
    (:official-guided
     (unless (= *num-observations* +cage2-scan-observation-size+)
       (error "Official-guided Phase 1 requires exactly ~D observations."
              +cage2-scan-observation-size+))
     (unless (= *num-actions* +num-semantic-36-actions+)
       (error "Official-guided direct policy requires exactly ~D target/response actions."
              +num-semantic-36-actions+))
     (unless (and (eq *teacher-forcing-rollout-mode* :dagger)
                  (eq *decoy-order-mode* :fixed)
                  (eq *cage2-opening-mode* :fixed)
                  (eq *teacher-backend* :heuristic)
                  (not *recurrent-policy-enabled*)
                  (not *hamming-space-enabled*))
       (error "Official-guided direct policy requires the heuristic teacher, stateless DAgger, fixed opening/order, and Hamming disabled."))
     (configure-teacher-forcing-fitness gym-environment-name))))

(defun safe-evaluate-team (team)
  (cons team
        (handler-case
            (funcall *fitness-fn* team)

          (floating-point-overflow (e) :bad)
          (floating-point-invalid-operation (e) :bad)
          (division-by-zero (e) :bad)

          (error (e)
            (format t "~&[safe-evaluate-team] ERROR: ~A~%" e)
            #+sbcl (sb-debug:print-backtrace :stream *standard-output*)
            :bad))))
            
(defun evaluate ()
  "Returns a list of (team . fitness), skipping and deleting bad teams."
  (update-online-fitness-stage)
  ;; The first CAGE2 team lazily creates a seed list after this reset. Every
  ;; root team reads that same list; the next population evaluation gets a new
  ;; list generated from the search random state.
  (setf *online-fitness-episode-seeds* nil
        *offline-fitness-batch-indices* nil
        *offline-fitness-batch-episode-indices* nil)
  (when (member *current-search-mode*
                '(:teacher-forcing :official-guided)
                :test #'eq)
    (setf *teacher-training-dataset* nil)
    (prepare-teacher-training-dataset)
    (when (phase4-selection-active-p)
      (prepare-phase4-selection-generation *teacher-training-dataset*)))
  (let* ((results
           (mapcar (lambda (team)
                     (abort-search-if-requested)
                     (safe-evaluate-team team))
                   (root-teams)))
         (bad-teams (loop for (team . fitness) in results
                          when (eq fitness :bad)
                            collect team))
         (good-results (remove :bad results :key #'cdr)))
    ;; Do mutation/deletion serially.
    (dolist (team bad-teams)
      (delete-team team))
    good-results))

(defun current-reference-evaluation (team training-fitness)
  "Return TEAM's comparable historical score for the active fitness protocol."
  (let ((reference-kind
          (cond
            ((eq *current-search-mode* :official-guided)
             :official-guided)
            ((eq *current-search-mode* :teacher-forcing)
             :teacher-forcing)
            ((and *current-gym-environment-name*
                  (cl-gym:cage2-environment-p
                   *current-gym-environment-name*))
             :cage2)
            (*offline-reference-dataset* :offline)
            (t nil))))
    (if (null reference-kind)
        training-fitness
        (let ((started (get-internal-real-time)))
          (emit-message
           (format nil
                   "Generation ~D ~A reference evaluation started."
                   *generation* reference-kind))
          (multiple-value-bind (result detail)
              (ecase reference-kind
                (:official-guided
                 ;; Official comparison is asynchronous and uses fresh seed
                 ;; blocks. This branch only establishes a provisional first
                 ;; incumbent without changing ranked imitation selection.
                 (values training-fitness nil))
                (:teacher-forcing
                 (values (teacher-forcing-reference-fitness team) nil))
                (:cage2
                 (let ((scores
                         (cage2-reference-scores
                          team
                          *current-gym-environment-name*)))
                   (values (arithmetic-mean scores) scores)))
                (:offline
                 (values (semantic-offline-reference-fitness team) nil)))
            (emit-message
             (format nil
                     "Generation ~D ~A reference evaluation finished in ~,2F seconds."
                     *generation*
                     reference-kind
                     (/ (- (get-internal-real-time) started)
                        (coerce internal-time-units-per-second
                                'double-float))))
            (values result detail))))))

(defun current-reference-fitness (team training-fitness)
  "Return only the scalar part of CURRENT-REFERENCE-EVALUATION."
  (nth-value 0 (current-reference-evaluation team training-fitness)))

(defun complexity-key-less-p (left right)
  "Return true when lexicographic complexity key LEFT is smaller than RIGHT."
  (loop for left-value in left
        for right-value in right
        when (< left-value right-value) do (return t)
        when (> left-value right-value) do (return nil)
         finally (return nil)))

(defun phase4-team-group-score (team key)
  "Return TEAM's frozen score for active case KEY."
  (let ((scores (and *phase4-team-group-scores*
                     (gethash team *phase4-team-group-scores*))))
    (multiple-value-bind (score present-p) (and scores (gethash key scores))
      (unless present-p
        (error "Missing Phase-4a score for team ~A case ~S."
               (team-id team) key))
      score)))

(defun phase4-raw-mad (values)
  "Return the raw median absolute deviation of VALUES."
  (if (null values)
      0.0d0
      (let ((median (numeric-median values)))
        (numeric-median
         (mapcar (lambda (value)
                   (abs (- (coerce value 'double-float) median)))
                 values)))))

(defun phase4-compute-group-statistics (scores)
  "Freeze per-case population medians and raw MAD epsilons once."
  (setf *phase4-group-epsilons* (make-hash-table :test #'equal)
        *phase4-group-medians* (make-hash-table :test #'equal))
  (dolist (group *phase4-case-groups*)
    (let* ((key (getf group :key))
           (values
             (mapcar (lambda (entry)
                       (phase4-team-group-score (car entry) key))
                     scores)))
      (setf (gethash key *phase4-group-medians*)
              (numeric-median values)
            (gethash key *phase4-group-epsilons*)
              (phase4-raw-mad values))))
  *phase4-group-epsilons*)

(defun phase4-lexicase-survivors (scores aggregate-champion survivor-count)
  "Choose SURVIVOR-COUNT evaluated roots without replacement by grouped epsilon-lexicase."
  (unless (<= 1 survivor-count (length scores))
    (error "Invalid Phase-4a survivor count ~D for ~D roots."
           survivor-count (length scores)))
  (let ((available (remove aggregate-champion scores :key #'car :test #'eq))
        (selected-others nil)
        (case-keys (mapcar (lambda (group) (getf group :key))
                           *phase4-case-groups*)))
    (loop repeat (1- survivor-count)
          do (let ((candidates (copy-list available)))
               (loop for key across (phase4-shuffled-copy case-keys)
                     while (> (length candidates) 1)
                     do (let ((best
                                (reduce #'max candidates
                                        :key (lambda (entry)
                                               (phase4-team-group-score
                                                (car entry) key))))
                              (epsilon
                                (gethash key *phase4-group-epsilons* 0.0d0)))
                          (setf candidates
                                (remove-if
                                 (lambda (entry)
                                   (< (phase4-team-group-score
                                       (car entry) key)
                                      (- best epsilon
                                         +phase4-selection-numerical-tolerance+)))
                                 candidates))))
               (unless candidates
                 (error "Phase-4a lexicase unexpectedly eliminated every candidate."))
               (let ((winner
                       (nth (phase4-selection-random-below
                             (length candidates))
                            candidates)))
                 (push winner selected-others)
                 (setf available
                       (remove (car winner) available :key #'car :test #'eq)))))
    (cons (assoc aggregate-champion scores :test #'eq)
          (nreverse selected-others))))

(defun phase4-group-behavior-differs-p (team champion group)
  "Return true when TEAM and CHAMPION differ on at least one row in GROUP."
  (let ((team-behavior (gethash team *phase4-team-row-behaviors*))
        (champion-behavior
          (gethash champion *phase4-team-row-behaviors*)))
    (and team-behavior champion-behavior
         (loop for index across (getf group :indices)
               thereis (/= (aref team-behavior index)
                            (aref champion-behavior index))))))

(defun phase4-register-specialists
       (scores sorted old-survivors aggregate-champion survivor-count)
  "Classify case elites and generated rescued specialists before deletion."
  (let* ((old-cutoff-entry (nth (1- survivor-count) sorted))
         (old-cutoff (cdr old-cutoff-entry))
         (case-elite-count 0)
         (generated-case-elite-count 0)
         (rescued-count 0)
         (generated-rescued-count 0)
         (case-elite-records nil)
         (rescued-records nil))
    (dolist (entry scores)
      (let* ((team (car entry))
             (aggregate (cdr entry))
             (parent (behavioral-parent-for-team team))
             (elite-groups nil)
             (rescued-groups nil))
        (dolist (group *phase4-case-groups*)
          (let* ((key (getf group :key))
                 (team-score (phase4-team-group-score team key))
                 (best (reduce #'max scores
                               :key (lambda (candidate)
                                      (phase4-team-group-score
                                       (car candidate) key))))
                 (median (gethash key *phase4-group-medians*))
                 (epsilon (gethash key *phase4-group-epsilons* 0.0d0))
                 (elite-p
                   (>= team-score
                       (- best epsilon
                          +phase4-selection-numerical-tolerance+)))
                 (discriminative-p
                   (> best (+ median
                              +phase4-selection-numerical-tolerance+))))
            (when elite-p
              (push key elite-groups))
            (when (and discriminative-p
                       elite-p
                       (> team-score
                          (+ (phase4-team-group-score
                              aggregate-champion key)
                             +phase4-selection-numerical-tolerance+))
                       (< aggregate
                          (- old-cutoff
                             +phase4-selection-numerical-tolerance+))
                       (phase4-group-behavior-differs-p
                        team aggregate-champion group))
              (push key rescued-groups))))
        (when elite-groups
          (incf case-elite-count)
          (when parent (incf generated-case-elite-count))
          (push (list :team-id (team-id team)
                      :direct-parent-id (and parent (team-id parent))
                      :groups (reverse elite-groups)
                      :aggregate-score aggregate
                      :would-old-scalar-survive
                        (not (null (member team old-survivors
                                           :key #'car :test #'eq))))
                case-elite-records))
        (when rescued-groups
          (incf rescued-count)
          (let ((groups (reverse rescued-groups)))
            (push (list :team-id (team-id team)
                        :direct-parent-id (and parent (team-id parent))
                        :groups groups
                        :group-scores
                          (loop for key in groups
                                collect (cons key
                                              (phase4-team-group-score
                                               team key)))
                        :aggregate-score aggregate
                        :would-old-scalar-survive
                          (not (null (member team old-survivors
                                             :key #'car :test #'eq))))
                  rescued-records)
            (when parent
              (incf generated-rescued-count)
              (let* (
                   (record
                    (list :specialist-id (team-id team)
                          :direct-parent-id (team-id parent)
                          :descendant-ids nil
                          :specialty-groups groups
                          :group-scores
                            (loop for key in groups
                                  collect (cons key
                                                (phase4-team-group-score
                                                 team key)))
                          :aggregate-score aggregate
                          :generation-created *generation*
                          :generation-internalized nil
                          :referencing-root-ids nil
                          :state :generated
                          :lifetime 0
                          :visited-count 0
                          :terminal-winning-count 0
                          :would-old-scalar-survive
                            (not (null (member team old-survivors
                                               :key #'car :test #'eq))))))
              (setf (gethash team *phase4-active-specialists*) record)
              (let ((parent-record
                      (gethash parent *phase4-active-specialists*)))
                (when parent-record
                  (pushnew (team-id team)
                           (getf parent-record :descendant-ids)
                           :test #'equal)))))))))
    (list :old-scalar-cutoff old-cutoff
          :case-elites case-elite-count
          :generated-case-elites generated-case-elite-count
          :case-elite-records (nreverse case-elite-records)
          :rescued-specialists rescued-count
          :generated-rescued-specialists generated-rescued-count
          :rescued-specialist-records (nreverse rescued-records))))

(defun phase4-referencing-roots (team roots)
  "Return IDs of ROOTS whose reachable closure contains TEAM."
  (loop for root in roots
        when (member team (closure root) :test #'eq)
          collect (team-id root)))

(defun phase4-direct-referencing-teams (target)
  "Return IDs of live teams with a direct learner edge to TARGET."
  (loop for team in *teams*
        when (some (lambda (learner)
                     (let ((action (learner-action learner)))
                       (and (eq (action-type action) :reference)
                            (eq (action-action action) target))))
                   (team-learners team))
          collect (team-id team)))

(defun phase4-build-reachability-index (roots)
  "Map every live reachable team to IDs of roots that can reach it."
  (let ((index (make-hash-table :test #'eq)))
    (dolist (root roots index)
      (dolist (team (closure root))
        (pushnew (team-id root) (gethash team index) :test #'equal)))))

(defun phase4-build-direct-reference-index ()
  "Map every directly referenced team to IDs of referring live teams."
  (let ((index (make-hash-table :test #'eq)))
    (dolist (team *teams* index)
      (dolist (learner (team-learners team))
        (let ((action (learner-action learner)))
          (when (eq (action-type action) :reference)
            (pushnew (team-id team)
                     (gethash (action-action action) index)
                     :test #'equal)))))))

(defun phase4-note-specialist-descendant (parent child)
  "Attach every direct reproduced CHILD ID to an active specialist PARENT."
  (let ((record (and *phase4-active-specialists*
                     (gethash parent *phase4-active-specialists*))))
    (when record
      (pushnew (team-id child) (getf record :descendant-ids)
               :test #'equal))))

(defun phase4-update-specialist-lifecycle (stage)
  "Refresh diagnostic specialist state after deletion or reproduction."
  (when *phase4-active-specialists*
    (let* ((roots (root-teams))
           (reachability-index (phase4-build-reachability-index roots))
           (reference-index (phase4-build-direct-reference-index))
          (completed nil)
          (completed-records nil))
      (maphash
       (lambda (team record)
         (let ((live-p (member team *teams* :test #'eq)))
           (setf (getf record :lifetime)
                   (max 0 (1+ (- *generation*
                                 (getf record :generation-created)))))
           (cond
             ((not live-p)
              (setf (getf record :state) :deleted)
              (push (copy-tree record) *phase4-specialist-history*)
              (push (copy-tree record) completed-records)
              (push team completed))
             (t
              (let ((referencing-roots (copy-list
                                         (gethash team reachability-index))))
                (setf (getf record :referencing-root-ids)
                        referencing-roots
                      (getf record :referencing-team-ids)
                        (copy-list (gethash team reference-index))
                      (getf record :state)
                        (cond
                          ((eq (team-type team) :root) :root-survived)
                          (referencing-roots :reachable)
                          (t :internalized)))
                (when (and (not (eq (team-type team) :root))
                           (null (getf record :generation-internalized)))
                  (setf (getf record :generation-internalized)
                          *generation*)))))))
       *phase4-active-specialists*)
      (dolist (team completed)
        (remhash team *phase4-active-specialists*))
      (when *phase4-selection-generation-record*
        (setf (getf *phase4-selection-generation-record*
                    (if (eq stage :post-selection)
                        :specialists-post-selection
                        :specialists-post-reproduction))
              (loop for record being the hash-values
                      of *phase4-active-specialists*
                    collect (copy-tree record)))
        (when completed-records
          (setf (getf *phase4-selection-generation-record*
                      :specialists-completed)
                (append
                 (getf *phase4-selection-generation-record*
                       :specialists-completed)
                 (nreverse completed-records))))))))

(defun persist-phase4-selection-generation-record ()
  "Append the completed Phase-4a selection/lifecycle record."
  (when (and (phase4-selection-active-p)
             *phase4-selection-generation-record*)
    (append-behavioral-locality-form
     (copy-tree *phase4-selection-generation-record*))))

(defun phase4-record-root-accounting (internal-teams-before-selection)
  "Record orphan promotion and the exact post-deletion reproduction pool."
  (let* ((roots-after-deletion (root-teams))
         (orphaned
           (remove-if-not
            (lambda (team)
              (and (member team *teams* :test #'eq)
                   (eq (team-type team) :root)))
            internal-teams-before-selection)))
    (setf (getf *phase4-selection-generation-record*
                :orphaned-internal-root-ids)
            (mapcar #'team-id orphaned)
          (getf *phase4-selection-generation-record*
                :orphaned-internal-root-count)
            (length orphaned)
          (getf *phase4-selection-generation-record*
                :final-root-count-before-reproduction)
            (length roots-after-deletion)
          (getf *phase4-selection-generation-record*
                :reproduction-parent-pool-ids)
            (mapcar #'team-id roots-after-deletion))
    roots-after-deletion))

(defun phase4-selection-delete-entries
       (scores sorted generation-best-team n-remove)
  "Return unselected entries and install the Phase-4a generation record."
  (phase4-compute-group-statistics scores)
  (let* ((survivor-count (- (length sorted) n-remove))
         (old-survivors (subseq sorted 0 survivor-count))
         (selected
           (phase4-lexicase-survivors
            scores generation-best-team survivor-count))
         (selected-teams (mapcar #'car selected))
         (unselected
           (remove-if (lambda (entry)
                        (member (car entry) selected-teams :test #'eq))
                      scores))
         (specialist-summary
           (phase4-register-specialists
            scores sorted old-survivors generation-best-team survivor-count)))
    (setf *phase4-selection-generation-record*
          (append
           (list :record-type :phase4a-selection
                 :protocol +phase4-selection-protocol+
                 :generation *generation*
                 :selection-age *phase4-selection-age*
                 :active-groups
                   (mapcar (lambda (group)
                           (list :key (copy-tree (getf group :key))
                                 :rows (length (getf group :indices))
                                 :median
                                   (gethash (getf group :key)
                                            *phase4-group-medians*)
                                 :epsilon-raw-mad
                                   (gethash (getf group :key)
                                            *phase4-group-epsilons*)
                                 :population-best-score
                                   (reduce #'max scores
                                           :key
                                           (lambda (entry)
                                             (phase4-team-group-score
                                              (car entry)
                                              (getf group :key))))
                                 :aggregate-champion-score
                                   (phase4-team-group-score
                                    generation-best-team (getf group :key))
                                 :aggregate-champion-exact-rate
                                   (gethash
                                    (getf group :key)
                                    (gethash
                                     generation-best-team
                                     *phase4-team-group-exact-rates*))
                                 :aggregate-champion-disagreement-rate
                                   (- 1.0d0
                                      (gethash
                                       (getf group :key)
                                       (gethash
                                        generation-best-team
                                        *phase4-team-group-exact-rates*)))))
                           *phase4-case-groups*)
                 :evaluated-roots (length scores)
                 :intended-survivors survivor-count
                 :lexicase-selected-evaluated-roots (length selected)
                 :aggregate-champion-id (team-id generation-best-team)
                 :selected-evaluated-root-ids (mapcar #'team-id selected-teams)
                 :old-scalar-survivor-ids
                   (mapcar (lambda (entry) (team-id (car entry)))
                           old-survivors))
           specialist-summary))
    (incf *phase4-selection-age*)
    unselected))

(defun select (scores)
  "Remove GAP percent of the population by removing the worst teams.

Maintain a frozen deep copy of the historical best team. Whenever a new
global best is discovered, immediately deep-copy the complete TPG graph
through serialization/deserialization and save it to disk."

  (unless scores
    (error "Cannot select from an empty score list."))

  (let* ((complexities (make-hash-table :test #'eq))
         (sorted
           (progn
             (dolist (entry scores)
               (setf (gethash (car entry) complexities)
                     (policy-complexity-key (car entry))))
             (stable-sort
              (copy-list scores)
              (lambda (left right)
                (let ((left-fitness (cdr left))
                      (right-fitness (cdr right)))
                  (if (= left-fitness right-fitness)
                      (complexity-key-less-p
                       (gethash (car left) complexities)
                       (gethash (car right) complexities))
                      (> left-fitness right-fitness)))))))

         (fitness-values
           (mapcar #'cdr sorted))

         (n-remove
           (floor (* *gap* (length sorted))))

         (worst-entries
           (if (> n-remove 0)
               (last sorted n-remove)
               nil))

         (best-entry
           (first sorted))

         (generation-best
           (cdr best-entry))

         (generation-best-team
           (car best-entry))

         (historical-candidate-fitness nil)

         (historical-candidate-detail nil)

         (population-mean
           (arithmetic-mean fitness-values))

         (population-median
           (numeric-median fitness-values))

         (population-worst
           (reduce #'min
                   fitness-values
                   :initial-value
                   most-positive-double-float))
         (staged-online-p
           (online-candidate-evaluation-enabled-p))
         (staged-guided-p
           (official-guided-candidate-evaluation-enabled-p))
         (staged-candidate-p (or staged-online-p staged-guided-p))
         (internal-teams-before-selection
           (remove-if-not (lambda (team)
                            (eq (team-type team) :internal))
                          *teams*)))

    ;; DAgger follows the evolving learner distribution, not the protected
    ;; official incumbent.  The independent snapshot is consumed next
    ;; generation and cannot be mutated by selection or reproduction.
    (when (and (official-guided-mode-p)
               (eq *teacher-forcing-rollout-mode* :dagger))
      (install-teacher-dagger-behavior-team
       generation-best-team generation-best *generation*))

    (cond
      (staged-guided-p
       (poll-official-guided-candidate-evaluation)
       (note-online-generation-candidate
        generation-best-team generation-best)
       (maybe-launch-official-guided-candidate-evaluation))
      (staged-online-p
       (poll-online-candidate-evaluation)
       (note-online-generation-candidate
        generation-best-team generation-best)
       (maybe-launch-online-candidate-evaluation)))

    (unless staged-candidate-p
      (multiple-value-setq
          (historical-candidate-fitness historical-candidate-detail)
        (current-reference-evaluation
         generation-best-team
         generation-best))

      ;; Non-online modes retain synchronous reference selection. The first
      ;; generation of a fresh online run also establishes its incumbent here;
      ;; later online candidates go through the independent staged worker.
      (multiple-value-bind (promotion-p mean-difference promotion-margin)
          (if (and (eq *current-search-mode* :online)
                   (cl-gym:cage2-environment-p
                    *current-gym-environment-name*)
                   *best-fitness*)
              (online-reference-promotion-p
               historical-candidate-detail
               *online-best-reference-scores*)
              (values (or (null *best-fitness*)
                          (> historical-candidate-fitness *best-fitness*))
                      nil
                      nil))
        (when (and *best-fitness*
                   (> historical-candidate-fitness *best-fitness*)
                   (not promotion-p))
          (emit-message
           (format nil
                   "Online best promotion rejected as noise: candidate=~A incumbent=~A paired-delta=~,4F required-margin=~,4F."
                   historical-candidate-fitness
                   *best-fitness*
                   mean-difference
                   promotion-margin)))

        (when promotion-p

          (let ((frozen-best-team
                  (deep-copy-team-via-serialization
                   generation-best-team)))

            (setf *best-fitness* historical-candidate-fitness
                  *best-team* frozen-best-team
                  *online-best-reference-scores*
                    (and historical-candidate-detail
                         (copy-list historical-candidate-detail)))

            (when (official-guided-mode-p)
              (incf *official-guided-incumbent-version*)
              (setf *official-guided-best-evaluation*
                    (list :protocol +official-guided-fitness-protocol+
                          :stage :provisional
                          :accepted t
                          :imitation-score generation-best
                          :episode-count 0)))

            (emit-message
             (format nil
                     "NEW GLOBAL BEST: generation=~A reference-fitness=~A training-fitness=~A. "
                     *generation*
                     *best-fitness*
                     generation-best))

            ;; Save immediately, before reproduce/mutation/deletion.
            (when *checkpoint-directory*
              (save-best-team)
              (when (official-guided-mode-p)
                (persist-official-guided-runtime-state)))))))

    ;; ------------------------------------------------------------
    ;; Telemetry
    ;; ------------------------------------------------------------

    (multiple-value-bind
          (team-count learner-count instruction-count
           max-team-size max-program-size)
        (teams-complexity *teams*)
      (emit-fitness-scores
       (telemetry-island-id)
       generation-best
       *best-fitness*
       population-mean
       population-median
       population-worst
       *generation*
       :online-fitness-episodes *online-fitness-episodes*
       :team-count team-count
       :learner-count learner-count
       :instruction-count instruction-count
       :max-team-size max-team-size
       :max-program-size max-program-size
       :elapsed-seconds
         (and *search-start-time*
              (- (get-universal-time) *search-start-time*))))

    ;; ------------------------------------------------------------
    ;; Selection
    ;; ------------------------------------------------------------

    (when (phase4-selection-active-p)
      (setf worst-entries
            (phase4-selection-delete-entries
             scores sorted generation-best-team n-remove)))
    (dolist (entry worst-entries)
      (delete-team (car entry)))
    (when (phase4-selection-active-p)
      (phase4-record-root-accounting internal-teams-before-selection)
      (phase4-update-specialist-lifecycle :post-selection)
      (emit-message
       (format nil
               "Generation ~D Phase-4a selection: selected=~D rescued-generated=~D orphan-roots=~D parent-pool=~D."
               *generation*
               (getf *phase4-selection-generation-record*
                     :lexicase-selected-evaluated-roots)
               (getf *phase4-selection-generation-record*
                     :generated-rescued-specialists)
               (getf *phase4-selection-generation-record*
                     :orphaned-internal-root-count)
               (getf *phase4-selection-generation-record*
                     :final-root-count-before-reproduction))))
    (when (behavioral-locality-active-p)
      (prune-behavioral-team-lineage))))

(defun should-send-migrants-p ()
  "Returns T periodically when the generation matches the migration interval."
  (and (> *generation* 0)
       (= (mod *generation* *migration-interval*) 0)))

(defun send-migrants (evaluation-scores)
  "Periodically send the best individual from this island to another island."
  (let* ((island-id (who-am-i))
	 (neighbours (get-neighbour-ids island-id)))
    (when neighbours
      (let ((random-neighbour (random-choice neighbours))
	    (best-individual (car (alexandria:extremum evaluation-scores #'> :key #'cdr))))
	(send-migrant-over-socket random-neighbour best-individual)))))

(defun receive-migrants ()
  "Replaces the worst individuals unless the migration buffer
   exceeds the population size (albeit unlikely) in which case
   it simply adds them all to the population."

  ;; Internal teams are added unconditionally
  (loop for internal-team = (pop-internal-team)
	while internal-team
	do (push internal-team *teams*))

  ;; Root teams compete for the 'worst' slots.
  (loop for root-team = (pop-root-team)
	while root-team
	do (push root-team *teams*)))

(defun reproduce-native-child (parent)
  "Create one child through the unchanged native/Phase-3 mutation path."
  (if (semantic-locality-control-active-p)
      (mutate-team-with-semantic-locality-control parent)
      (let ((child (clone-team parent)))
        (let ((*active-mutation-events* nil))
          (mutate-team child)
          (record-behavioral-mutation
           parent child (nreverse *active-mutation-events*)))
        child)))

(defun reproduce ()
  "Refill roots with mostly native mutation plus a small targeted quota."
  (setf *phase4b-routing-repair-generation-records* nil)
  (loop while (< (length (root-teams)) *population-size*)
        do (let* ((parents (root-teams))
                  (targeted-p
                    (and (phase4b-routing-repair-active-p)
                         (phase4b-routing-repair-slot-p))))
             (multiple-value-bind (repair-child repair-parent)
                 (if targeted-p
                     (phase4b-attempt-routing-repair parents)
                     (values nil nil))
               (let* ((parent
                        (or repair-parent (random-choice parents)))
                      (child
                        (or repair-child
                            (reproduce-native-child parent))))
                 (when (phase4-selection-active-p)
                   (phase4-note-specialist-descendant parent child))))))
  (when (phase4-selection-active-p)
    (phase4-update-specialist-lifecycle :post-reproduction)
    (persist-phase4-selection-generation-record))
  (finish-phase4b-routing-repair-generation)
  (persist-behavioral-generation-records)
  (finish-semantic-locality-control-generation))

(defun evolve ()
  "Evolve the population for a single generation."
  (abort-search-if-requested)
  (receive-migrants)

  (let ((evaluation-scores (evaluate)))

    ;; Do not select, checkpoint, migrate, or reproduce a partially evaluated
    ;; generation after the user has requested that the search stop.
    (abort-search-if-requested)

    (when (should-send-migrants-p)
      (send-migrants evaluation-scores))

    (select evaluation-scores)

    ;; Observe survivor diversity before reproduction adds new offspring.  This
    ;; is diagnostic only and consumes no random state.
    (persist-population-behavioral-diversity :post-selection)
    
    (reproduce)
    (maybe-run-behavioral-locality-sampling)
    (when (official-guided-mode-p)
      (persist-official-guided-runtime-state))))

(defun run-search (mode gym-environment-name dataset-name seed)
  "Search the solution space with a tangled program graph."
  (let* ((seed (seed-or-random-seed seed))
         (captured-state (sb-ext:seed-random-state seed)))
    (setf *random-state* captured-state
          *current-search-mode* mode
          *current-gym-environment-name* gym-environment-name
          *current-search-seed* seed
          *current-dataset-name* (and (eq mode :offline) dataset-name)
          *mixed-training-lineage* nil
          *online-best-reference-scores* nil
          *official-guided-last-evaluation* nil
          *official-guided-best-evaluation* nil
          *official-guided-incumbent-version* 0
          *search-start-time* (get-universal-time))

    (catch 'search-stop-requested
      (setf *teams* nil)
      (setf *generation* 1)
      (reset-online-candidate-evaluation-state)
      (reset-behavioral-locality-state)
      (setf *best-team* nil)
      (setf *best-fitness* nil)

      (when (official-guided-mode-p)
        (initialize-official-guided-seed-streams seed))

      (configure-fitness-function mode gym-environment-name dataset-name)
      (when (phase4-selection-active-p)
        (initialize-phase4-selection-state seed)
        (reset-phase4-selection-runtime))
      (when (phase4b-routing-repair-active-p)
        (initialize-phase4b-routing-repair-state seed))
      (make-initial-population)

      (when (and (official-guided-mode-p)
                 (eq *teacher-forcing-rollout-mode* :dagger))
        (install-teacher-dagger-behavior-team
         (first (root-teams)) nil 0))

      (loop while *running*
            do (evolve)
            do (incf *generation*)))))

(defun inject-loaded-best-team-into-population (loaded-best-team)
  "Replace the first root team in a freshly initialized population with LOADED-BEST-TEAM."
  (unless loaded-best-team
    (error "Cannot inject best team: LOADED-BEST-TEAM is NIL."))

  ;; Ensure the loaded team is a root candidate before computing closure.
  (setf (team-type loaded-best-team) :root
        (team-references loaded-best-team) 0)

  (let* ((loaded-closure (closure loaded-best-team))
         (random-roots (root-teams)))

    (unless random-roots
      (error "Cannot inject best team: no root teams exist in the current population."))

    ;; Fresh population contains only random root teams. Drop the first one and
    ;; prepend the loaded best team's full closure.
    (setf *teams*
          (append loaded-closure
                  (rest random-roots)))

    loaded-best-team))
					     
(defun checkpoint-fitness-comparable-p
       (fitness metadata gym-environment-name)
  "Return true when saved FITNESS can be retained for this resumed search.

Known environment or fitness-episode metadata must match.  Missing provenance
is accepted for legacy non-CAGE2 checkpoints. CAGE2 requires its reproducible
seed protocol. Semantic offline checkpoints require the current protocol and
the same train/reference file fingerprint."
  (and (numberp fitness)
       (let ((saved-environment
               (getf metadata :gym-environment-name))
             (saved-episodes
               (getf metadata :online-fitness-episodes))
             (saved-protocol
               (getf metadata :fitness-evaluation-protocol))
             (saved-online-reference-episodes
               (getf metadata :online-reference-episodes))
             (saved-dataset-fingerprint
               (getf metadata :dataset-fingerprint))
              (saved-agreement-signature
                (getf metadata :action-agreement-signature))
              (saved-hamming-enabled
                (not (null (getf metadata :hamming-space-enabled))))
              (saved-hamming-fingerprint
                (getf metadata :hamming-dataset-fingerprint))
              (saved-num-observations
                (getf metadata :num-observations))
              (saved-terminal-action-format
                (or (getf metadata :terminal-action-format) :factored))
              (saved-decoy-order-mode
                (getf metadata :decoy-order-mode))
              (saved-opening-mode
                ;; Checkpoints before v11 used TPG from step 0.
                (or (getf metadata :cage2-opening-mode) :policy))
              (saved-recurrent-enabled
                ;; Checkpoints before v13 always cleared registers per bid.
                (not (null (getf metadata :recurrent-policy-enabled))))
              (saved-teacher-backend
                ;; Checkpoints before v14 used the packaged model profile.
                (or (getf metadata :teacher-backend) :model)))
          (and (or (null saved-environment)
                   (equal saved-environment gym-environment-name))
               (or (null saved-num-observations)
                   (= saved-num-observations *num-observations*))
               (eq saved-terminal-action-format *terminal-action-format*)
               (or (null saved-decoy-order-mode)
                   (eq saved-decoy-order-mode *decoy-order-mode*))
               (or (not (or *recurrent-policy-enabled*
                            (cl-gym:cage2-environment-p
                             gym-environment-name)))
                   (eq saved-opening-mode *cage2-opening-mode*))
               (eq saved-recurrent-enabled
                   (not (null *recurrent-policy-enabled*)))
               (eq saved-teacher-backend *teacher-backend*)
               (eq saved-hamming-enabled
                   (not (null *hamming-space-enabled*)))
               (or (not *hamming-space-enabled*)
                   (equal saved-hamming-fingerprint
                          *current-hamming-dataset-fingerprint*))
               (cond
                ((eq *current-search-mode* :official-guided)
                 (and (eq saved-protocol
                          +official-guided-fitness-protocol+)
                      (equal saved-agreement-signature
                             (action-agreement-signature))))
                ((eq *current-search-mode* :teacher-forcing)
                 (and (or (null saved-episodes)
                          (= saved-episodes *online-fitness-episodes*))
                      (eq saved-protocol
                          (teacher-forcing-fitness-protocol))
                      (equal saved-agreement-signature
                             (action-agreement-signature))))
                ((cl-gym:cage2-environment-p gym-environment-name)
                 (and (eq saved-protocol
                          +cage2-online-fitness-protocol+)
                      (= (or saved-online-reference-episodes 0)
                         +cage2-online-reference-episodes+)
                      (equal saved-agreement-signature
                             (action-agreement-signature))))
                (*offline-reference-dataset*
                 (and (eq saved-protocol
                           (semantic-offline-fitness-protocol))
                      (equal saved-dataset-fingerprint
                             *current-dataset-fingerprint*)
                      (equal saved-agreement-signature
                             (action-agreement-signature))))
                (t
                 t))))))

(defun fitness-values-equivalent-p (left right)
  "Return true when two replayed fitness values agree to floating-point noise."
  (and (numberp left)
       (numberp right)
       (<= (abs (- (coerce left 'double-float)
                   (coerce right 'double-float)))
           1.0d-9)))

(defun initialize-best-from-current-population
       (loaded-best-team &optional saved-best-fitness)
  "Evaluate the warm-start population and initialize historical-best state.

Generation scores use a new shared training batch. Historical-best comparisons
use the active fixed CAGE2 seed bank or held-out semantic dataset, so a resumed
checkpoint remains replayable while training continues on changing batches."
  (let* ((scores (evaluate))
         (best-entry (and scores
                          (first (sort (copy-list scores) #'> :key #'cdr))))
         (loaded-entry (assoc loaded-best-team scores :test #'eq)))
    (unless best-entry
      (error "Warm-start evaluation failed: no valid teams after evaluation."))

    (unless loaded-entry
      (error "Warm-start evaluation did not include the loaded best team."))

    (let* ((generation-best-team (car best-entry))
           (generation-best-fitness (cdr best-entry))
           (loaded-current-fitness (cdr loaded-entry))
           (loaded-reference-fitness nil)
           (loaded-reference-detail nil)
           (generation-reference-fitness nil)
           (generation-reference-detail nil))
      (multiple-value-setq
          (loaded-reference-fitness loaded-reference-detail)
        (current-reference-evaluation
         loaded-best-team
         loaded-current-fitness))
      (if (eq generation-best-team loaded-best-team)
          (setf generation-reference-fitness loaded-reference-fitness
                generation-reference-detail loaded-reference-detail)
          (multiple-value-setq
              (generation-reference-fitness generation-reference-detail)
            (current-reference-evaluation
             generation-best-team
             generation-best-fitness)))
      (when (and (numberp saved-best-fitness)
                 (not (fitness-values-equivalent-p
                       saved-best-fitness
                       loaded-reference-fitness)))
        (error
         "Warm-start checkpoint reference fitness did not replay: saved=~A current=~A. Refusing to hide a policy/evaluation mismatch."
         saved-best-fitness
         loaded-reference-fitness))

      (let* ((loaded-baseline
               (or saved-best-fitness loaded-reference-fitness))
             (generation-won-p
               (if (and (eq *current-search-mode* :online)
                        (cl-gym:cage2-environment-p
                         *current-gym-environment-name*))
                   (online-reference-promotion-p
                    generation-reference-detail
                    loaded-reference-detail)
                   (> generation-reference-fitness loaded-baseline)))
             (chosen-team
               (if generation-won-p
                   generation-best-team
                   loaded-best-team))
             (chosen-fitness
               (if generation-won-p
                   generation-reference-fitness
                   loaded-baseline)))
        (setf *best-team*
                (deep-copy-team-via-serialization chosen-team)
              *best-fitness* chosen-fitness
              *online-best-reference-scores*
                (copy-list
                 (if generation-won-p
                     generation-reference-detail
                     loaded-reference-detail)))

        (emit-message
         (format nil
                 "Warm-start reference comparison: retained=~A saved=~A loaded-reference=~A generation-training=~A generation-reference=~A"
                 (if generation-won-p :generation-best :loaded-best)
                 saved-best-fitness
                 loaded-reference-fitness
                 generation-best-fitness
                 generation-reference-fitness))

        ;; Rewrite legacy/old-protocol checkpoints immediately with the current
        ;; replayable reference score, or save a better generation candidate.
        (when *checkpoint-directory*
          (save-best-team))))

    scores))

(defun ensure-official-guided-incumbent-checkpoint ()
  "Create the run-local incumbent checkpoint once, never overwrite it here.

Only a challenger that passes final Stage-3 promotion may subsequently call
SAVE-BEST-TEAM on this path.  This prevents warm-start/resume bookkeeping from
rewriting a protected on-disk incumbent."
  (let ((destination (best-team-checkpoint-path)))
    (cond
      ((probe-file destination)
       (emit-message
        (format nil
                "Protected existing warm-start incumbent checkpoint (not overwritten): ~A"
                (namestring destination)))
       :preserved)
      (t
       (save-best-team destination)
       :created))))

(defun initialize-official-guided-best-from-current-population
       (loaded-best-team saved-best-fitness checkpoint-metadata)
  "Install LOADED-BEST-TEAM as the official incumbent without imitation takeover.

The fresh population is still evaluated on ranked imitation, but no randomly
initialized team may replace the incumbent until it passes independent official
racing and all three fresh promotion stages."
  ;; Install the frozen graph before EVALUATE so the very first resumed DAgger
  ;; trajectory has an explicit independent owner.  A recovered behavior
  ;; snapshot takes precedence; otherwise seed it from another deep copy of the
  ;; loaded incumbent rather than sharing *BEST-TEAM*.
  (setf *best-team* (deep-copy-team-via-serialization loaded-best-team)
        *best-fitness* saved-best-fitness)
  (unless *teacher-dagger-behavior-team-snapshot*
    (install-teacher-dagger-behavior-team
     *best-team* nil 0 :announce nil))
  (let* ((scores (evaluate))
         (loaded-entry (assoc loaded-best-team scores :test #'eq))
         (best-entry
           (first
            (stable-sort
             (copy-list scores)
             (lambda (left right)
               (if (= (cdr left) (cdr right))
                   (complexity-key-less-p
                    (policy-complexity-key (car left))
                    (policy-complexity-key (car right)))
                   (> (cdr left) (cdr right))))))))
    (unless loaded-entry
      (error "Official-guided warm start did not evaluate the loaded team."))
    (unless best-entry
      (error "Official-guided warm start produced no valid imitation champion."))
    (install-teacher-dagger-behavior-team
     (car best-entry) (cdr best-entry) *generation*)
    (setf *best-fitness* (or saved-best-fitness (cdr loaded-entry))
          *official-guided-incumbent-version*
            (max 1
                 *official-guided-incumbent-version*
                 (or (getf checkpoint-metadata
                           :official-guided-incumbent-version)
                     0))
          *official-guided-best-evaluation*
            (or *official-guided-best-evaluation*
                (copy-tree
                 (getf checkpoint-metadata
                       :official-guided-best-evaluation))
                (list :protocol +official-guided-fitness-protocol+
                      :stage :imported-incumbent
                      :accepted t
                      :imitation-score (cdr loaded-entry)
                      :official-mean
                        (and (numberp saved-best-fitness)
                             saved-best-fitness)
                      :episode-count 0)))
    (emit-message
     (format nil
             "Official-guided warm start retained loaded incumbent: saved-score=~A current-imitation=~,4F incumbent-version=~D."
             saved-best-fitness (cdr loaded-entry)
             *official-guided-incumbent-version*))
    (when *checkpoint-directory*
      (ensure-official-guided-incumbent-checkpoint)
      (persist-official-guided-runtime-state))
    scores))

(defun run-search-from-best-team
       (mode gym-environment-name dataset-name seed best-team-path)
  "Warm-start search from a saved best team.

This does not restore the old population. Each island creates a fresh random
population, loads its own saved best team, replaces the first root team with it,
evaluates the resulting population once, initializes *BEST-TEAM*, then continues
normal evolution."
  (let* ((seed (seed-or-random-seed seed))
         (captured-state (sb-ext:seed-random-state seed)))
    (setf *random-state* captured-state
          *current-search-mode* mode
          *current-gym-environment-name* gym-environment-name
          *current-search-seed* seed
          *current-dataset-name* (and (eq mode :offline) dataset-name)
          *mixed-training-lineage* nil
          *online-best-reference-scores* nil
          *official-guided-last-evaluation* nil
          *official-guided-best-evaluation* nil
          *official-guided-incumbent-version* 0
          *search-start-time* (get-universal-time))

    (catch 'search-stop-requested
      ;; Fresh island-local state.
      (setf *teams* nil)
      (setf *generation* 1)
      (reset-online-candidate-evaluation-state)
      (reset-behavioral-locality-state)
      (setf *best-team* nil)
      (setf *best-fitness* nil)

      (when (official-guided-mode-p)
        (initialize-official-guided-seed-streams seed))

      ;; Configure the action contract before creating random learners.
      (configure-fitness-function mode gym-environment-name dataset-name)
      (when (phase4-selection-active-p)
        (initialize-phase4-selection-state seed)
        (reset-phase4-selection-runtime))
      (when (phase4b-routing-repair-active-p)
        (initialize-phase4b-routing-repair-state seed))

      ;; Build fresh random population for this island.
      (make-initial-population)

      ;; Load and inject this island's best team.  Versioned checkpoints retain
      ;; their historical score when the environment and episode count match.
      (multiple-value-bind
            (loaded-best-team saved-best-fitness checkpoint-metadata)
          (load-best-team best-team-path)
        (ensure-team-observation-compatible
         loaded-best-team *num-observations*)
        (when (official-guided-mode-p)
          (restore-official-guided-runtime-state
           checkpoint-metadata best-team-path))
        (inject-loaded-best-team-into-population loaded-best-team)
        (emit-policy-limit-warning loaded-best-team)

        (setf *mixed-training-lineage*
              (and (eq mode :online)
                   (or (getf checkpoint-metadata
                             :mixed-training-lineage)
                       (getf checkpoint-metadata :dataset-name)
                       (member
                        (getf checkpoint-metadata
                              :fitness-evaluation-protocol)
                         (list +teacher-forcing-teacher-protocol+
                              +teacher-forcing-dagger-protocol+
                              +teacher-forcing-recurrent-teacher-protocol+
                              +teacher-forcing-recurrent-dagger-protocol+)
                        :test #'eq))))

        (let ((comparable-fitness
                (and (checkpoint-fitness-comparable-p
                      saved-best-fitness
                      checkpoint-metadata
                      gym-environment-name)
                     saved-best-fitness)))
          (when (and saved-best-fitness (null comparable-fitness))
            (emit-message
             (format nil
                     "Warm-start: saved fitness ~A is not comparable with env=~A episodes=~A; re-baselining."
                     saved-best-fitness
                     gym-environment-name
                     *online-fitness-episodes*)))

          ;; Official-guided resume must never let imitation alone replace the
          ;; official incumbent. Other modes retain the historical behavior.
          (if (official-guided-mode-p)
              (initialize-official-guided-best-from-current-population
               loaded-best-team
               (or saved-best-fitness comparable-fitness)
               checkpoint-metadata)
              (initialize-best-from-current-population
               loaded-best-team
               comparable-fitness))))

      ;; Continue normal BES/TPG evolution.
      (loop while *running*
            do (evolve)
            do (incf *generation*)))))


(defun validate-best-team-online (best-team-path gym-environment-name)
  "Load BEST-TEAM-PATH and validate it in GYM-ENVIRONMENT-NAME."
  (let* ((cage2-p (cl-gym:cage2-environment-p gym-environment-name))
         (*random-state*
           (if cage2-p
               (sb-ext:seed-random-state +cage2-evaluation-seed+)
               *random-state*)))
    (let* ((team (load-best-team best-team-path))
           (score (cl-gym:cl-gym-validate-team
                   team
                   gym-environment-name
                   (random 9999999))))
      (emit-message
       (format nil
               "Validation finished. Env=~A BestTeam=~A Score=~A"
               gym-environment-name
               best-team-path
               score))
      score)))
