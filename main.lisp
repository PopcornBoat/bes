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

(defparameter *fitness-window-size* 1000)
(defparameter *fitness-window* '())
(defparameter *fitness-window-sum* 0.0d0)

(defun reset-fitness-window ()
  (setf *fitness-window* '()
        *fitness-window-sum* 0.0d0))

(defun record-fitness-and-mean (fitness)
  (let ((f (coerce fitness 'double-float)))
    (push f *fitness-window*)
    (incf *fitness-window-sum* f)

    (when (> (length *fitness-window*) *fitness-window-size*)
      (let ((oldest (car (last *fitness-window*))))
        (setf *fitness-window* (butlast *fitness-window*))
        (decf *fitness-window-sum* oldest)))

    (values (/ *fitness-window-sum*
               (length *fitness-window*))
            (length *fitness-window*))))
            	  
(defun make-fitness-function (&key gym-environment-name dataset-name)
  (cond
    (gym-environment-name
     (setf *fitness-fn*
	   (lambda (team)
	     (cl-gym:rollout team gym-environment-name (random 9999999)))))
    (dataset-name
     (let ((dataset (load-dataset dataset-name)))
       (setf *fitness-fn* 
	     (lambda (team)
	       (accuracy team dataset)))))))

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
  "Remove GAP percent of the population by removing the worst teams."
  (let* ((sorted (sort (copy-list scores) #'> :key #'cdr))
         (n-remove (floor (* *gap* (length scores))))
         (worst (last sorted n-remove))
         (best-entry (first sorted))
         (best-fitness (and best-entry (cdr best-entry))))

    (when best-fitness
      ;; Maintain best individual seen so far.
      (when (or (null *best-fitness*)
                (> best-fitness *best-fitness*))
        (setf *best-fitness* best-fitness
              *best-team* (car best-entry)))

      (multiple-value-bind (rolling-mean total-eps)
          (record-fitness-and-mean best-fitness)
        (emit-fitness-scores (who-am-i)
                             best-fitness
                             *generation*
                             :mean rolling-mean
                             :total-eps total-eps)))

    (dolist (entry worst)
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
    
    (reproduce)
    (maybe-save-best-team)))

(defun run-search (mode gym-environment-name dataset-name seed)
  "Search the solution space with a tangled program graph."
  (let* ((seed (seed-or-random-seed seed))
         (captured-state (sb-ext:seed-random-state seed)))
    (setf *random-state* captured-state)

    (setf *teams* nil)
    (setf *generation* 1)
    (setf *best-team* nil)
    (setf *best-fitness* nil)

    (reset-fitness-window)

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
                          (first (sort (copy-list scores) #'> :key #'cdr)))))
    (unless best-entry
      (error "Warm-start evaluation failed: no valid teams after evaluation."))

    (setf *best-team* (car best-entry)
          *best-fitness* (cdr best-entry))

    (if (eq *best-team* loaded-best-team)
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

    (reset-fitness-window)

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
  (let* ((team (load-best-team best-team-path))
         (score (cl-gym-validate-team
                 team
                 gym-environment-name
                 (random 9999999))))
    (emit-message
     (format nil
             "Validation finished. Env=~A BestTeam=~A Score=~A"
             gym-environment-name
             best-team-path
             score))
    score))