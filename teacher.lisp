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

(defun generate-teacher-trace-dataset (environment-name episode-seeds)
  "Generate one teacher-controlled trace bank through the Python bridge.

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
                            chunk)
                           "chunk"))
                   remaining (nthcdr count remaining)))
    (teacher-trace-to-dataset all-rows)))

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
  (setf *factored-actions-enabled* t
        *offline-training-dataset* nil
        *offline-reference-dataset* nil
        *offline-fitness-batch-indices* nil
        *current-dataset-fingerprint* nil
        *teacher-training-dataset* nil
        *teacher-reference-dataset* nil)
  (configure-hamming-observation-space)
  (emit-message
   (format nil
           "Teacher reference generation started: episodes=~D environment=~A"
           +teacher-reference-episodes+
           environment-name))
  (setf *teacher-reference-dataset*
        (generate-teacher-trace-dataset
         environment-name
         (make-teacher-reference-seeds)))
  (emit-message
   (format nil
           "Teacher reference ready: rows=~D"
           (dataset-size *teacher-reference-dataset*)))
  (setf *fitness-fn* #'teacher-forcing-training-fitness))

(defun prepare-teacher-training-dataset ()
  "Generate the current generation's shared teacher-controlled episodes."
  (let ((seeds (make-online-fitness-episode-seeds)))
    (emit-message
     (format nil
             "Generation ~D teacher trace generation started: episodes=~D"
             *generation*
             (length seeds)))
    (setf *teacher-training-dataset*
          (generate-teacher-trace-dataset
           *current-gym-environment-name*
           seeds))
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
