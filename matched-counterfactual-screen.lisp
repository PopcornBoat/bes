(in-package :cl-tpg)

(defparameter +matched-counterfactual-protocol+
  :matched-counterfactual-level2-v1)

(defun matched-counterfactual-lane-pair (lane key)
  (let* ((index (getf lane key))
         (pair (semantic-36-index-pair index)))
    (unless (and pair (= (first pair) (getf lane :target)))
      (error "Manifest action ~S does not match lane target ~S."
             index (getf lane :target)))
    pair))

(defun matched-counterfactual-bits-match-p (lane observation)
  (loop for value in (getf lane :bits)
        for index from (getf lane :offset)
        always (= value (aref observation index))))

(defun matched-counterfactual-controller-decision
       (resolver before pair)
  "Purely resolve PAIR from the actual pre-action Controller state."
  (replace (cage2-controller-scan-state resolver)
           (getf before :scan))
  (setf (cage2-controller-decoy-mask resolver)
        (getf before :decoy-mask)
        (cage2-controller-step resolver)
        (getf before :step))
  (let ((decision
          (cage2-controller-resolve-pair-ranking resolver (list pair))))
    (when (and (not (cage2-controller-decision-fallback-p decision))
               (equal pair (official-pilot-pair decision)))
      decision)))

(defun matched-counterfactual-find-event
       (team resolver lane baseline)
  "First baseline step matching the frozen group and both available actions."
  (let ((structural-pair
          (matched-counterfactual-lane-pair lane :structural-index))
        (random-pair
          (matched-counterfactual-lane-pair lane :random-index)))
    (loop for state across (getf baseline :steps)
          for step = (getf state :step)
          when (>= step 3)
            do (let ((observation
                       (getf state :policy-observation)))
                 (when (matched-counterfactual-bits-match-p
                        lane observation)
                   (multiple-value-bind (ranking path terminal)
                       (execute-team-semantic-ranked team observation)
                     (declare (ignore ranking path))
                     (when (and terminal
                                (string= (team-id terminal)
                                         (getf lane :terminal)))
                       (let* ((before
                                (getf state :controller-before))
                              (structural
                                (matched-counterfactual-controller-decision
                                 resolver before structural-pair))
                              (random
                                (matched-counterfactual-controller-decision
                                 resolver before random-pair))
                              (incumbent
                                (getf state :incumbent-concrete)))
                         (when (and structural random
                                    (/= incumbent
                                        (cage2-controller-decision-concrete-action
                                         structural))
                                    (/= incumbent
                                        (cage2-controller-decision-concrete-action
                                         random)))
                           (return
                             (list :state state
                                   :structural-concrete
                                     (cage2-controller-decision-concrete-action
                                      structural)
                                   :random-concrete
                                     (cage2-controller-decision-concrete-action
                                      random))))))))))))

(defun matched-counterfactual-assert-manifest (manifest)
  (unless (and (eq (getf manifest :protocol)
                   +matched-counterfactual-protocol+)
               (= (length (getf manifest :lanes)) 5)
               (stringp (getf manifest :level1-lanes-sha256)))
    (error "Incompatible frozen Level-2 lane manifest."))
  (loop for lane in (getf manifest :lanes)
        for position from 0
        do (unless (and (= (getf lane :id) position)
                        (= (length (getf lane :bits)) 4)
                        (<= 0 (getf lane :offset) 48)
                        (not (equal
                              (matched-counterfactual-lane-pair
                               lane :structural-index)
                              (matched-counterfactual-lane-pair
                               lane :random-index))))
             (error "Invalid or colliding lane ~S." lane)))
  manifest)

(defun run-matched-counterfactual-screen
       (checkpoint manifest-path output-file
        &key (seed-root 12000000) (count 100) (cap 20))
  "Compare frozen structural/random nominations at identical official states."
  (unless (and (integerp seed-root) (<= 0 seed-root)
               (integerp count) (plusp count)
               (integerp cap) (plusp cap))
    (error "Invalid Level-2 seed root, count or cap."))
  (let* ((*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*instruction-set-profile* :reduced-eq)
         (*read-only-register-profile* :cage2-categorical-v1)
         (*decoy-order-mode* :fixed)
         (*cage2-opening-mode* :fixed)
         (*recurrent-policy-enabled* nil)
         (*hamming-space-enabled* nil)
         (environment-name "Cage2-meander-100-v0")
         (manifest
           (matched-counterfactual-assert-manifest
            (rare-failure-read-form manifest-path)))
         (lanes (getf manifest :lanes))
         (counts (make-array (length lanes) :initial-element 0))
         (policy (rare-failure-load-policy :matched-screen checkpoint))
         (team (getf policy :team))
         (metadata (getf policy :metadata))
         (env nil)
         (controller nil)
         (resolver nil)
         (baseline-transitions 0)
         (structural-transitions 0)
         (random-transitions 0))
    (setf *instruction-set-profile*
          (or (getf metadata :instruction-set-profile) :reduced-eq)
          *read-only-register-profile*
          (or (getf metadata :read-only-register-profile)
              :cage2-categorical-v1))
    (py4cl2:pyexec
     "import gymnasium as gym, cage2_bridge, pickle, random, hashlib
def _bes_official_state_digest(env):
    base = env.unwrapped
    state = (base.cyborg.environment_controller.state,
             random.getstate(),
             tuple(float(x) for x in base.scan_state.state),
             tuple((k, tuple(sorted(v))) for k, v in sorted(base.used_decoys.items())),
             base.current_step)
    return hashlib.sha256(pickle.dumps(state, protocol=4)).hexdigest()")
    (setf env (cl-gym::make environment-name)
          controller
            (make-cage2-controller
             :decoy-order-profile
               (cage2-heuristic-controller-profile environment-name))
          resolver
            (make-cage2-controller
             :decoy-order-profile
               (cage2-heuristic-controller-profile environment-name)))
    (cl-gym::configure-cage2-controller-option-orders env controller)
    (cl-gym::configure-cage2-controller-option-orders env resolver)
    (unwind-protect
         (with-open-file (out output-file :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
           (format out
                   "lane_id~Cseed~Cstep~Cterminal~Cstate_digest~Cbaseline_return~Cstructural_return~Crandom_return~Cstructural_delta~Crandom_delta~Cstructural_minus_random~Cbaseline_concrete~Cstructural_concrete~Crandom_concrete~Cbaseline_transitions~Cstructural_transitions~Crandom_transitions~%"
                   #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab
                   #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab)
           (loop for i below count
                 for seed = (+ seed-root (* 197 i))
                 for baseline =
                   (official-pilot-run-episode
                    env controller team environment-name seed)
                 do (incf baseline-transitions
                          (length (getf baseline :steps)))
                    (dolist (lane lanes)
                      (let ((id (getf lane :id)))
                        (when (< (aref counts id) cap)
                          (let ((event
                                  (matched-counterfactual-find-event
                                   team resolver lane baseline)))
                            (when event
                              (let* ((state (getf event :state))
                                     (step (getf state :step))
                                     (prefix (getf baseline :steps))
                                     (structural-pair
                                       (matched-counterfactual-lane-pair
                                        lane :structural-index))
                                     (random-pair
                                       (matched-counterfactual-lane-pair
                                        lane :random-index))
                                     (structural
                                       (official-pilot-run-episode
                                        env controller team environment-name
                                        seed
                                        :intervention-step step
                                        :intervention-pair structural-pair
                                        :expected-prefix prefix))
                                     (random
                                       (official-pilot-run-episode
                                        env controller team environment-name
                                        seed
                                        :intervention-step step
                                        :intervention-pair random-pair
                                        :expected-prefix prefix))
                                     (s-step
                                       (aref (getf structural :steps)
                                             step))
                                     (r-step
                                       (aref (getf random :steps)
                                             step))
                                     (base-return
                                       (getf baseline :return))
                                     (s-return
                                       (getf structural :return))
                                     (r-return
                                       (getf random :return)))
                                (unless (and
                                         (= (getf s-step :actual-concrete)
                                            (getf event :structural-concrete))
                                         (= (getf r-step :actual-concrete)
                                            (getf event :random-concrete)))
                                  (error "Resolved intervention changed on seed ~D lane ~D."
                                         seed id))
                                (incf (aref counts id))
                                (incf structural-transitions
                                      (length (getf structural :steps)))
                                (incf random-transitions
                                      (length (getf random :steps)))
                                (format out
                                        "~D~C~D~C~D~C~A~C~A~C~A~C~A~C~A~C~A~C~A~C~A~C~D~C~D~C~D~C~D~C~D~C~D~%"
                                        id #\Tab seed #\Tab
                                        step #\Tab
                                        (team-id
                                         (nth-value
                                          2
                                          (execute-team-semantic-ranked
                                           team
                                           (getf state
                                                 :policy-observation))))
                                        #\Tab
                                        (getf state :state-digest) #\Tab
                                        base-return #\Tab
                                        s-return #\Tab
                                        r-return #\Tab
                                        (- s-return base-return) #\Tab
                                        (- r-return base-return) #\Tab
                                        (- s-return r-return) #\Tab
                                        (getf state :actual-concrete) #\Tab
                                        (getf s-step :actual-concrete)
                                        #\Tab
                                        (getf r-step :actual-concrete)
                                        #\Tab
                                        (length prefix) #\Tab
                                        (length (getf structural :steps))
                                        #\Tab
                                        (length (getf random :steps)))
                                (finish-output out)))))))
                    (when (zerop (mod (1+ i) 10))
                      (format t
                              "Level-2 paired screen ~D/~D seeds, group counts=~S~%"
                              (1+ i) count (coerce counts 'list))
                      (finish-output))))
      (when env
        (ignore-errors (py4cl2:pymethod env "close"))))
    (unless (= structural-transitions random-transitions)
      (error "Unequal intervention transition budgets: ~D versus ~D."
             structural-transitions random-transitions))
    (let ((summary
            (list :protocol +matched-counterfactual-protocol+
                  :checkpoint checkpoint
                  :manifest manifest-path
                  :seed-root seed-root
                  :seed-count count
                  :cap cap
                  :per-lane-counts (coerce counts 'list)
                  :baseline-transitions baseline-transitions
                  :structural-transitions structural-transitions
                  :random-transitions random-transitions)))
      (rare-failure-write-form
       summary
       (make-pathname :name "screen-summary" :type "sexp"
                      :defaults (pathname output-file)))
      summary)))