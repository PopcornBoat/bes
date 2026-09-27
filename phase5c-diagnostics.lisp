(in-package :cl-tpg)

(defconstant +phase5c-rare-failure-protocol+
  :phase5c-rare-failure-diagnosis-v1)

(defun phase5c-read-form (path)
  "Read one Lisp form from PATH with standard reader settings."
  (with-open-file (in path :direction :input)
    (with-standard-io-syntax
      (read in))))

(defun phase5c-write-form (value path)
  "Write VALUE as one reproducible Lisp form to PATH."
  (ensure-directories-exist path)
  (with-open-file (out path
                       :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (with-standard-io-syntax
      (let ((*print-pretty* t)
            (*print-length* nil)
            (*print-level* nil))
        (prin1 value out)
        (terpri out))))
  path)

(defun phase5c-validation-failures
       (results label threshold &optional (root +cage2-evaluation-seed+))
  "Recover LABEL's exact validation seeds and returns below THRESHOLD.

RESULTS must be the complete ordered output of VALIDATE-BEST-TEAM. Seed draws
for earlier result blocks are consumed exactly as RUN-VALIDATION-ROLLOUTS did."
  #+sbcl
  (let ((*random-state* (sb-ext:seed-random-state root))
        (found nil))
    (dolist (result results)
      (let ((scores (getf result :scores)))
        (when scores
          (let ((seeds
                  (loop repeat (length scores)
                        collect (random 9999999))))
            (when (string= (getf result :label) label)
              (setf found
                    (loop for score in scores
                          for seed in seeds
                          for episode from 1
                          when (< score threshold)
                            collect
                              (list :episode episode
                                    :seed seed
                                    :recorded-return score))))))))
    (or found
        (error "Validation label ~S was absent or had no scores." label)))
  #-sbcl
  (declare (ignore results label threshold root))
  #-sbcl
  (error "Phase 5C validation-seed recovery currently requires SBCL."))

(defun phase5c-semantic-pairs (ranking)
  (mapcar #'semantic-action-category-pair ranking))

(defun phase5c-decision-record (decision)
  (let ((semantic (cage2-controller-decision-semantic-action decision)))
    (list :pair (semantic-action-category-pair semantic)
          :concrete-action
            (cage2-controller-decision-concrete-action decision)
          :rank (cage2-controller-decision-rank decision)
          :option (cage2-controller-decision-option decision)
          :fallback-p (cage2-controller-decision-fallback-p decision))))

(defun phase5c-load-policy (label path)
  "Load one independently deserialized policy and capture its provenance."
  (multiple-value-bind (team fitness metadata)
      (load-best-team path)
    (let ((format (or (getf metadata :terminal-action-format) :factored)))
      (unless (eq format :target-response-36)
        (error "Phase 5C expected TARGET-RESPONSE-36 for ~S, got ~S."
               label format))
      (ensure-team-observation-compatible team 62)
      (list :label label
            :path (namestring (pathname path))
            :fitness fitness
            :generation (getf metadata :generation)
            :metadata metadata
            :team team))))

(defun phase5c-policy-proposal-record (policy controller observation)
  "Query POLICY without changing controller or environment state."
  (let ((team (getf policy :team)))
    (multiple-value-bind (ranking path terminal-team)
        (execute-team-semantic-ranked team observation)
      (multiple-value-bind (winner registers)
          (execute-team-to-terminal team observation)
        (let* ((pairs (phase5c-semantic-pairs ranking))
               (decision
                 (cage2-controller-resolve-ranking controller ranking))
               (winner-pair
                 (semantic-action-category-pair
                  (make-semantic-action-from-terminal
                   (action-action (learner-action winner)) registers))))
          (unless (equal winner-pair (first pairs))
            (error "Top-1/ranking mismatch for ~S: ~S versus ~S."
                   (getf policy :label) winner-pair (first pairs)))
          (list :label (getf policy :label)
                :winning-learner (learner-id winner)
                :preferred-path (mapcar #'team-id path)
                :terminal-team (and terminal-team (team-id terminal-team))
                :ranking pairs
                :decision (phase5c-decision-record decision)
                :decision-object decision))))))

(defun phase5c-public-proposal-record (record)
  "Remove live Lisp objects before a proposal record is serialized."
  (loop for (key value) on record by #'cddr
        unless (eq key :decision-object)
          append (list key value)))

(defun phase5c-correction-p (mode disagreement-p first-disagreement)
  "Return true when MODE executes the teacher on this disagreement."
  (cond
    ((null mode) nil)
    ((eq mode :first-disagreement)
     (and disagreement-p (null first-disagreement)))
    ((eq mode :all-disagreements) disagreement-p)
    (t (error "Unknown Phase 5C correction mode: ~S" mode))))

(defun phase5c-intervention-decision
       (controller intervention teacher-decision timestep opening-pairs
        policy-observation teacher-pair behavior-pair)
  "Return the forced decision requested by INTERVENTION at TIMESTEP.

The proposal is resolved against the controller state produced only by the
real prefix.  Assertions copied from the baseline trace make trajectory drift
fail loudly instead of silently changing the counterfactual question."
  (when (and intervention
             (= timestep (getf intervention :step)))
    (when opening-pairs
      (error "Phase 5D cannot intervene during fixed opening step ~D."
             timestep))
    (let ((expected-observation
            (getf intervention :expected-policy-observation))
          (expected-teacher-pair
            (getf intervention :expected-teacher-pair))
          (expected-behavior-pair
            (getf intervention :expected-behavior-pair)))
      (when (and expected-observation
                 (not (equalp expected-observation policy-observation)))
        (error "Phase 5D state mismatch before intervention at step ~D."
               timestep))
      (when (and expected-teacher-pair
                 (not (equal expected-teacher-pair teacher-pair)))
        (error "Phase 5D teacher mismatch at step ~D: expected ~S, got ~S."
               timestep expected-teacher-pair teacher-pair))
      (when (and expected-behavior-pair
                 (not (equal expected-behavior-pair behavior-pair)))
        (error "Phase 5D behavior mismatch at step ~D: expected ~S, got ~S."
               timestep expected-behavior-pair behavior-pair)))
    (let* ((source (getf intervention :source))
           (requested-pair (getf intervention :pair))
           (decision
             (case source
               (:teacher teacher-decision)
               (:semantic-pair
                (cage2-controller-resolve-pair-ranking
                 controller (list requested-pair)))
               (otherwise
                (error "Unknown Phase 5D intervention source: ~S" source))))
           (resolved-pair
             (getf (phase5c-decision-record decision) :pair)))
      (when (and requested-pair
                 (not (equal requested-pair resolved-pair)))
        (error "Phase 5D requested ~S at step ~D, but controller resolved ~S."
               requested-pair timestep resolved-pair))
      decision)))

(defun phase5c-trace-episode
       (env controller policies behavior-label environment-name seed
        &key correction-mode intervention expected-prefix)
  "Trace one policy-controlled episode while querying every POLICY and teacher.

INTERVENTION optionally replaces exactly one decision after replaying and
verifying EXPECTED-PREFIX.  It exists for Phase 5D counterfactual credit; a
normal Phase 5C call is unchanged."
  (unless (find behavior-label policies
                :key (lambda (policy) (getf policy :label))
                :test #'eq)
    (error "Unknown Phase 5C behavior policy: ~S" behavior-label))
  (when intervention
    (let ((step (getf intervention :step)))
      (unless (and (integerp step) (not (minusp step)))
        (error "Phase 5D intervention needs a non-negative :STEP, got ~S."
               step))
      (unless (= (length expected-prefix) step)
        (error "Phase 5D expected prefix length ~D for intervention step ~D."
               (length expected-prefix) step))))
  (let ((steps nil)
        (episode-return 0.0d0)
        (first-disagreement nil)
        (correction-count 0)
        (intervention-executed-p nil))
    (call-with-fresh-policy-episode
     (lambda ()
       (cage2-controller-reset controller)
       (let ((observation (cl-gym::reset env seed)))
         (loop for timestep fixnum from 0
               do (let* ((policy-observation
                           (cage2-controller-observe controller observation))
                          (mask-before
                            (cage2-controller-decoy-mask controller))
                          (opening-pairs
                            (cl-gym::cage2-fixed-opening-action
                             environment-name timestep))
                          (teacher-ranking
                            (cage2-bline-heuristic-ranking
                             controller policy-observation))
                          (teacher-decision
                            (cage2-controller-resolve-ranking
                             controller teacher-ranking))
                          (proposals
                            (mapcar
                             (lambda (policy)
                               (phase5c-policy-proposal-record
                                policy controller policy-observation))
                             policies))
                          (behavior-record
                            (or (find behavior-label proposals
                                      :key (lambda (record)
                                             (getf record :label))
                                      :test #'eq)
                                (error "Missing behavior proposal ~S."
                                       behavior-label)))
                          (opening-decision
                            (and opening-pairs
                                 (cage2-controller-resolve-pair-ranking
                                  controller opening-pairs)))
                          (teacher-pair
                            (getf (phase5c-decision-record teacher-decision)
                                  :pair))
                          (behavior-pair
                            (getf (getf behavior-record :decision) :pair))
                          (disagreement-p
                            (and (not opening-pairs)
                                 (not (equal teacher-pair behavior-pair))))
                          (correction-p
                            (phase5c-correction-p
                             correction-mode disagreement-p
                             first-disagreement))
                          (intervention-decision
                            (phase5c-intervention-decision
                             controller intervention teacher-decision timestep
                             opening-pairs policy-observation teacher-pair
                             behavior-pair))
                          (intervention-p
                            (not (null intervention-decision)))
                          (executed-decision
                            (or opening-decision
                                intervention-decision
                                (and correction-p teacher-decision)
                                (getf behavior-record :decision-object)))
                          (teacher-rank
                            (and (not opening-pairs)
                                 (position teacher-pair
                                           (getf behavior-record :ranking)
                                           :test #'equal))))
                     (when (and disagreement-p (null first-disagreement))
                       (setf first-disagreement timestep))
                     (when correction-p
                       (incf correction-count))
                     (when intervention-p
                       (setf intervention-executed-p t))
                     (when (< timestep (length expected-prefix))
                       (let ((expected (elt expected-prefix timestep))
                             (selected
                               (cage2-controller-decision-concrete-action
                                executed-decision)))
                         (unless (= expected selected)
                           (error
                            "Phase 5D prefix mismatch at step ~D: expected concrete action ~D, selected ~D."
                            timestep expected selected))))
                     (multiple-value-bind
                           (next-observation reward terminated truncated info)
                         (cl-gym::step
                          env
                          (cl-gym::controller-decision->cage2-input
                           executed-decision))
                       (let ((actual
                               (cl-gym::cage2-info-value
                                info "concrete_action")))
                         (cl-gym::commit-controller-step
                          controller executed-decision info)
                         (incf episode-return (coerce reward 'double-float))
                         (push
                          (list
                           :step timestep
                           :observation (cl-gym:obs->array observation)
                           :policy-observation (copy-seq policy-observation)
                           :decoy-mask-before mask-before
                           :opening-pairs (copy-tree opening-pairs)
                           :teacher-ranking
                             (phase5c-semantic-pairs teacher-ranking)
                           :teacher-decision
                             (phase5c-decision-record teacher-decision)
                           :teacher-rank-in-behavior teacher-rank
                           :teacher-disagreement-p disagreement-p
                           :teacher-correction-p correction-p
                           :intervention-p intervention-p
                           :policy-proposals
                             (mapcar #'phase5c-public-proposal-record proposals)
                           :executed-source
                             (cond
                               (opening-pairs :fixed-opening)
                               (intervention-p :counterfactual-intervention)
                               (correction-p :teacher-correction)
                               (t behavior-label))
                           :executed-decision
                             (phase5c-decision-record executed-decision)
                           :actual-concrete-action actual
                           :reward (coerce reward 'double-float)
                           :cumulative-return episode-return
                           :decoy-mask-after
                             (cage2-controller-decoy-mask controller)
                           :terminated terminated
                           :truncated truncated)
                          steps))
                       (setf observation next-observation)
                       (when (or terminated truncated)
                         (return))))))))
    (list :protocol +phase5c-rare-failure-protocol+
          :behavior behavior-label
          :seed seed
          :environment environment-name
          :return episode-return
          :steps-executed (length steps)
          :first-teacher-disagreement first-disagreement
          :correction-mode (or correction-mode :none)
          :corrections-executed correction-count
          :intervention (copy-tree intervention)
          :intervention-executed-p intervention-executed-p
          :prefix-verified-p (and intervention-executed-p t)
          :catastrophic-p (< episode-return -100.0d0)
          :steps (nreverse steps))))

(defun phase5c-episode-summary (episode)
  (loop for (key value) on episode by #'cddr
        unless (eq key :steps)
          append (list key value)))

(defun run-phase5c-rare-failure-diagnosis
       (validation-result-path baseline-path candidate-path output-directory
        &key (environment-name "Cage2-b_line-100-v0")
             (validation-label "b_line-100")
             (failure-threshold -100.0d0))
  "Audit and trace candidate failures against the protected baseline."
  (let* ((output-directory
           (uiop:ensure-directory-pathname output-directory))
         (results (phase5c-read-form validation-result-path))
         (failures
           (phase5c-validation-failures
            results validation-label failure-threshold))
         (*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*decoy-order-mode* :fixed)
         (*cage2-opening-mode* :fixed)
         (*teacher-backend* :heuristic)
         (*recurrent-policy-enabled* nil)
         (*hamming-space-enabled* nil)
         (policies
           (list (phase5c-load-policy :phase4a baseline-path)
                 (phase5c-load-policy :v17 candidate-path)))
         (env nil)
         (controller nil)
         (episodes nil))
    (unless failures
      (error "Phase 5C found no ~A returns below ~A."
             validation-label failure-threshold))
    (phase5c-write-form
     (list :protocol +phase5c-rare-failure-protocol+
           :validation-result (namestring (pathname validation-result-path))
           :validation-root +cage2-evaluation-seed+
           :validation-label validation-label
           :failure-threshold failure-threshold
           :failures failures)
     (merge-pathnames "seed-audit.sexp" output-directory))
    (py4cl2:pyexec "import gymnasium as gym; import cage2_bridge")
    (setf env (cl-gym::make environment-name)
          controller
            (make-cage2-controller :decoy-order-profile :heuristic))
    (cl-gym::configure-cage2-controller-option-orders env controller)
    (unwind-protect
         (dolist (failure failures)
           (dolist (behavior '(:v17 :phase4a))
             (let ((episode
                     (phase5c-trace-episode
                      env controller policies behavior environment-name
                      (getf failure :seed))))
               (format t
                       "Phase5C trace behavior=~A seed=~D return=~,4F expected=~A~%"
                       behavior
                       (getf failure :seed)
                       (getf episode :return)
                       (and (eq behavior :v17)
                            (getf failure :recorded-return)))
               (finish-output)
               (push episode episodes))))
      (when env
        (ignore-errors (py4cl2:pymethod env "close"))))
    (setf episodes (nreverse episodes))
    (let* ((candidate-episodes
             (remove :v17 episodes :key (lambda (x) (getf x :behavior))
                     :test-not #'eq))
           (audit
             (loop for failure in failures
                   for episode in candidate-episodes
                   collect
                     (list :seed (getf failure :seed)
                           :recorded-return
                             (getf failure :recorded-return)
                           :replayed-return (getf episode :return)
                           :match-p
                             (< (abs (- (getf failure :recorded-return)
                                        (getf episode :return)))
                                1.0d-9))))
           (summary
             (list :protocol +phase5c-rare-failure-protocol+
                   :policies
                     (mapcar
                      (lambda (policy)
                        (list :label (getf policy :label)
                              :path (getf policy :path)
                              :fitness (getf policy :fitness)
                              :generation (getf policy :generation)))
                      policies)
                   :seed-audit audit
                   :all-candidate-returns-reproduced-p
                     (every (lambda (entry) (getf entry :match-p)) audit)
                   :episodes (mapcar #'phase5c-episode-summary episodes))))
      (phase5c-write-form
       episodes (merge-pathnames "trajectories.sexp" output-directory))
      (phase5c-write-form
       summary (merge-pathnames "summary.sexp" output-directory))
      (unless (getf summary :all-candidate-returns-reproduced-p)
        (error "Phase 5C candidate replay did not reproduce every saved return."))
      summary)))

(defun run-phase5c-causal-confirmation
       (validation-result-path candidate-path output-directory
        &key (environment-name "Cage2-b_line-100-v0")
             (validation-label "b_line-100")
             (failure-threshold -100.0d0))
  "Replay rare failures with one-shot and persistent teacher correction."
  (let* ((output-directory
           (uiop:ensure-directory-pathname output-directory))
         (results (phase5c-read-form validation-result-path))
         (failures
           (phase5c-validation-failures
            results validation-label failure-threshold))
         (*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*decoy-order-mode* :fixed)
         (*cage2-opening-mode* :fixed)
         (*teacher-backend* :heuristic)
         (*recurrent-policy-enabled* nil)
         (*hamming-space-enabled* nil)
         (policies (list (phase5c-load-policy :v17 candidate-path)))
         (modes '(:none :first-disagreement :all-disagreements))
         (env nil)
         (controller nil)
         (episodes nil))
    (py4cl2:pyexec "import gymnasium as gym; import cage2_bridge")
    (setf env (cl-gym::make environment-name)
          controller
            (make-cage2-controller :decoy-order-profile :heuristic))
    (cl-gym::configure-cage2-controller-option-orders env controller)
    (unwind-protect
         (dolist (failure failures)
           (dolist (mode modes)
             (let ((episode
                     (phase5c-trace-episode
                      env controller policies :v17 environment-name
                      (getf failure :seed)
                      :correction-mode (unless (eq mode :none) mode))))
               (format t
                       "Phase5C causal mode=~A seed=~D return=~,4F corrections=~D~%"
                       mode (getf failure :seed) (getf episode :return)
                       (getf episode :corrections-executed))
               (finish-output)
               (push episode episodes))))
      (when env
        (ignore-errors (py4cl2:pymethod env "close"))))
    (setf episodes (nreverse episodes))
    (let* ((paired
             (loop for failure in failures
                   for seed = (getf failure :seed)
                   for normal =
                     (find-if
                      (lambda (episode)
                        (and (= (getf episode :seed) seed)
                             (eq (getf episode :correction-mode) :none)))
                      episodes)
                   for first =
                     (find-if
                      (lambda (episode)
                        (and (= (getf episode :seed) seed)
                             (eq (getf episode :correction-mode)
                                 :first-disagreement)))
                      episodes)
                   for all =
                     (find-if
                      (lambda (episode)
                        (and (= (getf episode :seed) seed)
                             (eq (getf episode :correction-mode)
                                 :all-disagreements)))
                      episodes)
                   collect
                     (list
                      :seed seed
                      :recorded-return (getf failure :recorded-return)
                      :normal-return (getf normal :return)
                      :first-correction-return (getf first :return)
                      :first-correction-delta
                        (- (getf first :return) (getf normal :return))
                      :first-correction-rescued-p
                        (not (getf first :catastrophic-p))
                      :all-corrections-return (getf all :return)
                      :all-corrections-delta
                        (- (getf all :return) (getf normal :return))
                      :all-corrections-rescued-p
                        (not (getf all :catastrophic-p))
                      :all-correction-count
                        (getf all :corrections-executed))))
           (normal-audit-p
             (every
              (lambda (entry)
                (< (abs (- (getf entry :recorded-return)
                           (getf entry :normal-return)))
                   1.0d-9))
              paired))
           (summary
             (list
              :protocol :phase5c-causal-confirmation-v1
              :candidate (namestring (pathname candidate-path))
              :normal-returns-reproduced-p normal-audit-p
              :first-correction-rescues
                (count-if
                 (lambda (entry)
                   (getf entry :first-correction-rescued-p))
                 paired)
              :all-corrections-rescues
                (count-if
                 (lambda (entry)
                   (getf entry :all-corrections-rescued-p))
                 paired)
              :episodes (length paired)
              :paired-results paired)))
      (phase5c-write-form
       episodes (merge-pathnames "causal-trajectories.sexp" output-directory))
      (phase5c-write-form
       summary (merge-pathnames "causal-summary.sexp" output-directory))
      (unless normal-audit-p
        (error "Phase 5C causal replay failed to reproduce normal returns."))
      summary)))

(defun run-phase5c-rare-failure-diagnosis-from-environment ()
  "Run Phase 5C using paths supplied by the checked-in shell launcher."
  (flet ((required (name)
           (or (uiop:getenv name)
               (error "Required environment variable ~A is missing." name))))
    (run-phase5c-rare-failure-diagnosis
     (required "PHASE5C_VALIDATION_RESULT")
     (required "PHASE5C_BASELINE_CHECKPOINT")
     (required "PHASE5C_CANDIDATE_CHECKPOINT")
     (required "PHASE5C_OUTPUT_DIRECTORY"))))

(defun run-phase5c-causal-confirmation-from-environment ()
  "Run the Phase 5C causal replay from launcher-supplied paths."
  (flet ((required (name)
           (or (uiop:getenv name)
               (error "Required environment variable ~A is missing." name))))
    (run-phase5c-causal-confirmation
     (required "PHASE5C_VALIDATION_RESULT")
     (required "PHASE5C_CANDIDATE_CHECKPOINT")
     (required "PHASE5C_OUTPUT_DIRECTORY"))))
