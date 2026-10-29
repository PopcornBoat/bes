(in-package :cl-tpg)

(defun response-sweep-first-event (team lane baseline)
  "First path/host state; response feasibility cannot select the event."
  (loop for state across (getf baseline :steps)
        for step = (getf state :step)
        when (and (>= step 3)
                  (matched-counterfactual-bits-match-p
                   lane (getf state :policy-observation)))
          do (multiple-value-bind (ranking path terminal)
                 (execute-team-semantic-ranked
                  team (getf state :policy-observation))
               (declare (ignore ranking))
               (when (and terminal
                          (string= (team-id terminal)
                                   (getf lane :terminal))
                          (or (null (getf lane :path))
                              (string= (format nil "~{~A~^>~}"
                                               (mapcar #'team-id path))
                                       (getf lane :path))))
                 (return state)))))

(defun response-sweep-manifest (path)
  "Accept the original frozen manifest or a fresh target/path-only one."
  (let ((manifest (rare-failure-read-form path)))
    (if (eq (getf manifest :protocol) :matched-counterfactual-level2-v1)
        (matched-counterfactual-assert-manifest manifest)
        (unless (and (eq (getf manifest :protocol) :response-sweep-v2)
                     (<= 1 (length (getf manifest :lanes)) 12)
                     (loop for lane in (getf manifest :lanes)
                           for id from 0
                           always (and (= (getf lane :id) id)
                                       (stringp (getf lane :terminal))
                                       (or (null (getf lane :path))
                                           (stringp (getf lane :path)))
                                       (member (getf lane :target)
                                               '(1 2 3 4 5 7 8 9 10))
                                       (= (length (getf lane :bits)) 4)
                                       (= (getf lane :offset)
                                          (case (getf lane :target)
                                            (1 0) (2 4) (3 8) (4 12)
                                            (5 28) (7 36) (8 40)
                                            (9 44) (10 48))))))
          (error "Invalid response-sweep target/path manifest.")))
    manifest))

(defun run-response-sweep (checkpoint manifest-path output-file
                           &key (seed-root 13000000) (count 100) (cap 40)
                                (environment-name "Cage2-meander-100-v0"))
  "Replay all four responses at frozen official state/path opportunities."
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
         (manifest (response-sweep-manifest manifest-path))
         (lanes (getf manifest :lanes))
         (counts (make-array (length lanes) :initial-element 0))
         (policy (rare-failure-load-policy :response-sweep checkpoint))
         (team (getf policy :team))
         (metadata (getf policy :metadata))
         (env nil)
         (controller nil)
         (resolver nil)
         (baseline-transitions 0)
         (branch-transitions 0))
    (unless (and (integerp seed-root) (<= 0 seed-root)
                 (integerp count) (plusp count)
                 (integerp cap) (plusp cap))
      (error "Invalid response-sweep seed/count/cap."))
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
          controller (make-cage2-controller
                      :decoy-order-profile
                      (cage2-heuristic-controller-profile environment-name))
          resolver (make-cage2-controller
                    :decoy-order-profile
                    (cage2-heuristic-controller-profile environment-name)))
    (cl-gym::configure-cage2-controller-option-orders env controller)
    (cl-gym::configure-cage2-controller-option-orders env resolver)
    (unwind-protect
         (with-open-file (out output-file :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
           (format out "group~Cseed~Ccohort~Cstep~Cresponse~Cstatus~Cbaseline_return~Cbranch_return~Cdelta~Cbaseline_concrete~Cbranch_concrete~Cbranch_transitions~Cstate_digest~Cobservation~%"
                   #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab
                   #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab)
           (loop for i below count
                 for seed = (+ seed-root (* 197 i))
                 for baseline = (official-pilot-run-episode
                                 env controller team environment-name seed)
                 do (incf baseline-transitions
                          (length (getf baseline :steps)))
                    (dolist (lane lanes)
                      (let ((id (getf lane :id)))
                        (when (< (aref counts id) cap)
                          (let ((state (response-sweep-first-event
                                        team lane baseline)))
                            (when state
                              (incf (aref counts id))
                              (loop for response below 4
                                    for pair = (list (getf lane :target)
                                                     response)
                                    for decision =
                                      (matched-counterfactual-controller-decision
                                       resolver
                                       (getf state :controller-before)
                                       pair)
                                    for concrete =
                                      (and decision
                                           (cage2-controller-decision-concrete-action
                                            decision))
                                    for incumbent =
                                      (getf state :actual-concrete)
                                    for status =
                                      (cond ((null decision) :unavailable)
                                            ((= concrete incumbent) :same)
                                            (t :intervened))
                                    for branch =
                                      (when (eq status :intervened)
                                        (official-pilot-run-episode
                                         env controller team environment-name
                                         seed
                                         :intervention-step (getf state :step)
                                         :intervention-pair pair
                                         :expected-prefix
                                           (getf baseline :steps)))
                                    for branch-step =
                                      (and branch
                                           (aref (getf branch :steps)
                                                 (getf state :step)))
                                    for value =
                                      (if branch (getf branch :return)
                                          (getf baseline :return))
                                    do (when branch
                                         (unless (= concrete
                                                    (getf branch-step
                                                          :actual-concrete))
                                           (error "Intervention changed on seed ~D, group ~D, response ~D."
                                                  seed id response))
                                         (incf branch-transitions
                                               (length (getf branch :steps))))
                                       (format out
                                               "~D~C~D~C~A~C~D~C~D~C~A~C~A~C~A~C~A~C~D~C~A~C~D~C~A~C~A~%"
                                               id #\Tab seed #\Tab
                                               (if (<= (aref counts id) 20)
                                                   "discovery" "confirmation")
                                               #\Tab (getf state :step)
                                               #\Tab response #\Tab status
                                               #\Tab (getf baseline :return)
                                               #\Tab value #\Tab
                                               (- value
                                                  (getf baseline :return))
                                               #\Tab incumbent #\Tab
                                               (or concrete -1) #\Tab
                                               (if branch
                                                   (length
                                                    (getf branch :steps))
                                                   0)
                                               #\Tab
                                               (getf state :state-digest)
                                               #\Tab
                                               (format nil "~{~A~^,~}"
                                                       (coerce
                                                        (getf state
                                                              :policy-observation)
                                                        'list))))
                              (finish-output out))))))
                    (when (zerop (mod (1+ i) 10))
                      (format t "Response sweep ~D/~D seeds, counts=~S~%"
                              (1+ i) count (coerce counts 'list))
                      (finish-output))))
      (when env (ignore-errors (py4cl2:pymethod env "close"))))
    (let ((summary (list :protocol :response-sweep-v1
                         :seed-root seed-root :seed-count count :cap cap
                         :counts (coerce counts 'list)
                         :baseline-transitions baseline-transitions
                         :branch-transitions branch-transitions)))
      (rare-failure-write-form
       summary
       (make-pathname :name "sweep-summary" :type "sexp"
                      :defaults (pathname output-file)))
      summary)))
