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

(defun semantic-action-label-matches-p (prediction label)
  "Compare PREDICTION with a canonical (target response option) LABEL.

GLOBAL requires only the target. Host non-Decoy labels require target and
response; Decoy additionally requires the option. This mirrors the runtime
semantic contract and never penalizes fields ignored by the bridge."
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
                                (semantic-action-option prediction)))
                          (and (integerp predicted-option)
                               (= predicted-option option))))))))))

(defun semantic-accuracy (team dataset &optional indices)
  "Return strict hierarchical semantic accuracy for TEAM on DATASET.

When INDICES is supplied, evaluate only those rows. Sampling remains outside
this function so an entire population can share exactly the same batch."
  (let ((correct 0)
        (count 0)
        (observations (observations dataset))
        (labels (actions dataset)))
    (labels ((score-row (index)
               ;; Reference scoring can cover tens of thousands of rows. Check
               ;; periodically so a stop request does not wait for the complete
               ;; held-out dataset to finish.
               (when (and *search-active*
                          (zerop (logand count 255)))
                 (abort-search-if-requested))
               (when (semantic-action-label-matches-p
                      (execute-team-semantic team (aref observations index))
                      (aref labels index))
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

(defun semantic-offline-training-fitness (team)
  "Evaluate TEAM on the uniform row batch shared by this generation."
  (unless *offline-training-dataset*
    (error "Semantic offline training dataset is not configured."))
  (unless *offline-fitness-batch-indices*
    (setf *offline-fitness-batch-indices*
          (or (make-uniform-dataset-indices *offline-training-dataset*)
              :all)))
  (semantic-accuracy
   team
   *offline-training-dataset*
   (unless (eq *offline-fitness-batch-indices* :all)
     *offline-fitness-batch-indices*)))

(defun semantic-offline-reference-fitness (team)
  "Evaluate TEAM on the complete fixed held-out semantic dataset."
  (unless *offline-reference-dataset*
    (error "Semantic offline reference dataset is not configured."))
  (semantic-accuracy team *offline-reference-dataset*))

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

(defun make-online-fitness-episode-seeds (&optional root-seed)
  "Return one seed per online-fitness episode.

With ROOT-SEED, derive a reproducible seed bank without consuming the search
random state. Without it, consume the search random state so each generation
receives a new batch."
  (unless (and (integerp *online-fitness-episodes*)
               (> *online-fitness-episodes* 0))
    (error "*ONLINE-FITNESS-EPISODES* must be a positive integer."))

  (let ((*random-state*
          (if root-seed
              (sb-ext:seed-random-state root-seed)
              *random-state*)))
    (loop repeat *online-fitness-episodes*
          collect (random 9999999))))

(defun cage2-fitness-on-seeds (team gym-environment-name episode-seeds)
  "Evaluate TEAM on the exact CAGE2 EPISODE-SEEDS and return mean reward."
  (arithmetic-mean
   (loop for episode-seed in episode-seeds
         do (abort-search-if-requested)
         collect
         (cl-gym:rollout team gym-environment-name episode-seed))))

(defun cage2-reference-fitness (team gym-environment-name)
  "Evaluate TEAM on the fixed checkpoint/reference seed bank rooted at 153."
  (cage2-fitness-on-seeds
   team
   gym-environment-name
   (make-online-fitness-episode-seeds +cage2-evaluation-seed+)))

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
     (setf *offline-training-dataset* nil
           *offline-reference-dataset* nil
           *offline-fitness-batch-indices* nil
           *current-dataset-fingerprint* nil)
     (setf *fitness-fn*
           (lambda (team)
             (online-fitness team gym-environment-name))))

    (dataset-name
     (let ((dataset (load-dataset dataset-name)))
       (if (eq (dataset-action-format dataset) :semantic)
           (let* ((reference-path
                    (semantic-validation-dataset-path
                     (dataset-source-path dataset)))
                  (reference-file (probe-file reference-path)))
             (unless reference-file
               (error "Semantic validation dataset not found: ~A"
                      (namestring reference-path)))
             (let ((reference-dataset (load-dataset reference-file)))
               (unless (eq (dataset-action-format reference-dataset) :semantic)
                 (error "Semantic validation path contains a legacy dataset: ~A"
                        (namestring reference-file)))
               (setf *offline-training-dataset* dataset
                     *offline-reference-dataset* reference-dataset
                     *offline-fitness-batch-indices* nil
                     *current-dataset-fingerprint*
                       (list :training (dataset-file-fingerprint dataset)
                             :reference
                             (dataset-file-fingerprint reference-dataset))
                     *fitness-fn* #'semantic-offline-training-fitness)))
           (progn
             (setf *offline-training-dataset* nil
                   *offline-reference-dataset* nil
                   *offline-fitness-batch-indices* nil
                   *current-dataset-fingerprint* nil)
             (setf *fitness-fn*
                   (lambda (team)
                     (accuracy team dataset)))))))

    (t
     (error "Neither GYM-ENVIRONMENT-NAME nor DATASET-NAME was supplied."))))

(defun configure-fitness-function (mode gym-environment-name dataset-name)
  "Configure *FITNESS-FN* according to MODE."
  (ecase mode
    (:online
     (make-fitness-function :gym-environment-name gym-environment-name))
    (:offline
     (make-fitness-function :dataset-name dataset-name))))

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
  ;; The first CAGE2 team lazily creates a seed list after this reset. Every
  ;; root team reads that same list; the next population evaluation gets a new
  ;; list generated from the search random state.
  (setf *online-fitness-episode-seeds* nil
        *offline-fitness-batch-indices* nil)
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

(defun current-reference-fitness (team training-fitness)
  "Return TEAM's comparable historical score for the active fitness protocol."
  (let ((reference-kind
          (cond
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
          (let ((result
                  (ecase reference-kind
                    (:cage2
                     (cage2-reference-fitness
                      team *current-gym-environment-name*))
                    (:offline
                     (semantic-offline-reference-fitness team)))))
            (emit-message
             (format nil
                     "Generation ~D ~A reference evaluation finished in ~,2F seconds."
                     *generation*
                     reference-kind
                     (/ (- (get-internal-real-time) started)
                        (coerce internal-time-units-per-second
                                'double-float))))
            result)))))

(defun complexity-key-less-p (left right)
  "Return true when lexicographic complexity key LEFT is smaller than RIGHT."
  (loop for left-value in left
        for right-value in right
        when (< left-value right-value) do (return t)
        when (> left-value right-value) do (return nil)
        finally (return nil)))

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

         (historical-candidate-fitness
           (current-reference-fitness
            generation-best-team
            generation-best))

         (population-mean
           (arithmetic-mean fitness-values))

         (population-median
           (numeric-median fitness-values))

         (population-worst
           (reduce #'min
                   fitness-values
                   :initial-value
                   most-positive-double-float)))

    ;; ------------------------------------------------------------
    ;; Historical best
    ;;
    ;; IMPORTANT:
    ;; Never store the live population team directly in *BEST-TEAM*.
    ;;
    ;; Instead:
    ;;   1. detect a new global best
    ;;   2. deep-copy its entire graph immediately
    ;;   3. store that frozen copy in *BEST-TEAM*
    ;;   4. immediately write it to disk
    ;;
    ;; This guarantees that *BEST-FITNESS* and *BEST-TEAM* refer to
    ;; the exact same policy state.
    ;; ------------------------------------------------------------

    (when (or (null *best-fitness*)
              (> historical-candidate-fitness *best-fitness*))

      (let ((frozen-best-team
              (deep-copy-team-via-serialization
               generation-best-team)))

        (setf *best-fitness* historical-candidate-fitness
              *best-team* frozen-best-team)

        (emit-message
         (format nil
                 "NEW GLOBAL BEST: generation=~A reference-fitness=~A training-fitness=~A. "
                 *generation*
                 *best-fitness*
                 generation-best))

        ;; Save immediately, before reproduce/mutation/deletion.
        (when *checkpoint-directory*
          (save-best-team))))

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
       :max-program-size max-program-size))

    ;; ------------------------------------------------------------
    ;; Selection
    ;; ------------------------------------------------------------

    (dolist (entry worst-entries)
      (delete-team (car entry)))))

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

(defun reproduce ()
  (loop while (< (length (root-teams)) *population-size*)
	do (mutate-team (clone-team (random-choice (root-teams))))))

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
    
    (reproduce)))

(defun run-search (mode gym-environment-name dataset-name seed)
  "Search the solution space with a tangled program graph."
  (let* ((seed (seed-or-random-seed seed))
         (captured-state (sb-ext:seed-random-state seed)))
    (setf *random-state* captured-state
          *current-gym-environment-name* gym-environment-name
          *current-search-seed* seed
          *current-dataset-name* (and (eq mode :offline) dataset-name))

    (catch 'search-stop-requested
      (setf *teams* nil)
      (setf *generation* 1)
      (setf *best-team* nil)
      (setf *best-fitness* nil)

      (make-initial-population)
      (configure-fitness-function mode gym-environment-name dataset-name)

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
             (saved-dataset-fingerprint
               (getf metadata :dataset-fingerprint)))
         (and (or (null saved-environment)
                  (equal saved-environment gym-environment-name))
              (cond
                ((cl-gym:cage2-environment-p gym-environment-name)
                 (and (or (null saved-episodes)
                          (= saved-episodes *online-fitness-episodes*))
                      (eq saved-protocol
                          +cage2-online-fitness-protocol+)))
                (*offline-reference-dataset*
                 (and (eq saved-protocol
                          +semantic-offline-fitness-protocol+)
                      (equal saved-dataset-fingerprint
                             *current-dataset-fingerprint*)))
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
           (loaded-reference-fitness
             (current-reference-fitness
              loaded-best-team
              loaded-current-fitness))
           (generation-reference-fitness
             (if (eq generation-best-team loaded-best-team)
                 loaded-reference-fitness
                 (current-reference-fitness
                  generation-best-team
                  generation-best-fitness))))
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
               (> generation-reference-fitness loaded-baseline))
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
              *best-fitness* chosen-fitness)

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
          *current-gym-environment-name* gym-environment-name
          *current-search-seed* seed
          *current-dataset-name* (and (eq mode :offline) dataset-name))

    (catch 'search-stop-requested
      ;; Fresh island-local state.
      (setf *teams* nil)
      (setf *generation* 1)
      (setf *best-team* nil)
      (setf *best-fitness* nil)

      ;; Build fresh random population for this island.
      (make-initial-population)

      ;; Fitness must exist before the initial evaluation.
      (configure-fitness-function mode gym-environment-name dataset-name)

      ;; Load and inject this island's best team.  Versioned checkpoints retain
      ;; their historical score when the environment and episode count match.
      (multiple-value-bind
            (loaded-best-team saved-best-fitness checkpoint-metadata)
          (load-best-team best-team-path)
        (inject-loaded-best-team-into-population loaded-best-team)
        (emit-policy-limit-warning loaded-best-team)

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

          ;; Evaluate all roots once and initialize the historical-best floor.
          (initialize-best-from-current-population
           loaded-best-team
           comparable-fitness)))

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
