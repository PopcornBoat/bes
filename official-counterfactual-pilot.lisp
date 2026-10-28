(in-package :cl-tpg)

(defparameter *official-counterfactual-pilot-protocol*
  :official-counterfactual-pilot-v1)

(defun official-pilot-python-state-digest (env)
  (py4cl2:pycall "_bes_official_state_digest" env))

(defun official-pilot-controller-state (controller)
  (list :scan (coerce (cage2-controller-scan-state controller) 'list)
        :decoy-mask (cage2-controller-decoy-mask controller)
        :step (cage2-controller-step controller)))

(defun official-pilot-pair (decision)
  (semantic-action-category-pair
   (cage2-controller-decision-semantic-action decision)))

(defun official-pilot-assert-prefix (baseline record step)
  (dolist (key '(:state-digest :policy-observation :controller-before
                 :incumbent-pair :incumbent-concrete :ranking))
    (unless (equalp (getf baseline key) (getf record key))
      (error "Official replay mismatch at step ~D, field ~S." step key))))

(defun official-pilot-run-episode
       (env controller team environment-name seed
        &key intervention-step intervention-pair expected-prefix)
  "Run one official episode; verify the entire prefix before one intervention."
  (call-with-fresh-policy-episode
   (lambda ()
     (cage2-controller-reset controller)
     (let ((observation (cl-gym::reset env seed))
           (steps nil)
           (total 0.0d0)
           (intervened nil))
       (loop for timestep fixnum from 0
             do (let* ((policy-observation
                          (cage2-controller-observe controller observation))
                       (state-digest
                         (official-pilot-python-state-digest env))
                       (controller-before
                         (official-pilot-controller-state controller))
                       (opening
                         (cl-gym::cage2-fixed-opening-action
                          environment-name timestep))
                       (ranking
                         (and (null opening)
                              (execute-team-semantic-ranked
                               team policy-observation)))
                       (incumbent-decision
                         (if opening
                             (cage2-controller-resolve-pair-ranking
                              controller opening)
                             (cage2-controller-resolve-ranking
                              controller ranking)))
                       (incumbent-concrete
                         (cage2-controller-decision-concrete-action
                          incumbent-decision))
                       (intervention-p
                         (and intervention-step
                              (= timestep intervention-step)))
                       (decision
                         (if intervention-p
                             (cage2-controller-resolve-pair-ranking
                              controller (list intervention-pair))
                             incumbent-decision))
                       (record
                         (list
                          :step timestep
                          :state-digest state-digest
                          :policy-observation (copy-seq policy-observation)
                          :controller-before controller-before
                          :incumbent-pair
                            (official-pilot-pair incumbent-decision)
                          :incumbent-concrete incumbent-concrete
                          :ranking (and ranking
                                        (mapcar
                                         #'semantic-action-category-pair
                                         ranking))
                          :executed-pair (official-pilot-pair decision)
                          :executed-concrete
                            (cage2-controller-decision-concrete-action
                             decision))))
                  (when (and expected-prefix
                             (<= timestep intervention-step))
                    (let ((baseline
                            (elt expected-prefix timestep)))
                      (official-pilot-assert-prefix
                       baseline record timestep)
                      (when (< timestep intervention-step)
                        (unless (equal
                                 (getf baseline :executed-concrete)
                                 (getf record :executed-concrete))
                          (error "Official replay action mismatch at step ~D."
                                 timestep)))))
                  (when intervention-p
                    (when (equal
                           (getf record :incumbent-concrete)
                           (getf record :executed-concrete))
                      (error "Intervention at step ~D changed no concrete action."
                             timestep))
                    (unless (equal intervention-pair
                                   (getf record :executed-pair))
                      (error "Intervention pair ~S resolved as ~S."
                             intervention-pair
                             (getf record :executed-pair)))
                    (setf intervened t))
                  (multiple-value-bind
                        (next-observation reward terminated truncated info)
                      (cl-gym::step
                       env
                       (cl-gym::controller-decision->cage2-input
                        decision))
                    (let ((actual
                            (cl-gym::cage2-info-value
                             info "concrete_action")))
                      (cl-gym::commit-controller-step
                       controller decision info)
                      (setf record
                            (append
                             record
                             (list
                              :actual-concrete actual
                              :reward (coerce reward 'double-float)
                              :next-observation
                                (copy-seq next-observation)
                              :controller-after
                                (official-pilot-controller-state
                                 controller))))
                      (when (and expected-prefix
                                 (< timestep intervention-step))
                        (let ((baseline
                                (elt expected-prefix timestep)))
                          (dolist (key '(:actual-concrete :reward
                                         :next-observation :controller-after))
                            (unless (equalp (getf baseline key)
                                            (getf record key))
                              (error "Official replay transition mismatch at step ~D, field ~S."
                                     timestep key)))))
                      (incf total (coerce reward 'double-float))
                      (push record steps)
                      (setf observation next-observation)
                      (when (or terminated truncated)
                        (return))))))
       (when (and intervention-step (not intervened))
         (error "Episode ended before intervention step ~D."
                intervention-step))
       (list :seed seed :return total :steps (coerce (nreverse steps) 'vector)
             :intervention-step intervention-step
             :intervention-pair intervention-pair)))))

(defun official-pilot-verify-identical-episodes (first second)
  "Verify full same-seed, same-policy replay before branching."
  (unless (and (equal (getf first :return) (getf second :return))
               (= (length (getf first :steps))
                  (length (getf second :steps))))
    (error "Official baseline replay changed return or episode length."))
  (loop for before across (getf first :steps)
        for replay across (getf second :steps)
        for step from 0
        do (official-pilot-assert-prefix before replay step)
           (dolist (key '(:actual-concrete :reward :next-observation
                          :controller-after))
             (unless (equalp (getf before key) (getf replay key))
               (error "Official baseline replay mismatch at step ~D, field ~S."
                      step key))))
  t)
(defun official-pilot-alternatives (controller state ranking incumbent-concrete)
  "Choose at most two distinct executable Top-8 semantic alternatives."
  (let ((alternatives nil))
    (replace (cage2-controller-scan-state controller) (getf state :scan))
    (setf (cage2-controller-decoy-mask controller) (getf state :decoy-mask)
          (cage2-controller-step controller) (getf state :step))
    (dolist (pair ranking)
      (when (< (length alternatives) 2)
        (let ((decision
                (cage2-controller-resolve-pair-ranking
                 controller (list pair))))
          (when (and (equal pair (official-pilot-pair decision))
                     (/= incumbent-concrete
                         (cage2-controller-decision-concrete-action
                          decision))
                     (not (member pair alternatives :test #'equal)))
            (push pair alternatives)))))
    (nreverse alternatives)))

(defun run-official-counterfactual-pilot
       (checkpoint output-path
        &key (seeds '(153 42 2026 314159 271828))
             (phase-steps '(5 20 40 60 80))
             (environment-name "Cage2-meander-100-v0"))
  "Teacher-free one-step counterfactual pilot on official CAGE2."
  (let ((*num-observations* 62)
        (*num-actions* 36)
        (*factored-actions-enabled* t)
        (*terminal-action-format* :target-response-36)
        (*instruction-set-profile* :full)
        (*read-only-register-profile* :disabled)
        (*decoy-order-mode* :fixed)
        (*cage2-opening-mode* :fixed)
        (*recurrent-policy-enabled* nil)
        (*hamming-space-enabled* nil)
        (team nil)
        (env nil)
        (controller nil)
        (records nil)
        (baseline-episodes nil)
        (branch-count 0))
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
    (let* ((policy (rare-failure-load-policy :pilot checkpoint))
           (metadata (getf policy :metadata)))
      (setf team (getf policy :team)
            *instruction-set-profile*
              (or (getf metadata :instruction-set-profile) :full)
            *read-only-register-profile*
              (or (getf metadata :read-only-register-profile) :disabled)))
    (setf env (cl-gym::make environment-name)
          controller
            (make-cage2-controller
             :decoy-order-profile
               (cage2-heuristic-controller-profile environment-name)))
    (cl-gym::configure-cage2-controller-option-orders env controller)
    (unwind-protect
         (dolist (seed seeds)
           (let* ((baseline
                    (official-pilot-run-episode
                     env controller team environment-name seed))
                  (baseline-steps (getf baseline :steps)))
             (official-pilot-verify-identical-episodes
              baseline
              (official-pilot-run-episode
               env controller team environment-name seed))
             (push (list :seed seed :return (getf baseline :return)
                         :steps (length baseline-steps)
                         :full-replay-verified-p t)
                   baseline-episodes)
             (dolist (step phase-steps)
               (when (< step (length baseline-steps))
                 (let* ((event (aref baseline-steps step))
                        (alternatives
                          (official-pilot-alternatives
                           controller (getf event :controller-before)
                           (getf event :ranking)
                           (getf event :incumbent-concrete))))
                   (dolist (pair alternatives)
                     (let* ((branch
                              (official-pilot-run-episode
                               env controller team environment-name seed
                               :intervention-step step
                               :intervention-pair pair
                               :expected-prefix baseline-steps))
                            (delta
                              (- (getf branch :return)
                                 (getf baseline :return))))
                       (incf branch-count)
                       (push
                        (list :seed seed :step step
                              :incumbent-pair
                                (getf event :incumbent-pair)
                              :alternative-pair pair
                              :baseline-concrete
                                (getf event :incumbent-concrete)
                              :alternative-concrete
                                (getf (aref (getf branch :steps) step)
                                      :actual-concrete)
                              :baseline-return
                                (getf baseline :return)
                              :branch-return (getf branch :return)
                              :paired-delta delta
                              :baseline-steps (length baseline-steps)
                              :branch-steps
                                (length (getf branch :steps)))
                        records))))))))
      (when env
        (ignore-errors (py4cl2:pymethod env "close"))))
    (let* ((result
             (list :protocol *official-counterfactual-pilot-protocol*
                   :checkpoint checkpoint
                   :environment environment-name
                   :seeds seeds
                   :phase-steps phase-steps
                   :baseline-episodes
                     (reverse baseline-episodes)
                   :branches branch-count
                   :official-transitions
                     (+ (* 2 (reduce #'+ baseline-episodes
                                      :key (lambda (x) (getf x :steps))
                                      :initial-value 0))
                        (reduce #'+ records
                                :key (lambda (x) (getf x :branch-steps))
                                :initial-value 0))
                   :records (reverse records))))
      (rare-failure-write-form result output-path)
      result)))





(defun official-pilot-executable-alternative-p (controller event pair)
  "Check a pair against the recorded Controller state without executing it."
  (let ((state (getf event :controller-before)))
    (replace (cage2-controller-scan-state controller) (getf state :scan))
    (setf (cage2-controller-decoy-mask controller) (getf state :decoy-mask)
          (cage2-controller-step controller) (getf state :step))
    (let ((decision
            (cage2-controller-resolve-pair-ranking
             controller (list pair))))
      (and (equal pair (official-pilot-pair decision))
           (/= (getf event :incumbent-concrete)
               (cage2-controller-decision-concrete-action decision))))))
(defun run-official-counterfactual-holdout
       (checkpoint output-path
        &key (seeds (loop for index below 120
                          collect (+ 6000001 (* 197 index))))
             (environment-name "Cage2-meander-100-v0"))
  "Confirm one frozen discovery group on independent official seeds.

The hypothesis is (7,0) -> (9,3) at step 20 or 40, with the alternative
present in the frozen policy's own ranking. One eligible event per episode."
  (let ((*num-observations* 62)
        (*num-actions* 36)
        (*factored-actions-enabled* t)
        (*terminal-action-format* :target-response-36)
        (*instruction-set-profile* :full)
        (*read-only-register-profile* :disabled)
        (*decoy-order-mode* :fixed)
        (*cage2-opening-mode* :fixed)
        (*recurrent-policy-enabled* nil)
        (*hamming-space-enabled* nil)
        (team nil)
        (env nil)
        (controller nil)
        (records nil)
        (transition-count 0))
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
    (let* ((policy (rare-failure-load-policy :holdout checkpoint))
           (metadata (getf policy :metadata)))
      (setf team (getf policy :team)
            *instruction-set-profile*
              (or (getf metadata :instruction-set-profile) :full)
            *read-only-register-profile*
              (or (getf metadata :read-only-register-profile) :disabled)))
    (setf env (cl-gym::make environment-name)
          controller
            (make-cage2-controller
             :decoy-order-profile
               (cage2-heuristic-controller-profile environment-name)))
    (cl-gym::configure-cage2-controller-option-orders env controller)
    (unwind-protect
         (dolist (seed seeds)
           (let* ((baseline
                    (official-pilot-run-episode
                     env controller team environment-name seed))
                  (steps (getf baseline :steps))
                  (event
                    (loop for step in '(20 40)
                          for candidate = (and (< step (length steps))
                                               (aref steps step))
                          when (and candidate
                                (equal '(7 0)
                                       (getf candidate :incumbent-pair))
                                (member '(9 3)
                                        (getf candidate :ranking)
                                        :test #'equal)
                                (official-pilot-executable-alternative-p
                                 controller candidate '(9 3)))
                            return candidate)))
             (incf transition-count (length steps))
             (if (null event)
                 (push (list :seed seed :status :no-eligible-event)
                       records)
                 (let* ((step (getf event :step))
                        (branch
                          (official-pilot-run-episode
                           env controller team environment-name seed
                           :intervention-step step
                           :intervention-pair '(9 3)
                           :expected-prefix steps))
                        (delta (- (getf branch :return)
                                  (getf baseline :return))))
                   (incf transition-count (length (getf branch :steps)))
                   (push (list :seed seed :status :eligible :step step
                               :baseline-return (getf baseline :return)
                               :branch-return (getf branch :return)
                               :paired-delta delta
                               :baseline-concrete
                                 (getf event :incumbent-concrete)
                               :alternative-concrete
                                 (getf (aref (getf branch :steps) step)
                                       :actual-concrete))
                         records)))))
      (when env
        (ignore-errors (py4cl2:pymethod env "close"))))
    (let ((result
            (list :protocol :official-counterfactual-holdout-v1
                  :checkpoint checkpoint
                  :environment environment-name
                  :seeds (copy-list seeds)
                  :requested-seeds (length seeds)
                  :hypothesis
                    '(:incumbent-pair (7 0)
                      :alternative-pair (9 3)
                      :steps (20 40)
                      :alternative-must-be-in-ranking t)
                  :official-transitions transition-count
                  :records (reverse records))))
      (rare-failure-write-form result output-path)
      result)))
