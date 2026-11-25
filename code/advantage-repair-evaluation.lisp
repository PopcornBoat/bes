(in-package :cl-tpg)

(defun advantage-repair-evaluation-statistics (values)
  (let* ((count (length values))
         (mean (/ (reduce #'+ values) (coerce count 'double-float)))
         (variance
           (if (> count 1)
               (/ (reduce #'+ values
                          :key (lambda (value)
                                 (expt (- value mean) 2)))
                  (coerce (1- count) 'double-float))
               0.0d0))
         (standard-deviation (sqrt variance)))
    (list :mean mean
          :standard-deviation standard-deviation
          :standard-error
            (/ standard-deviation
               (sqrt (coerce count 'double-float))))))

(defun run-advantage-repair-evaluation
       (parent-path child-path output-path
        &key (seed-count 100) (seed-root 8000001)
             (environment-name "Cage2-meander-100-v0"))
  "Evaluate one tentative bid repair on fresh, paired official seeds."
  (let* ((*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*instruction-set-profile* :full)
         (*read-only-register-profile* :disabled)
         (*decoy-order-mode* :fixed)
         (*cage2-opening-mode* :fixed)
         (*recurrent-policy-enabled* nil)
         (*hamming-space-enabled* nil)
         (parent-policy (rare-failure-load-policy :parent parent-path))
         (child-policy (rare-failure-load-policy :repair child-path))
         (metadata (getf parent-policy :metadata))
         (records nil))
    (setf *instruction-set-profile*
          (or (getf metadata :instruction-set-profile) :full)
          *read-only-register-profile*
          (or (getf metadata :read-only-register-profile) :disabled))
    (py4cl2:pyexec
     "import gymnasium as gym, cage2_bridge, pickle, random, hashlib
def _bes_official_state_digest(env):
    base = env.unwrapped
    state = (base.cyborg.environment_controller.state,
             random.getstate(),
             tuple(float(x) for x in base.scan_state.state),
             tuple((k, tuple(sorted(v))) for k, v in sorted(base.used_decoys.items())),
             base.current_step)
    return hashlib.sha256(pickle.dumps(state, protocol=4)).hexdigest()
def _bes_close_env(env):
    env.close()")
    (let* ((env (cl-gym::make environment-name))
           (controller
             (make-cage2-controller
              :decoy-order-profile
                (cage2-heuristic-controller-profile environment-name))))
      (cl-gym::configure-cage2-controller-option-orders env controller)
      (unwind-protect
           (loop for index below seed-count
                 for seed = (+ seed-root (* 197 index))
                 do (let* ((parent
                             (official-pilot-run-episode
                              env controller (getf parent-policy :team)
                              environment-name seed))
                           (child
                             (official-pilot-run-episode
                              env controller (getf child-policy :team)
                              environment-name seed))
                           (parent-steps (getf parent :steps))
                           (child-steps (getf child :steps))
                           (shared-prefix
                             (loop for step below
                                     (min (length parent-steps)
                                          (length child-steps))
                                   while
                                     (equal
                                      (getf (aref parent-steps step)
                                            :executed-concrete)
                                      (getf (aref child-steps step)
                                            :executed-concrete))
                                   count t))
                           (delta
                             (- (getf child :return)
                                (getf parent :return))))
                      (unless (and (equal
                                    (getf (aref parent-steps 0)
                                          :state-digest)
                                    (getf (aref child-steps 0)
                                          :state-digest))
                                   (equalp
                                    (getf (aref parent-steps 0)
                                          :policy-observation)
                                    (getf (aref child-steps 0)
                                          :policy-observation)))
                        (error "Paired seed ~D did not reproduce its initial state."
                               seed))
                      (push (list :seed seed
                                  :parent-return (getf parent :return)
                                  :child-return (getf child :return)
                                  :paired-delta delta
                                  :first-action-divergence
                                    (if (< shared-prefix
                                           (min (length parent-steps)
                                                (length child-steps)))
                                        shared-prefix
                                        nil)
                                  :parent-steps (length parent-steps)
                                  :child-steps (length child-steps))
                            records)
                      (when (zerop (mod (1+ index) 10))
                        (format t "~&Completed ~D/~D paired seeds.~%"
                                (1+ index) seed-count)
                        (finish-output))))
        (py4cl2:pycall "_bes_close_env" env)))
    (setf records (nreverse records))
    (let* ((deltas (mapcar (lambda (item)
                            (getf item :paired-delta))
                          records))
           (parent-returns
             (mapcar (lambda (item)
                       (getf item :parent-return))
                     records))
           (child-returns
             (mapcar (lambda (item)
                       (getf item :child-return))
                     records))
           (result
             (list :protocol :official-advantage-repair-evaluation-v1
                   :parent-path parent-path
                   :child-path child-path
                   :environment environment-name
                   :seed-root seed-root
                   :seed-stride 197
                   :seed-count seed-count
                   :parent-statistics
                     (advantage-repair-evaluation-statistics
                      parent-returns)
                   :child-statistics
                     (advantage-repair-evaluation-statistics
                      child-returns)
                   :paired-statistics
                     (advantage-repair-evaluation-statistics
                      deltas)
                   :wins (count-if #'plusp deltas)
                   :ties (count 0.0d0 deltas)
                   :losses (count-if #'minusp deltas)
                   :records records)))
      (rare-failure-write-form result output-path)
      (format t "~&Paired result: ~S~%"
              (getf result :paired-statistics))
      result)))
