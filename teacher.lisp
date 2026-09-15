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
         (truncations (make-array count :initial-element 0)))
    (when (zerop count)
      (error "Teacher trace generation returned no rows."))
    (loop for raw-row in row-list
          for index fixnum from 0
          for row = (teacher-sequence-list raw-row "row")
          do (unless (= (length row) 4)
               (error "Teacher row must contain four fields, got ~S." row))
             (destructuring-bind
                   (raw-observation raw-selected raw-ranking decoy-mask)
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
                 (setf (aref observations index) observation
                       (aref actions index)
                         (list (first selected) (second selected) 0)
                       (aref rankings index) ranking
                       (aref masks index) decoy-mask))))
    (%make-dataset
     :observations observations
     :actions actions
     :rewards rewards
     :terminations terminations
     :truncations truncations
     :teacher-actions (make-array count :initial-element nil)
     :decoy-masks masks
     :semantic-rankings rankings
     :size count
     :action-format :semantic-ranked
     :source-path nil)))

(defconstant +teacher-trace-chunk-size+ 5
  "Maximum episodes per bridge call, bounding stop-request latency.")

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
                            include-opening-p)
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
                     (first-available-decoy-option target decoy-mask))
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
  "Run BEHAVIOR-TEAM and label its visited states with the frozen teacher.

The fixed three-step episode opening remains controller-owned. The teacher is
advanced on those same observations but never acts in the environment; from
step three onward only BEHAVIOR-TEAM controls the trajectory."
  (unless behavior-team
    (error "DAgger requires a behavior team."))
  (py4cl2:pyexec
   "import gymnasium as gym; import cage2_bridge; import cage2_bridge.teacher")
  (let* ((env (cl-gym::make environment-name))
         (teacher
           (py4cl2:pycall
            "cage2_bridge.teacher.TeacherPolicy"
            (teacher-red-agent-name environment-name)))
         (rows nil))
    (cl-gym::configure-cage2-option-orders env behavior-team)
    (unwind-protect
         (dolist (episode-seed episode-seeds)
           (abort-search-if-requested)
           (py4cl2:pymethod teacher "reset")
           (let ((observation (cl-gym::reset env episode-seed)))
             (loop for timestep fixnum from 0
                   do (when (zerop (mod timestep 10))
                        (abort-search-if-requested))
                      (let* ((ranking
                               (mapcar
                                (lambda (pair)
                                  (teacher-sequence-list pair "ranking pair"))
                                (teacher-sequence-list
                                 (py4cl2:pymethod
                                  teacher "rank" observation)
                                 "ranking")))
                             (decoy-mask
                               (teacher-observation-decoy-mask observation))
                             (selected
                               (resolve-teacher-pair-ranking
                                ranking decoy-mask))
                             (opening-action
                               (cl-gym::cage2-fixed-opening-action
                                environment-name timestep))
                             (action
                               (or opening-action
                                   (cl-gym::execute-policy-action
                                    behavior-team observation environment-name))))
                        ;; Only states where the learner owns the action enter
                        ;; imitation fitness. The teacher labels the learner's
                        ;; observation without changing the environment state.
                        (unless opening-action
                          (push
                           (list (coerce observation 'list)
                                 (copy-list selected)
                                 (copy-tree ranking)
                                 decoy-mask)
                           rows))
                        (multiple-value-bind
                              (next-observation reward terminated truncated info)
                            (cl-gym::step env action)
                          (declare (ignore reward info))
                          (setf observation next-observation)
                          (when (or terminated truncated)
                            (return)))))))
      (ignore-errors (py4cl2:pymethod env "close")))
    (nreverse rows)))

(defun append-teacher-dagger-replay (rows)
  "Append ROWS and keep only the newest bounded DAgger replay entries."
  (let* ((combined (nconc *teacher-dagger-replay-rows* (copy-list rows)))
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
  (setf *factored-actions-enabled* t
        *offline-training-dataset* nil
        *offline-reference-dataset* nil
        *offline-fitness-batch-indices* nil
        *current-dataset-fingerprint* nil
        *teacher-training-dataset* nil
        *teacher-reference-dataset* nil
        *teacher-dagger-replay-rows* nil
        *teacher-dagger-random-state*
          (sb-ext:seed-random-state
           (+ *current-search-seed* 32452843)))
  (configure-hamming-observation-space)
  (emit-message
   (format nil
           "Teacher reference generation started: episodes=~D environment=~A opening=~A rollout=~A~A"
           +teacher-reference-episodes+
           environment-name
           *cage2-opening-mode*
           *teacher-forcing-rollout-mode*
           (if (eq *cage2-opening-mode* :fixed)
               "; first three controller steps excluded from TPG fitness"
               "")))
  (setf *teacher-reference-dataset*
        (generate-teacher-trace-dataset
         environment-name
         (make-teacher-reference-seeds)))
  (emit-message
   (format nil
           "Teacher reference ready: rows=~D"
           (dataset-size *teacher-reference-dataset*)))
  (setf *fitness-fn* #'teacher-forcing-training-fitness))

(defun teacher-dagger-behavior-team ()
  "Return the policy that owns this generation's DAgger rollout."
  (or *best-team*
      (first (root-teams))
      (error "DAgger cannot choose a behavior team from an empty population.")))

(defun prepare-teacher-training-dataset ()
  "Build one shared teacher-labelled fitness dataset for this generation."
  (let ((seeds (make-online-fitness-episode-seeds)))
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
                  (append-teacher-dagger-replay learner-rows)
                  (let ((replay-sample
                          (sample-teacher-dagger-replay
                           (length teacher-rows))))
                    (emit-message
                     (format nil
                             "Generation ~D DAgger rollout: behavior=~A learner-rows=~D replay=~D sampled=~D teacher-rows=~D"
                             *generation*
                             (team-id behavior-team)
                             (length learner-rows)
                             (length *teacher-dagger-replay-rows*)
                             (length replay-sample)
                             (length teacher-rows)))
                    (teacher-trace-to-dataset
                     (append teacher-rows replay-sample)))))))
    (emit-message
     (format nil
             "Generation ~D teacher trace ready: rows=~D"
             *generation*
             (dataset-size *teacher-training-dataset*)))))

(defun teacher-forcing-training-fitness (team)
  "Evaluate TEAM against the generation-shared teacher trace."
  (unless *teacher-training-dataset*
    (error "Teacher training trace is not prepared."))
  (semantic-ranked-fitness team *teacher-training-dataset*))

(defun teacher-forcing-reference-fitness (team)
  "Evaluate TEAM against the fixed teacher reference trace bank."
  (unless *teacher-reference-dataset*
    (error "Teacher reference trace is not configured."))
  (semantic-ranked-fitness team *teacher-reference-dataset*))
