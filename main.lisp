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

(defun online-fitness (team gym-environment-name)
  "Evaluate TEAM over *ONLINE-FITNESS-EPISODES* complete episodes.

The returned fitness is the mean episode reward. CAGE2 teams are always
evaluated on the same deterministic episode batch rooted at seed 153. This
makes a saved policy's score replayable and gives every candidate common
random numbers. The dynamic Lisp random-state binding also keeps rollout seed
generation from consuming the evolutionary random stream."
  (unless (and (integerp *online-fitness-episodes*)
               (> *online-fitness-episodes* 0))
    (error "*ONLINE-FITNESS-EPISODES* must be a positive integer."))

  (let* ((cage2-p (cl-gym:cage2-environment-p gym-environment-name))
         (*random-state*
           (if cage2-p
               (sb-ext:seed-random-state +cage2-evaluation-seed+)
               *random-state*)))
    ;; CybORG consumes Python's process-wide RANDOM stream. Reset it once per
    ;; candidate evaluation, not once per episode, so a fixed policy sees a
    ;; repeatable advancing sequence rather than one repeated episode.
    (when cage2-p
      (cl-gym:seed-python-random +cage2-evaluation-seed+))

    (arithmetic-mean
     (loop repeat *online-fitness-episodes*
           collect
           (cl-gym:rollout team
                           gym-environment-name
                           (random 9999999))))))
            	  
(defun make-fitness-function (&key gym-environment-name dataset-name)
  (cond
    (gym-environment-name
     (setf *fitness-fn*
           (lambda (team)
             (online-fitness team gym-environment-name))))

    (dataset-name
     (let ((dataset (load-dataset dataset-name)))
       (setf *fitness-fn*
             (lambda (team)
               (accuracy team dataset)))))

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
  (let* ((results (mapcar #'safe-evaluate-team
                                     (root-teams)))
         (bad-teams (loop for (team . fitness) in results
                          when (eq fitness :bad)
                            collect team))
         (good-results (remove :bad results :key #'cdr)))
    ;; Do mutation/deletion serially.
    (dolist (team bad-teams)
      (delete-team team))
    good-results))

(defun select (scores)
  "Remove GAP percent of the population by removing the worst teams.

Maintain a frozen deep copy of the historical best team. Whenever a new
global best is discovered, immediately deep-copy the complete TPG graph
through serialization/deserialization and save it to disk."

  (unless scores
    (error "Cannot select from an empty score list."))

  (let* ((sorted
           (sort (copy-list scores) #'> :key #'cdr))

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
              (> generation-best *best-fitness*))

      (let ((frozen-best-team
              (deep-copy-team-via-serialization
               generation-best-team)))

        (setf *best-fitness* generation-best
              *best-team* frozen-best-team)

        (emit-message
         (format nil
                 "NEW GLOBAL BEST: generation=~A fitness=~A. "
                 *generation*
                 *best-fitness*))

        ;; Save immediately, before reproduce/mutation/deletion.
        (when *checkpoint-directory*
          (save-best-team))))

    ;; ------------------------------------------------------------
    ;; Telemetry
    ;; ------------------------------------------------------------

    (emit-fitness-scores
     (who-am-i)
     generation-best
     *best-fitness*
     population-mean
     population-median
     population-worst
     *generation*
     :online-fitness-episodes
     *online-fitness-episodes*)

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
  (receive-migrants)

  (let ((evaluation-scores (evaluate)))

    (when (should-send-migrants-p)
      (send-migrants evaluation-scores))

    (select evaluation-scores)
    
    (reproduce)))

(defun run-search (mode gym-environment-name dataset-name seed)
  "Search the solution space with a tangled program graph."
  (let* ((seed (seed-or-random-seed seed))
         (captured-state (sb-ext:seed-random-state seed)))
    (setf *random-state* captured-state)

    (setf *teams* nil)
    (setf *generation* 1)
    (setf *best-team* nil)
    (setf *best-fitness* nil)

   

    (make-initial-population)
    (configure-fitness-function mode gym-environment-name dataset-name)

    (loop while *running*
          do (evolve)
          do (incf *generation*))))

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
					     
(defun initialize-best-from-current-population (loaded-best-team)
  "Evaluate the current root population and initialize *BEST-TEAM* and *BEST-FITNESS*.

If LOADED-BEST-TEAM is still the best individual after evaluation, keep it as the
global best. Otherwise use the best individual from the freshly initialized
population."
  (let* ((scores (evaluate))
         (best-entry (and scores
                          (first (sort (copy-list scores) #'> :key #'cdr))))
         (generation-best-team (and best-entry (car best-entry)))
         (loaded-won-p (eq generation-best-team loaded-best-team)))
    (unless best-entry
      (error "Warm-start evaluation failed: no valid teams after evaluation."))

    (setf *best-team*
      (deep-copy-team-via-serialization
       generation-best-team)

      *best-fitness*
      (cdr best-entry))

    (if loaded-won-p
        (emit-message
         (format nil
                 "Warm-start: loaded best team remains best after initial evaluation. Fitness=~A"
                 *best-fitness*))
        (emit-message
         (format nil
                 "Warm-start: a newly initialized team outperformed loaded best. New best fitness=~A"
                 *best-fitness*)))

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
    (setf *random-state* captured-state)

    ;; Fresh island-local state.
    (setf *teams* nil)
    (setf *generation* 1)
    (setf *best-team* nil)
    (setf *best-fitness* nil)

 

    ;; Build fresh random population for this island.
    (make-initial-population)

    ;; Fitness must exist before the initial evaluation.
    (configure-fitness-function mode gym-environment-name dataset-name)

    ;; Load and inject this island's best team.
    (let ((loaded-best-team (load-best-team best-team-path)))
      (inject-loaded-best-team-into-population loaded-best-team)

      ;; Evaluate all root teams once and decide whether loaded best is still best.
      (initialize-best-from-current-population loaded-best-team))

    ;; Continue normal BES/TPG evolution.
    (loop while *running*
          do (evolve)
          do (incf *generation*))))


(defun validate-best-team-online (best-team-path gym-environment-name)
  "Load BEST-TEAM-PATH and validate it in GYM-ENVIRONMENT-NAME."
  (let* ((cage2-p (cl-gym:cage2-environment-p gym-environment-name))
         (*random-state*
           (if cage2-p
               (sb-ext:seed-random-state +cage2-evaluation-seed+)
               *random-state*)))
    (when cage2-p
      (cl-gym:seed-python-random +cage2-evaluation-seed+))

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
