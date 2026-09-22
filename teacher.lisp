(in-package :cl-tpg)

(defun teacher-sequence-list (value description)
  "Return VALUE as a list, rejecting non-sequence bridge results."
  (unless (and (typep value 'sequence) (not (stringp value)))
    (error "Teacher trace ~A must be a sequence, got ~S." description value))
  (coerce value 'list))

(defun teacher-trace-to-dataset (rows)
  "Convert primitive Python teacher rows into an in-memory ranked dataset."
  (let* ((row-list (teacher-sequence-list rows "batch"))
         (count (length row-list))
         (observations (make-array count))
         (actions (make-array count))
         (rankings (make-array count))
         (masks (make-array count))
         (rewards (make-array count
                              :element-type 'double-float
                              :initial-element 0.0d0))
         (terminations (make-array count :initial-element 0))
         (truncations (make-array count :initial-element 0))
         (episode-ids (make-array count :initial-element nil))
         (steps (make-array count :initial-element nil))
         (saw-episode-metadata nil)
         (saw-missing-episode-metadata nil))
    (when (zerop count)
      (error "Teacher trace generation returned no rows."))
    (loop for raw-row in row-list
          for index fixnum from 0
          for row = (teacher-sequence-list raw-row "row")
          do (unless (member (length row) '(4 6))
               (error "Teacher row must contain four or six fields, got ~S."
                      row))
             (destructuring-bind
                   (raw-observation raw-selected raw-ranking decoy-mask
                    &optional episode-id step)
                  row
               (let* ((selected
                        (teacher-sequence-list raw-selected "selected action"))
                      (ranking
                        (mapcar
                         (lambda (pair)
                           (teacher-sequence-list pair "ranking pair"))
                         (teacher-sequence-list raw-ranking "ranking")))
                      (observation (cl-gym:obs->array raw-observation)))
                 (unless (= (length observation) +cage2-observation-size+)
                   (error "Teacher row expected ~D observations, got ~D."
                          +cage2-observation-size+
                          (length observation)))
                 (unless (valid-semantic-pair-p selected)
                   (error "Invalid teacher selected action: ~S" selected))
                 (unless (valid-semantic-ranking-p ranking)
                   (error "Invalid teacher semantic ranking: ~S" ranking))
                 (unless (and (integerp decoy-mask) (not (minusp decoy-mask)))
                   (error "Invalid teacher Decoy mask: ~S" decoy-mask))
                 (if (= (length row) 6)
                     (progn
                       (unless (and (integerp step) (not (minusp step)))
                         (error "Invalid teacher trace step: ~S" step))
                       (setf saw-episode-metadata t))
                     (setf saw-missing-episode-metadata t))
                 (when (and saw-episode-metadata saw-missing-episode-metadata)
                   (error
                    "Teacher trace mixes rows with and without episode metadata."))
                 (setf (aref observations index) observation
                       (aref actions index)
                         (list (first selected) (second selected) 0)
                       (aref rankings index) ranking
                       (aref masks index) decoy-mask
                       (aref episode-ids index) episode-id
                       (aref steps index) step))))
    (%make-dataset
     :observations observations
     :actions actions
     :rewards rewards
     :terminations terminations
     :truncations truncations
     :teacher-actions (make-array count :initial-element nil)
     :decoy-masks masks
     :semantic-rankings rankings
     :episode-ids (and saw-episode-metadata episode-ids)
     :steps (and saw-episode-metadata steps)
     :episode-ranges
       (and saw-episode-metadata
            (make-dataset-episode-ranges episode-ids))
     :size count
     :action-format :semantic-ranked
     :source-path nil)))

(defconstant +teacher-trace-chunk-size+ 5
  "Maximum episodes per bridge call, bounding stop-request latency.")

(defun teacher-backend-python-name ()
  "Return the selected local teacher backend name for the Python bridge."
  (string-downcase (symbol-name *teacher-backend*)))

(defun generate-teacher-trace-rows (environment-name episode-seeds)
  "Generate primitive rows from teacher-controlled episodes.

Episodes are requested in small chunks so a stop request can be observed
between simulator calls. Chunking does not change episode seeds or rows."
  (unless (and (stringp environment-name)
               (cl-gym:cage2-environment-p environment-name))
    (error "Teacher forcing requires a CAGE2 environment, got ~S."
           environment-name))
  (unless episode-seeds
    (error "Teacher forcing requires at least one episode seed."))
  (py4cl2:pyexec "import cage2_bridge; import cage2_bridge.teacher")
  (let ((remaining (coerce episode-seeds 'list))
        (include-opening-p (eq *cage2-opening-mode* :policy))
        (all-rows nil))
    (loop while remaining
          for count = (min +teacher-trace-chunk-size+ (length remaining))
          for chunk = (subseq remaining 0 count)
          do (abort-search-if-requested)
             (setf all-rows
                   (nconc all-rows
                          (teacher-sequence-list
                           (py4cl2:pycall
                            "cage2_bridge.teacher.generate_teacher_trace"
                            environment-name
                            chunk
                            include-opening-p
                            t
                            (teacher-backend-python-name))
                           "chunk"))
                   remaining (nthcdr count remaining)))
    all-rows))

(defun generate-teacher-trace-dataset (environment-name episode-seeds)
  "Generate one teacher-controlled trace bank through the Python bridge."
  (teacher-trace-to-dataset
   (generate-teacher-trace-rows environment-name episode-seeds)))

(defun teacher-observation-decoy-mask (observation)
  "Return the pre-action Decoy-use mask encoded in a bridge observation."
  (unless (= (length observation) +cage2-observation-size+)
    (error "DAgger expected ~D bridge observations, got ~D."
           +cage2-observation-size+
           (length observation)))
  (loop with mask = 0
        for observation-index from +cage2-scan-observation-size+
          below +cage2-observation-size+
        for option-index fixnum from 0
        when (<= (coerce (elt observation observation-index) 'double-float)
                 0.5d0)
          do (setf mask (logior mask (ash 1 option-index)))
        finally (return mask)))

(defun resolve-teacher-pair-ranking (ranking decoy-mask)
  "Resolve a teacher target/response RANKING exactly like fixed bridge fallback."
  (loop for pair in ranking
        for rank fixnum from 0
        for target = (first pair)
        for response = (second pair)
        do (cond
             ((= target +global-target+)
              (return pair))
             ((= response 3)
              (when (integerp
                     (first-available-decoy-option
                      target
                      decoy-mask
                      (action-agreement-decoy-orders-for-backend)))
                (return pair)))
             ((and (> rank 0) (= response 2))
              nil)
             (t
              (return pair)))
        finally (return (list +global-target+ 0))))

(defun teacher-red-agent-name (environment-name)
  "Return the bridge teacher name implied by ENVIRONMENT-NAME."
  (cond
    ((search "b_line" environment-name) "b_line")
    ((search "meander" environment-name) "meander")
    (t
     (error "Teacher forcing supports separate b_line and meander environments."))))

(defun generate-dagger-trace-rows (behavior-team environment-name episode-seeds)
  "Run a clean mixed DAgger rollout and label every policy-owned state.

Teacher and learner queries are proposals only. The bridge owns scan and Decoy
state, and only the action actually passed to STEP can advance that state. The
fixed three-step opening remains controller-owned. Outside official-guided mode
the historical learner-controlled DAgger behavior is preserved."
  (unless behavior-team
    (error "DAgger requires a behavior team."))
  (py4cl2:pyexec
   "import gymnasium as gym; import cage2_bridge; import cage2_bridge.teacher")
  (let* ((env (cl-gym::make environment-name))
         (teacher
           (py4cl2:pycall
            "cage2_bridge.teacher.make_teacher_policy"
            (teacher-red-agent-name environment-name)
            (teacher-backend-python-name)))
         (teacher-rate
           (if (official-guided-mode-p)
               (official-guided-teacher-mixing-rate)
               0.0d0))
         (rows nil)
         (policy-steps 0)
         (disagreements 0)
         (teacher-absent 0)
         (teacher-controlled 0)
         (learner-controlled 0)
         (first-disagreement-steps nil)
         (total-reward 0.0d0))
    (cl-gym::configure-cage2-option-orders env behavior-team)
    (unwind-protect
         (dolist (episode-seed episode-seeds)
           (abort-search-if-requested)
           ;; The behavior policy must experience exactly the same episode-local
           ;; register lifecycle here as it does during online rollout.
           (call-with-fresh-policy-episode
            (lambda ()
              (py4cl2:pymethod teacher "reset")
              (let ((observation (cl-gym::reset env episode-seed))
                    (episode-id
                      (list :dagger *generation* episode-seed))
                    (episode-reward 0.0d0)
                    (first-disagreement nil))
                (loop for timestep fixnum from 0
                      do (when (zerop (mod timestep 10))
                           (abort-search-if-requested))
                         (let* ((ranking
                                  (mapcar
                                   (lambda (pair)
                                     (teacher-sequence-list
                                      pair "ranking pair"))
                                   (teacher-sequence-list
                                    (py4cl2:pymethod
                                     teacher "rank" observation timestep)
                                    "ranking")))
                                (decoy-mask
                                  (teacher-observation-decoy-mask observation))
                                (selected
                                  (resolve-teacher-pair-ranking
                                   ranking decoy-mask))
                                (opening-action
                                  (cl-gym::cage2-fixed-opening-action
                                   environment-name timestep))
                                (predictions
                                  (and (not opening-action)
                                       (execute-team-semantic-ranked
                                        behavior-team
                                        (policy-observation observation))))
                                (predicted-pair
                                  (and predictions
                                       (resolve-semantic-ranking
                                        predictions
                                        decoy-mask
                                        (effective-team-option-orders
                                         behavior-team))))
                                (teacher-rank
                                  (and predictions
                                       (position
                                        selected predictions
                                        :test #'equal
                                        :key #'semantic-action-category-pair)))
                                (disagreement-p
                                  (and predicted-pair
                                       (not (equal predicted-pair selected))))
                                (teacher-controls-p
                                  (and (not opening-action)
                                       (official-guided-mode-p)
                                       (official-guided-teacher-controls-p
                                        episode-seed timestep teacher-rate)))
                                (action
                                  (or opening-action
                                      (if teacher-controls-p
                                          ranking
                                          (cl-gym::semantic-ranking->cage2-input
                                           predictions)))))
                           ;; Only policy-owned states enter imitation fitness.
                           ;; Metadata keeps each recurrent episode intact.
                           (unless opening-action
                             (push
                              (list observation
                                    (copy-list selected)
                                    (copy-tree ranking)
                                    decoy-mask
                                    episode-id
                                    timestep)
                              rows))
                           (unless opening-action
                             (incf policy-steps)
                             (if teacher-controls-p
                                 (incf teacher-controlled)
                                 (incf learner-controlled))
                             (when disagreement-p
                               (incf disagreements)
                               (unless first-disagreement
                                 (setf first-disagreement timestep)
                                 (push timestep first-disagreement-steps))
                               (unless teacher-rank
                                 (incf teacher-absent))))
                           (multiple-value-bind
                                 (next-observation reward terminated truncated info)
                               (cl-gym::step env action)
                             (declare (ignore info))
                             (incf episode-reward
                                   (coerce reward 'double-float))
                             (setf observation next-observation)
                             (when (or terminated truncated)
                               (incf total-reward episode-reward)
                               (return)))))))))
      (ignore-errors (py4cl2:pymethod env "close")))
    (setf *last-dagger-diagnostics*
          (list :episodes (length episode-seeds)
                :policy-steps policy-steps
                :disagreements disagreements
                :disagreement-rate
                  (if (plusp policy-steps)
                      (/ disagreements (coerce policy-steps 'double-float))
                      0.0d0)
                :first-disagreement-mean
                  (and first-disagreement-steps
                       (/ (reduce #'+ first-disagreement-steps)
                          (coerce (length first-disagreement-steps)
                                  'double-float)))
                :teacher-absent-top-8 teacher-absent
                :teacher-mixing-rate teacher-rate
                :teacher-controlled-steps teacher-controlled
                :learner-controlled-steps learner-controlled
                :mean-mixed-return
                  (/ total-reward
                     (coerce (max 1 (length episode-seeds)) 'double-float))))
    (nreverse rows)))

(defun compact-teacher-dagger-row (row)
  "Copy one DAgger ROW into replay's compact, independently owned form."
  (destructuring-bind
        (observation selected ranking decoy-mask
         &optional episode-id step)
      row
    (list (cl-gym:obs->array observation)
          (copy-list selected)
          (copy-tree ranking)
          decoy-mask
          episode-id
          step)))

(defun append-teacher-dagger-replay (rows)
  "Append ROWS and keep only the newest bounded DAgger replay entries."
  (let* ((compact-rows (mapcar #'compact-teacher-dagger-row rows))
         (combined (nconc *teacher-dagger-replay-rows* compact-rows))
         (excess (- (length combined) +teacher-dagger-replay-capacity+)))
    (setf *teacher-dagger-replay-rows*
          (if (plusp excess)
              (nthcdr excess combined)
              combined))))

(defun sample-teacher-dagger-replay (count)
  "Sample at most COUNT replay rows without replacement."
  (let* ((rows (coerce *teacher-dagger-replay-rows* 'vector))
         (size (length rows))
         (sample-size (min count size)))
    (unless *teacher-dagger-random-state*
      (error "DAgger replay random state is not configured."))
    (loop for index fixnum below sample-size
          for selected-index =
            (+ index
               (random (- size index) *teacher-dagger-random-state*))
          do (rotatef (aref rows index) (aref rows selected-index))
          collect (aref rows index))))

(defun teacher-rows-to-episodes (rows)
  "Group adjacent six-field teacher ROWS into complete episode lists."
  (let ((episodes nil)
        (current nil)
        (current-id :none))
    (dolist (row rows)
      (unless (= (length row) 6)
        (error "Recurrent teacher row lacks episode metadata: ~S" row))
      (let ((episode-id (fifth row)))
        (unless (equal episode-id current-id)
          (when current
            (push (nreverse current) episodes))
          (setf current nil
                current-id episode-id))
        (push row current)))
    (when current
      (push (nreverse current) episodes))
    (nreverse episodes)))

(defun append-teacher-dagger-replay-episodes (rows)
  "Append complete DAgger episodes and enforce the row cap at boundaries."
  (let* ((episodes
           (mapcar
            (lambda (episode)
              (mapcar #'compact-teacher-dagger-row episode))
            (teacher-rows-to-episodes rows)))
         (combined
           (nconc *teacher-dagger-replay-episodes* episodes))
         (row-count
           (loop for episode in combined sum (length episode))))
    (loop while (and combined
                     (> row-count +teacher-dagger-replay-capacity+))
          do (decf row-count (length (first combined)))
             (setf combined (rest combined)))
    (setf *teacher-dagger-replay-episodes* combined)))

(defun sample-teacher-dagger-replay-episodes (row-budget)
  "Sample complete replay episodes without exceeding their sequence context."
  (unless *teacher-dagger-random-state*
    (error "DAgger replay random state is not configured."))
  (let* ((episodes (coerce *teacher-dagger-replay-episodes* 'vector))
         (size (length episodes))
         (selected nil)
         (selected-rows 0))
    (loop for position fixnum below size
          while (< selected-rows row-budget)
          for selected-index =
            (+ position
               (random (- size position) *teacher-dagger-random-state*))
          do (rotatef (aref episodes position)
                      (aref episodes selected-index))
             (push (aref episodes position) selected)
             (incf selected-rows (length (aref episodes position))))
    (loop for episode in (nreverse selected)
          append episode)))

(defun make-teacher-reference-seeds ()
  "Return the fixed seed-153 teacher reference bank."
  (let ((*random-state*
          (sb-ext:seed-random-state +cage2-evaluation-seed+)))
    (loop repeat +teacher-reference-episodes+
          collect (random 9999999))))

(defun configure-teacher-forcing-fitness (environment-name)
  "Configure ranked imitation and build the fixed teacher reference bank."
  (unless (= *num-actions* +num-semantic-targets+)
    (error "Teacher forcing requires ~D semantic targets, got ~S."
           +num-semantic-targets+
           *num-actions*))
  (unless (valid-cage2-policy-observation-size-p *num-observations*)
    (error "Teacher forcing requires ~D or ~D observations, got ~S."
           +cage2-scan-observation-size+
           +cage2-observation-size+
           *num-observations*))
  (unless (eq *decoy-order-mode* :fixed)
    (error "Teacher forcing requires the fixed Decoy order."))
  (unless (valid-cage2-opening-mode-p *cage2-opening-mode*)
    (error "Invalid CAGE2 opening mode: ~S." *cage2-opening-mode*))
  (unless (valid-teacher-forcing-rollout-mode-p
           *teacher-forcing-rollout-mode*)
    (error "Invalid teacher-forcing rollout mode: ~S."
           *teacher-forcing-rollout-mode*))
  (unless (valid-teacher-backend-p *teacher-backend*)
    (error "Invalid local teacher backend: ~S." *teacher-backend*))
  (when (and (eq *teacher-backend* :heuristic)
             (not (search "b_line" environment-name)))
    (error "The heuristic teacher currently supports only b_line environments."))
  (setf *factored-actions-enabled* t
        *offline-training-dataset* nil
        *offline-reference-dataset* nil
        *offline-fitness-batch-indices* nil
        *offline-fitness-batch-episode-indices* nil
        *current-dataset-fingerprint* nil
        *teacher-training-dataset* nil
        *teacher-reference-dataset* nil
        *teacher-dagger-replay-rows* nil
        *teacher-dagger-replay-episodes* nil
        *last-dagger-diagnostics* nil
        *teacher-dagger-behavior-team-snapshot* nil
        *teacher-dagger-behavior-fitness* nil
        *teacher-dagger-behavior-generation* nil
        *teacher-dagger-random-state*
          (sb-ext:seed-random-state
           (+ *current-search-seed* 32452843)))
  (configure-hamming-observation-space)
  (emit-message
   (format nil
           "Teacher reference generation started: episodes=~D environment=~A backend=~A opening=~A rollout=~A memory=~A~A"
           +teacher-reference-episodes+
           environment-name
           *teacher-backend*
           *cage2-opening-mode*
           *teacher-forcing-rollout-mode*
           (if *recurrent-policy-enabled* :recurrent :stateless)
           (if (eq *cage2-opening-mode* :fixed)
               "; first three controller steps excluded from TPG fitness"
               "")))
  (setf *teacher-reference-dataset*
        (generate-teacher-trace-dataset
         environment-name
         (make-teacher-reference-seeds)))
  (when *recurrent-policy-enabled*
    (ensure-recurrent-dataset-compatible
     *teacher-reference-dataset* "Recurrent teacher reference dataset"))
  (emit-message
   (format nil
           "Teacher reference ready: rows=~D"
           (dataset-size *teacher-reference-dataset*)))
  (setf *fitness-fn* #'teacher-forcing-training-fitness))

(defun reset-teacher-dagger-behavior-state ()
  "Discard the run-local DAgger behavior snapshot and its provenance."
  (setf *teacher-dagger-behavior-team-snapshot* nil
        *teacher-dagger-behavior-fitness* nil
        *teacher-dagger-behavior-generation* nil))

(defun install-teacher-dagger-behavior-team
       (team fitness generation &key (announce t))
  "Install a fully independent DAgger behavior snapshot of TEAM.

Serialization/deserialization is deliberately used instead of CLONE-TEAM so
referenced subgraphs cannot remain shared with the live population, the
official incumbent, or the warm-start graph stored on disk."
  (unless team
    (error "Cannot install a NIL DAgger behavior team."))
  (let ((snapshot (deep-copy-team-via-serialization team)))
    (setf *teacher-dagger-behavior-team-snapshot* snapshot
          *teacher-dagger-behavior-fitness* fitness
          *teacher-dagger-behavior-generation* generation)
    (when announce
      (emit-message
       (format nil
               "Generation ~D DAgger behavior snapshot advanced: source=~A imitation=~A complexity=~S (independent deep copy)."
               generation (team-id team) fitness
               (policy-complexity-key snapshot))))
    snapshot))

(defun teacher-dagger-behavior-state-copy ()
  "Return a serialization-safe copy of the independent DAgger behavior state."
  (when *teacher-dagger-behavior-team-snapshot*
    (list :version 1
          :source-generation *teacher-dagger-behavior-generation*
          :imitation-fitness *teacher-dagger-behavior-fitness*
          :team
            (serialize-team
             *teacher-dagger-behavior-team-snapshot*
             (make-hash-table :test #'equal)))))

(defun restore-teacher-dagger-behavior-state (state)
  "Restore STATE as an independent, non-population DAgger behavior graph."
  (when state
    (unless (and (= (getf state :version 0) 1)
                 (getf state :team))
      (error "Invalid DAgger behavior state: ~S" state))
    (let ((snapshot
            (deserialize-team
             (getf state :team)
             (make-hash-table :test #'equal))))
      (ensure-team-observation-compatible snapshot *num-observations*)
      (setf *teacher-dagger-behavior-team-snapshot* snapshot
            *teacher-dagger-behavior-fitness*
              (getf state :imitation-fitness)
            *teacher-dagger-behavior-generation*
              (getf state :source-generation))))
  *teacher-dagger-behavior-team-snapshot*)

(defun teacher-dagger-behavior-team ()
  "Return the isolated policy that owns this generation's DAgger rollout.

Official-guided search advances this snapshot from the previous generation's
ranked-imitation champion.  *BEST-TEAM* remains the independently protected
official incumbent and is never repurposed as mutable DAgger state."
  (or *teacher-dagger-behavior-team-snapshot*
      *best-team*
      (first (root-teams))
      (error "DAgger cannot choose a behavior team from an empty population.")))

(defun maybe-collect-teacher-dagger-garbage ()
  "Periodically reclaim promoted trace objects retired from bounded replay."
  #+sbcl
  (when (and (eq *teacher-forcing-rollout-mode* :dagger)
             (plusp *generation*)
             (zerop (mod *generation*
                         +teacher-dagger-full-gc-interval+)))
    (emit-message
     (format nil
             "Generation ~D DAgger full garbage collection started."
             *generation*))
    (sb-ext:gc :full t)))

(defun prepare-teacher-training-dataset ()
  "Build one shared teacher-labelled fitness dataset for this generation."
  (maybe-collect-teacher-dagger-garbage)
  (let ((seeds
          (if (official-guided-mode-p)
              (official-guided-take-seeds
               :training *online-fitness-episodes*)
              (make-online-fitness-episode-seeds))))
    (emit-message
     (format nil
             "Generation ~D teacher trace generation started: episodes=~D"
             *generation*
             (length seeds)))
    (let ((teacher-rows
            (generate-teacher-trace-rows
             *current-gym-environment-name* seeds)))
      (setf *teacher-training-dataset*
            (if (eq *teacher-forcing-rollout-mode* :teacher)
                (teacher-trace-to-dataset teacher-rows)
                (let* ((behavior-team (teacher-dagger-behavior-team))
                       (learner-rows
                         (generate-dagger-trace-rows
                          behavior-team
                          *current-gym-environment-name*
                          seeds)))
                  (if *recurrent-policy-enabled*
                      (append-teacher-dagger-replay-episodes learner-rows)
                      (append-teacher-dagger-replay learner-rows))
                  (let ((replay-sample
                          (if *recurrent-policy-enabled*
                              (sample-teacher-dagger-replay-episodes
                               (length teacher-rows))
                              (sample-teacher-dagger-replay
                               (length teacher-rows)))))
                    (emit-message
                     (format nil
                             "Generation ~D DAgger rollout: behavior=~A learner-rows=~D replay=~D sampled=~D teacher-rows=~D memory=~A"
                             *generation*
                             (team-id behavior-team)
                             (length learner-rows)
                             (if *recurrent-policy-enabled*
                                 (loop for episode
                                         in *teacher-dagger-replay-episodes*
                                       sum (length episode))
                                 (length *teacher-dagger-replay-rows*))
                             (length replay-sample)
                             (length teacher-rows)
                             (if *recurrent-policy-enabled*
                                 :recurrent
                                 :stateless)))
                    (when *last-dagger-diagnostics*
                      (emit-message
                       (format nil
                               "Generation ~D DAgger diagnostics: disagreement=~,2F%% first=~A absent-top8=~D teacher-rate=~,2F source-teacher=~D source-learner=~D mixed-return=~,3F"
                               *generation*
                               (* 100.0d0
                                  (getf *last-dagger-diagnostics*
                                        :disagreement-rate 0.0d0))
                               (or (getf *last-dagger-diagnostics*
                                         :first-disagreement-mean)
                                   :none)
                               (getf *last-dagger-diagnostics*
                                     :teacher-absent-top-8 0)
                               (getf *last-dagger-diagnostics*
                                     :teacher-mixing-rate 0.0d0)
                               (getf *last-dagger-diagnostics*
                                     :teacher-controlled-steps 0)
                               (getf *last-dagger-diagnostics*
                                     :learner-controlled-steps 0)
                               (getf *last-dagger-diagnostics*
                                     :mean-mixed-return 0.0d0))))
                    (teacher-trace-to-dataset
                     (append teacher-rows replay-sample)))))))
    (when *recurrent-policy-enabled*
      (ensure-recurrent-dataset-compatible
       *teacher-training-dataset* "Recurrent teacher training dataset"))
    (emit-message
     (format nil
             "Generation ~D teacher trace ready: rows=~D"
             *generation*
             (dataset-size *teacher-training-dataset*)))
    (when (behavioral-locality-active-p)
      (update-behavioral-probe-archive *teacher-training-dataset*))
    (when (official-guided-mode-p)
      (persist-official-guided-runtime-state))))

(defun teacher-forcing-training-fitness (team)
  "Evaluate TEAM against the generation-shared teacher trace."
  (unless *teacher-training-dataset*
    (error "Teacher training trace is not prepared."))
  (if *recurrent-policy-enabled*
      (semantic-ranked-sequence-fitness team *teacher-training-dataset*)
      (semantic-ranked-fitness team *teacher-training-dataset*)))

(defun teacher-forcing-reference-fitness (team)
  "Evaluate TEAM against the fixed teacher reference trace bank."
  (unless *teacher-reference-dataset*
    (error "Teacher reference trace is not configured."))
  (if *recurrent-policy-enabled*
      (semantic-ranked-sequence-fitness team *teacher-reference-dataset*)
      (semantic-ranked-fitness team *teacher-reference-dataset*)))
