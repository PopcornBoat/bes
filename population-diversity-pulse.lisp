(in-package :cl-tpg)

(defun reset-population-diversity-pulse-state ()
  "Reset run-local pulse scheduling without changing a policy or population."
  (setf *population-diversity-pulse-last-event-generation* nil
        *population-diversity-pulse-last-improvement-generation* 1
        *population-diversity-pulse-last-incumbent-version*
          *official-guided-incumbent-version*
        *population-diversity-pulse-event-count* 0
        *population-diversity-pulse-last-record* nil))

(defun population-diversity-pulse-state-copy ()
  "Return serialization-safe provenance for the latest pulse."
  (list :protocol +population-diversity-pulse-protocol+
        :enabled (not (null *population-diversity-pulse-enabled*))
        :event-count *population-diversity-pulse-event-count*
        :last-event-generation
          *population-diversity-pulse-last-event-generation*
        :last-improvement-generation
          *population-diversity-pulse-last-improvement-generation*
        :last-incumbent-version
          *population-diversity-pulse-last-incumbent-version*
        :last-record (copy-tree *population-diversity-pulse-last-record*)))

(defun population-diversity-pulse-active-p ()
  "Return true only for the maintained stateless official-guided contract."
  (and *population-diversity-pulse-enabled*
       (official-guided-mode-p)
       (not *recurrent-policy-enabled*)
       (member *terminal-action-format*
               '(:target-response-36 :flat-36) :test #'eq)
       *best-team*))

(defun population-diversity-pulse-track-incumbent-change ()
  "Restart the plateau clock whenever final official promotion changes best."
  (unless (= *population-diversity-pulse-last-incumbent-version*
             *official-guided-incumbent-version*)
    (setf *population-diversity-pulse-last-incumbent-version*
            *official-guided-incumbent-version*
          *population-diversity-pulse-last-improvement-generation*
            *generation*)
    t))

(defun population-diversity-pulse-eligible-p ()
  "Return true when both incumbent plateau and event cooldown are satisfied."
  (and (population-diversity-pulse-active-p)
       (>= (- *generation*
              *population-diversity-pulse-last-improvement-generation*)
           *population-diversity-pulse-plateau-generations*)
       (or (null *population-diversity-pulse-last-event-generation*)
           (>= (- *generation*
                  *population-diversity-pulse-last-event-generation*)
               *population-diversity-pulse-cooldown-generations*))))

(defun population-diversity-pulse-cohort-size ()
  "Return the number of roots in one temporary warm-start cohort."
  (max 1
       (round (* *population-size*
                 *population-diversity-pulse-cohort-fraction*))))

(defun population-diversity-pulse-seed ()
  "Derive an event-local seed without consuming ordinary mutation RNG state."
  (unless (integerp *current-search-seed*)
    (error "A diversity pulse requires an integer search seed, got ~S."
           *current-search-seed*))
  (official-guided-derived-root
   *current-search-seed*
   (+ +population-diversity-pulse-rng-salt+
      *population-diversity-pulse-event-count*)))

(defun make-population-diversity-pulse-random-roots (count seed)
  "Create COUNT independent initial roots under an event-local RNG stream."
  (let ((*teams* nil)
        (*random-state* (sb-ext:seed-random-state seed)))
    (loop repeat count collect (make-team))))

(defun maybe-install-population-diversity-pulse ()
  "Add one temporary warm-start cohort beside the current population.

The cohort contains one independent protected-incumbent copy and otherwise
fresh random roots.  Nothing is removed here: the next ordinary evaluation
temporarily sees the enlarged population, and the unchanged selection gap
returns it toward its configured size.  The protected best and its checkpoint
are never modified."
  (population-diversity-pulse-track-incumbent-change)
  (unless (population-diversity-pulse-eligible-p)
    (return-from maybe-install-population-diversity-pulse nil))
  (let* ((roots-before (length (root-teams)))
         (cohort-size (population-diversity-pulse-cohort-size))
         (random-count (max 0 (1- cohort-size)))
         (seed (population-diversity-pulse-seed))
         (incumbent-copy (deep-copy-team-via-serialization *best-team*))
         (random-roots
           (make-population-diversity-pulse-random-roots random-count seed)))
    (install-independent-team-closure incumbent-copy)
    (dolist (root random-roots)
      (push root *teams*))
    (incf *population-diversity-pulse-event-count*)
    (setf *population-diversity-pulse-last-event-generation* *generation*
          *population-diversity-pulse-last-record*
            (list :protocol +population-diversity-pulse-protocol+
                  :generation *generation*
                  :incumbent-version *official-guided-incumbent-version*
                  :event-index *population-diversity-pulse-event-count*
                  :seed seed
                  :roots-before roots-before
                  :cohort-size cohort-size
                  :incumbent-copies 1
                  :incumbent-copy-id (team-id incumbent-copy)
                  :fresh-random-roots random-count
                  :roots-after (length (root-teams))))
    (append-behavioral-locality-form
     (append (list :record-type :population-diversity-pulse)
             (copy-tree *population-diversity-pulse-last-record*)))
    (emit-message
     (format nil
             "Generation ~D population diversity pulse: incumbent-version=~D roots=~D+~D->~D incumbent-copies=1 fresh-random=~D seed=~D. Protected incumbent unchanged."
             *generation*
             *official-guided-incumbent-version*
             roots-before cohort-size (length (root-teams)) random-count seed))
    (copy-tree *population-diversity-pulse-last-record*)))
