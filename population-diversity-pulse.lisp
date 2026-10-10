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
        :wipe-fraction *population-diversity-pulse-wipe-fraction*
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

(defun population-diversity-pulse-wipe-count (root-count)
  "Return how many of ROOT-COUNT live roots one pulse replaces."
  (unless (and (realp *population-diversity-pulse-wipe-fraction*)
               (> *population-diversity-pulse-wipe-fraction* 0)
               (<= *population-diversity-pulse-wipe-fraction* 1))
    (error "Diversity-pulse wipe fraction must be in (0,1], got ~S."
           *population-diversity-pulse-wipe-fraction*))
  (min root-count
       (max 1
            (round (* root-count
                      *population-diversity-pulse-wipe-fraction*)))))

(defun population-diversity-pulse-seed ()
  "Derive an event-local seed without consuming ordinary mutation RNG state."
  (unless (integerp *current-search-seed*)
    (error "A diversity pulse requires an integer search seed, got ~S."
           *current-search-seed*))
  (official-guided-derived-root
   *current-search-seed*
   (+ +population-diversity-pulse-rng-salt+
      *population-diversity-pulse-event-count*)))

(defun make-population-diversity-pulse-random-roots (count random-state)
  "Create COUNT independent initial roots under an event-local RNG stream."
  (let ((*teams* nil)
        (*random-state* random-state))
    (loop repeat count collect (make-team))))

(defun population-diversity-pulse-select-wiped-roots
       (roots count random-state)
  "Select COUNT distinct ROOTS using only the pulse-local RANDOM-STATE."
  (let ((available (copy-list roots))
        (selected nil)
        (*random-state* random-state))
    (loop repeat count
          for root = (random-choice available)
          do (push root selected)
             (setf available (delete root available :test #'eq :count 1)))
    (values (nreverse selected) available)))

(defun population-diversity-pulse-delete-wiped-closure
       (wiped-roots retained-roots)
  "Delete WIPED-ROOTS and any newly orphaned subgraphs.

Teams still referenced by RETAINED-ROOTS remain internal and are preserved.
Return the number of newly orphaned roots removed after the requested roots."
  (dolist (root wiped-roots)
    (when (member root *teams* :test #'eq)
      (delete-team root)))
  (loop with orphan-count = 0
        for orphan = (find-if
                      (lambda (team)
                        (not (member team retained-roots :test #'eq)))
                      (root-teams))
        while orphan
        do (incf orphan-count)
           (delete-team orphan)
        finally (return orphan-count)))

(defun maybe-install-population-diversity-pulse ()
  "Replace a configured root fraction with a warm-start-style cohort.

The retained population stays intact.  Wiped roots and their newly orphaned
subgraphs are removed, then one independent protected-incumbent copy and fresh
random roots refill exactly the vacated slots.  The protected best and its
checkpoint are never modified."
  (population-diversity-pulse-track-incumbent-change)
  (unless (population-diversity-pulse-eligible-p)
    (return-from maybe-install-population-diversity-pulse nil))
  (let* ((roots-before (length (root-teams)))
         (wipe-count (population-diversity-pulse-wipe-count roots-before))
         (random-count (max 0 (1- wipe-count)))
         (seed (population-diversity-pulse-seed))
         (event-random-state (sb-ext:seed-random-state seed))
         (incumbent-copy (deep-copy-team-via-serialization *best-team*))
         (wiped-roots nil)
         (retained-roots nil)
         (random-roots nil)
         (orphan-roots-pruned 0))
    (multiple-value-setq (wiped-roots retained-roots)
      (population-diversity-pulse-select-wiped-roots
       (root-teams) wipe-count event-random-state))
    ;; Construct replacements before destructively changing the live graph.
    ;; Fresh roots stay isolated from *TEAMS* until the replacement commits.
    (setf random-roots
          (make-population-diversity-pulse-random-roots
           random-count event-random-state))
    (setf orphan-roots-pruned
          (population-diversity-pulse-delete-wiped-closure
           wiped-roots retained-roots))
    (install-independent-team-closure incumbent-copy)
    (dolist (root random-roots)
      (push root *teams*))
    (unless (= (length (root-teams)) roots-before)
      (error "Diversity pulse changed root count from ~D to ~D."
             roots-before (length (root-teams))))
    (incf *population-diversity-pulse-event-count*)
    (setf *population-diversity-pulse-last-event-generation* *generation*
          *population-diversity-pulse-last-record*
            (list :protocol +population-diversity-pulse-protocol+
                  :generation *generation*
                  :incumbent-version *official-guided-incumbent-version*
                  :event-index *population-diversity-pulse-event-count*
                  :seed seed
                  :roots-before roots-before
                  :wipe-fraction *population-diversity-pulse-wipe-fraction*
                  :roots-wiped wipe-count
                  :wiped-root-ids (mapcar #'team-id wiped-roots)
                  :roots-retained (length retained-roots)
                  :retained-root-ids (mapcar #'team-id retained-roots)
                  :orphan-roots-pruned orphan-roots-pruned
                  :incumbent-copies 1
                  :incumbent-copy-id (team-id incumbent-copy)
                  :fresh-random-roots random-count
                  :roots-after (length (root-teams))))
    (append-behavioral-locality-form
     (append (list :record-type :population-diversity-pulse)
             (copy-tree *population-diversity-pulse-last-record*)))
    (emit-message
     (format nil
             "Generation ~D population diversity pulse: incumbent-version=~D roots=~D wipe=~D (~,2F) retained=~D orphan-pruned=~D rebuilt=1+~D final=~D seed=~D. Protected incumbent unchanged."
             *generation*
             *official-guided-incumbent-version*
             roots-before wipe-count
             *population-diversity-pulse-wipe-fraction*
             (length retained-roots) orphan-roots-pruned random-count
             (length (root-teams)) seed))
    (copy-tree *population-diversity-pulse-last-record*)))
