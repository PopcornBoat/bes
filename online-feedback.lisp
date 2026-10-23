(in-package :cl-tpg)

;;; Online feedback uses complete official episodes. Stored observations are not
;;; used as a reward model, and the protected reference bank is monitoring only.

(defun online-feedback-active-p ()
  (and *online-feedback-racing-enabled*
       (eq *current-search-mode* :online)
       *current-gym-environment-name*
       (cl-gym:cage2-environment-p *current-gym-environment-name*)))

(defun reset-online-feedback-state ()
  (setf *online-feedback-racing-cursor* 0
        *online-feedback-promotion-cursor* 0
        *online-feedback-seed-root* *current-search-seed*
        *online-feedback-incumbent-version* 0
        *online-feedback-nominations* nil
        *online-feedback-random-seen* 0
        *online-feedback-probes* nil))

(defun online-feedback-state-copy ()
  (when (online-feedback-active-p)
    (list :protocol +online-feedback-protocol+
          :seed-root *online-feedback-seed-root*
          :racing-cursor *online-feedback-racing-cursor*
          :promotion-cursor *online-feedback-promotion-cursor*
          :incumbent-version *online-feedback-incumbent-version*)))

(defun restore-online-feedback-state (state)
  (when state
    (unless (and (eq (getf state :protocol) +online-feedback-protocol+)
                 (integerp (getf state :seed-root))
                 (every (lambda (value)
                          (and (integerp value) (not (minusp value))))
                        (list (getf state :racing-cursor)
                              (getf state :promotion-cursor)
                              (getf state :incumbent-version))))
      (error "Invalid online feedback checkpoint state: ~S" state))
    (setf *online-feedback-seed-root* (getf state :seed-root)
          *online-feedback-racing-cursor* (getf state :racing-cursor)
          *online-feedback-promotion-cursor* (getf state :promotion-cursor)
          *online-feedback-incumbent-version*
            (getf state :incumbent-version))))

(defun online-feedback-take-seeds (stream count)
  "Return fresh, disjoint racing or promotion seeds and advance its cursor."
  (unless (and (member stream '(:racing :promotion))
               (integerp count) (plusp count)
               (integerp *online-feedback-seed-root*))
    (error "Invalid online feedback seed request: ~S ~S" stream count))
  (let* ((cursor (ecase stream
                   (:racing *online-feedback-racing-cursor*)
                   (:promotion *online-feedback-promotion-cursor*)))
         (root (official-guided-derived-root
                *online-feedback-seed-root*
                (ecase stream (:racing 909031) (:promotion 909071))))
         (seeds (loop for offset below count
                      collect (official-guided-seed-at
                               stream root (+ cursor offset)))))
    (ecase stream
      (:racing (incf *online-feedback-racing-cursor* count))
      (:promotion (incf *online-feedback-promotion-cursor* count)))
    seeds))

(defun online-feedback-runtime-path ()
  (checkpoint-path *checkpoint-directory* ".online-feedback-state.lisp"))

(defun persist-online-feedback-state ()
  "Durably record cursors even when a racing worker rejects its challenger."
  (when (and (online-feedback-active-p) *checkpoint-directory*
             *best-fitness*)
    (write-readable-object-atomically
     (list :state (online-feedback-state-copy)
           :incumbent-fitness *best-fitness*)
     (online-feedback-runtime-path))))

(defun restore-online-feedback-runtime-state (metadata)
  "Use a newer sidecar only if it belongs to the saved incumbent."
  (let ((saved (getf metadata :online-feedback-state)))
    (restore-online-feedback-state saved)
    (when (and saved *checkpoint-directory*
               (probe-file (online-feedback-runtime-path)))
      (let* ((journal (read-readable-object
                       (online-feedback-runtime-path)))
             (candidate (getf journal :state)))
        (when (and candidate
                   (= (getf candidate :seed-root)
                      (getf saved :seed-root))
                   (= (getf candidate :incumbent-version)
                      (getf saved :incumbent-version))
                   (fitness-values-equivalent-p
                    (getf journal :incumbent-fitness)
                    (getf metadata :fitness))
                   (>= (getf candidate :racing-cursor)
                       (getf saved :racing-cursor))
                   (>= (getf candidate :promotion-cursor)
                       (getf saved :promotion-cursor)))
          (restore-online-feedback-state candidate))))))

(defun online-feedback-constant-sites (team)
  "Find constants in the root learners' effective bid slices."
  (loop for learner in (team-learners team)
        for learner-index from 0
        for program = (learner-program learner)
        for instructions = (program-instructions program)
        append
        (loop for instruction-index in
                (getf (analyze-program-effective-code program)
                      :effective-indices)
              for instruction = (aref instructions instruction-index)
              append
              (loop for slot in (instruction-source-slots instruction)
                    when (eq (instruction-source-type-at instruction slot)
                             :const)
                      collect (list learner-index instruction-index slot)))))

(defun online-feedback-perturb-child (parent site change)
  "Clone PARENT, modifying exactly one effective bid constant."
  (destructuring-bind (learner-index instruction-index slot) site
    (let* ((child (clone-team parent))
           (learner (nth learner-index (team-learners child)))
           (instruction
             (aref (program-instructions (learner-program learner))
                   instruction-index))
           (old (instruction-source-value-at instruction slot)))
      (set-instruction-source instruction slot :const (+ old change))
      child)))

(defun maybe-create-online-feedback-probes ()
  "Spend two ordinary offspring slots on opposite single-constant changes."
  (when (and (online-feedback-active-p)
             (<= (+ (length (root-teams)) 2) *population-size*))
    (let* ((eligible
             (loop for parent in (root-teams)
                   for sites = (online-feedback-constant-sites parent)
                   when sites collect (cons parent sites))))
      (when eligible
        (let* ((entry (random-choice eligible))
               (parent (car entry))
               (site (random-choice (cdr entry)))
               (plus (online-feedback-perturb-child
                      parent site +online-feedback-constant-step+))
               (minus (online-feedback-perturb-child
                       parent site (- +online-feedback-constant-step+))))
          (setf *online-feedback-probes*
                (list :parent parent :plus plus :minus minus :site site))
          t)))))

(defun online-feedback-directional-result (scores)
  "Measure both signs against their unchanged parent on the shared episode."
  (when *online-feedback-probes*
    (let* ((probe *online-feedback-probes*)
           (parent (assoc (getf probe :parent) scores :test #'eq))
           (plus (assoc (getf probe :plus) scores :test #'eq))
           (minus (assoc (getf probe :minus) scores :test #'eq))
           (winner
             (when (and parent plus minus)
               (if (> (cdr plus) (cdr minus)) plus minus))))
      (setf *online-feedback-probes* nil)
      (when winner
        (emit-message
         (format nil
                 "Online paired constant probe: generation=~D site=~S parent=~,4F plus-delta=~,4F minus-delta=~,4F (one shared seed; provisional)."
                 *generation* (getf probe :site) (cdr parent)
                 (- (cdr plus) (cdr parent))
                 (- (cdr minus) (cdr parent))))
        (when (> (cdr winner) (cdr parent))
          winner)))))

(defun online-feedback-priority-records ()
  (remove :random *online-feedback-nominations*
          :key (lambda (record) (getf record :lane))))

(defun online-feedback-offer-nomination (entry delta lane)
  "Keep at most four high paired-delta proposals plus one reservoir control."
  (when entry
    (let* ((team (car entry))
           (id (team-id team))
           (existing (find id *online-feedback-nominations*
                           :key (lambda (record) (getf record :team-id))
                           :test #'string=)))
      (unless (or existing
                  (and *best-team*
                       (string= id (team-id *best-team*))))
        (if (eq lane :random)
            (progn
              (incf *online-feedback-random-seen*)
              (when (zerop (random *online-feedback-random-seen*))
                (setf *online-feedback-nominations*
                      (remove :random *online-feedback-nominations*
                              :key (lambda (record) (getf record :lane))))
                (push (list :team (deep-copy-team-via-serialization team)
                            :team-id id :generation *generation*
                            :training-fitness (cdr entry) :delta delta
                            :lane lane)
                      *online-feedback-nominations*)))
            (let* ((priority (online-feedback-priority-records))
                   (limit (1- +online-feedback-nomination-limit+))
                   (worst (first (sort (copy-list priority) #'<
                                       :key (lambda (record)
                                              (getf record :delta))))))
              (when (or (< (length priority) limit)
                        (> delta (getf worst :delta)))
                (when (>= (length priority) limit)
                  (setf *online-feedback-nominations*
                        (remove worst *online-feedback-nominations*
                                :test #'eq)))
                (push (list :team (deep-copy-team-via-serialization team)
                            :team-id id :generation *generation*
                            :training-fitness (cdr entry) :delta delta
                            :lane lane)
                      *online-feedback-nominations*))))))))

(defun online-feedback-nominate-generation (scores sorted)
  "Nominate from one common-seed generation without comparing raw returns
across generations. The one-seed delta only nominates; fresh racing decides."
  (when (and (online-feedback-active-p) *best-team* sorted)
    (let* ((seeds *online-fitness-episode-seeds*)
           (incumbent
             (cage2-fitness-on-seeds
              *best-team* *current-gym-environment-name* seeds))
           (directional (online-feedback-directional-result scores))
           (random-entry (random-choice scores)))
      (online-feedback-offer-nomination
       (first sorted) (- (cdar sorted) incumbent) :generation-best)
      (when directional
        (online-feedback-offer-nomination
         directional (- (cdr directional) incumbent) :directional))
      (online-feedback-offer-nomination
       random-entry (- (cdr random-entry) incumbent) :random))))

(defun online-feedback-continue-p (candidate-returns incumbent-returns)
  "Early stages reject only an unmistakable regression."
  (let* ((differences (mapcar #'- candidate-returns incumbent-returns))
         (mean (arithmetic-mean differences))
         (se (sample-standard-error differences)))
    (values (>= (+ mean (* 2.0d0 se)) -5.0d0) mean se)))

(defun online-feedback-promotion-p (candidate-returns incumbent-returns)
  "Only a positive paired one-SE margin on fresh seeds can promote."
  (online-reference-promotion-p candidate-returns incumbent-returns))

(defun launch-online-feedback-batch ()
  "Snapshot a bounded nomination batch and start its independent evaluator."
  (let* ((generation *generation*)
         (records (reverse *online-feedback-nominations*))
         (incumbent-path
           (online-candidate-path generation "feedback-incumbent" "lisp"))
         (request-path
           (online-candidate-path generation "feedback-request" "lisp"))
         (result-path
           (online-candidate-path generation "feedback-result" "lisp"))
         (log-path
           (online-candidate-path generation "feedback-worker" "log"))
         (worker-script
           (merge-pathnames
            "scripts/run-online-candidate-evaluation.lisp"
            (asdf:system-source-directory :cl-tpg)))
         (candidates
           (loop for record in records
                 for index from 0
                 for path =
                   (online-candidate-path
                    generation (format nil "feedback-~D" index) "lisp")
                 do (write-online-candidate-checkpoint
                     (getf record :team)
                     (getf record :training-fitness)
                     (getf record :generation) path)
                 collect (list :path (namestring path)
                               :generation (getf record :generation)
                               :training-fitness
                                 (getf record :training-fitness)
                               :lane (getf record :lane)))))
    (write-online-candidate-checkpoint
     *best-team* *best-fitness* generation incumbent-path)
    (write-readable-object-atomically
     (list :protocol +online-feedback-protocol+
           :result-path (namestring result-path)
           :incumbent-path (namestring incumbent-path)
           :incumbent-version *online-feedback-incumbent-version*
           :incumbent-fitness *best-fitness*
           :candidates candidates
           :racing-stages (copy-list +online-feedback-racing-stages+)
           :racing-seeds
             (online-feedback-take-seeds
              :racing (car (last +online-feedback-racing-stages+)))
           :promotion-seeds
             (online-feedback-take-seeds
              :promotion +online-feedback-promotion-episodes+)
           :gym-environment-name *current-gym-environment-name*
           :num-observations *num-observations*
           :num-actions *num-actions*
           :decoy-order-mode *decoy-order-mode*
           :cage2-opening-mode *cage2-opening-mode*
           :recurrent-policy-enabled *recurrent-policy-enabled*
           :teacher-backend *teacher-backend*
           :hamming-space-enabled *hamming-space-enabled*
           :hamming-dataset-name *hamming-dataset-name*)
     request-path)
    (setf *online-candidate-process*
            (uiop:launch-program
             (list "sbcl" "--dynamic-space-size" "4096"
                   "--noinform" "--non-interactive"
                   "--load" (namestring worker-script)
                   "--end-toplevel-options" (namestring request-path))
             :input nil :output log-path :error-output :output
             :if-output-exists :supersede :ignore-error-status t)
          *online-candidate-job*
            (list :protocol +online-feedback-protocol+
                  :generation generation :request-path request-path
                  :result-path result-path :log-path log-path)
          *online-candidate-next-submit-generation*
            (+ generation +online-candidate-evaluation-interval+)
          *online-feedback-nominations* nil
          *online-feedback-random-seen* 0)
    (emit-message
     (format nil
             "Generation ~D submitted ~D online feedback nominees: shared fresh racing=~S, independent promotion=~D."
             generation (length candidates) +online-feedback-racing-stages+
             +online-feedback-promotion-episodes+))
    (persist-online-feedback-state)))

(defun consume-online-feedback-result (result)
  "Install only an independently promoted graph, never a one-seed probe."
  (let ((generation (getf result :candidate-generation)))
    (cond
      ((eq (getf result :status) :error)
       (emit-message
        (format nil "Online feedback evaluator failed: ~A"
                (getf result :message))))
      ((or (/= (getf result :incumbent-version)
               *online-feedback-incumbent-version*)
           (not (fitness-values-equivalent-p
                 (getf result :incumbent-fitness) *best-fitness*)))
       (emit-message
        "Discarded online feedback result for a superseded incumbent."))
      ((not (getf result :accepted))
       (emit-message
        (format nil
                "Online feedback batch rejected at ~A: paired-delta=~A margin=~A."
                (getf result :stage) (getf result :paired-delta)
                (getf result :margin))))
      (t
       (let ((candidate (load-best-team (getf result :candidate-path))))
         (ensure-team-observation-compatible candidate *num-observations*)
         (unless (= (length (getf result :candidate-scores))
                    +cage2-online-reference-episodes+)
           (error "Accepted online feedback result lacks monitor scores."))
         (setf *best-team* (deep-copy-team-via-serialization candidate)
               *best-fitness* (getf result :candidate-fitness)
               *online-best-reference-scores*
                 (copy-list (getf result :candidate-scores)))
         (incf *online-feedback-incumbent-version*)
         (emit-message
          (format nil
                  "NEW GLOBAL BEST: online feedback generation=~D lane=~A fresh paired-delta=~,4F margin=~,4F fixed-monitor=~,4F."
                  generation (getf result :candidate-lane)
                  (getf result :paired-delta) (getf result :margin)
                  *best-fitness*))
         (let ((*generation* generation))
           (save-best-team))
         (persist-online-feedback-state))))))

(defun run-online-feedback-batch (request)
  "Run one independent multi-candidate common-seed tournament."
  (let* ((result-path (pathname (getf request :result-path)))
         (started (get-universal-time)))
    (labels ((publish (result)
               (write-readable-object-atomically
                (append (list :protocol +online-feedback-protocol+)
                        result
                        (list :elapsed-seconds
                              (- (get-universal-time) started)))
                result-path))
             (episode-returns (team seeds)
               (loop for seed in seeds
                     collect (cl-gym:rollout
                              team *current-gym-environment-name* seed))))
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
                 (*teacher-backend* (getf request :teacher-backend))
                 (*recurrent-policy-enabled*
                   (not (null (getf request :recurrent-policy-enabled))))
                 (*hamming-space-enabled*
                   (getf request :hamming-space-enabled))
                 (*hamming-dataset-name*
                   (getf request :hamming-dataset-name))
                 (*factored-actions-enabled* t)
                 (incumbent (load-best-team (getf request :incumbent-path)))
                 (metadata *loaded-checkpoint-metadata*)
                 (profile (multiple-value-list
                           (checkpoint-execution-profile
                            metadata "Online feedback incumbent")))
                 (*terminal-action-format* (first profile))
                 (*instruction-set-profile* (second profile))
                 (*read-only-register-profile* (third profile))
                 (racing-seeds (getf request :racing-seeds))
                 (racing-stages
                   (or (getf request :racing-stages)
                       +online-feedback-racing-stages+))
                 (promotion-seeds (getf request :promotion-seeds))
                 (contenders
                   (loop for record in (getf request :candidates)
                         collect (list :path (getf record :path)
                                       :generation (getf record :generation)
                                       :training-fitness
                                         (getf record :training-fitness)
                                       :lane (getf record :lane)
                                       :team (load-best-team
                                              (getf record :path))
                                       :returns nil)))
                 (incumbent-returns nil)
                 (prior-stage 0))
            (configure-hamming-observation-space)
            (ensure-team-observation-compatible incumbent *num-observations*)
            (dolist (contender contenders)
              (ensure-team-observation-compatible
               (getf contender :team) *num-observations*))
            (unless (and contenders racing-stages promotion-seeds
                         (every (lambda (stage)
                                  (and (integerp stage)
                                       (> stage 0)
                                       (<= stage (length racing-seeds))))
                                racing-stages)
                         (equal racing-stages
                                (sort (copy-list racing-stages) #'<)))
              (error "Invalid online feedback racing request."))
            (dolist (stage racing-stages)
              (let ((fresh (subseq racing-seeds prior-stage stage)))
                (setf incumbent-returns
                      (append incumbent-returns
                              (episode-returns incumbent fresh)))
                (dolist (contender contenders)
                  (setf (getf contender :returns)
                        (append (getf contender :returns)
                                (episode-returns
                                 (getf contender :team) fresh))))
                (setf contenders
                      (remove-if-not
                       (lambda (record)
                         (online-feedback-continue-p
                          (getf record :returns) incumbent-returns))
                       contenders)
                      prior-stage stage)
                (format t "~&Online feedback racing: stage=~D survivors=~D~%"
                        stage (length contenders))
                (finish-output)
                (when (null contenders)
                  (publish
                   (list :status :complete :accepted nil :stage :racing
                         :incumbent-version
                           (getf request :incumbent-version)
                         :incumbent-fitness
                           (getf request :incumbent-fitness)
                         :paired-delta nil :margin nil))
                  (return-from run-online-feedback-batch t))))
            (let* ((winner
                     (reduce
                      (lambda (left right)
                        (if (> (arithmetic-mean
                                (mapcar #'- (getf left :returns)
                                        incumbent-returns))
                               (arithmetic-mean
                                (mapcar #'- (getf right :returns)
                                        incumbent-returns)))
                            left right))
                      contenders))
                   (candidate-promotion
                     (episode-returns (getf winner :team) promotion-seeds))
                   (incumbent-promotion
                     (episode-returns incumbent promotion-seeds)))
              (multiple-value-bind (accepted delta margin)
                  (online-feedback-promotion-p
                   candidate-promotion incumbent-promotion)
                (format t "~&Online feedback promotion: accepted=~S paired-delta=~,4F margin=~,4F~%"
                        accepted delta margin)
                (finish-output)
                (let* ((monitor-scores
                         (and accepted
                              (episode-returns
                               (getf winner :team)
                               (make-online-fitness-episode-seeds
                                +cage2-evaluation-seed+
                                +cage2-online-reference-episodes+))))
                       (fitness
                         (if accepted
                             (arithmetic-mean monitor-scores)
                             (arithmetic-mean candidate-promotion))))
                  (publish
                   (list :status :complete :accepted accepted
                         :stage :promotion
                         :candidate-path (getf winner :path)
                         :candidate-generation (getf winner :generation)
                         :candidate-training-fitness
                           (getf winner :training-fitness)
                         :candidate-fitness fitness
                         :candidate-scores monitor-scores
                         :candidate-lane (getf winner :lane)
                         :incumbent-version
                           (getf request :incumbent-version)
                         :incumbent-fitness
                           (getf request :incumbent-fitness)
                         :paired-delta delta :margin margin
                         :racing-seeds (copy-list racing-seeds)
                         :promotion-seeds (copy-list promotion-seeds)))))))
        (error (condition)
          (publish
           (list :status :error :accepted nil
                 :incumbent-version (getf request :incumbent-version)
                 :incumbent-fitness (getf request :incumbent-fitness)
                 :message (princ-to-string condition)))))))
  t)
