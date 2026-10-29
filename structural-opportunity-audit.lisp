(in-package :cl-tpg)

(defparameter +structural-opportunity-protocol+ :structural-opportunity-level1-v1)

(defun structural-opportunity-mask-for-team (team &optional reachable-p)
  "Catalogue mask of direct atomic terminals, or all terminals in TEAM closure."
  (let ((mask 0))
    (dolist (current (if reachable-p (closure team) (list team)) mask)
      (dolist (learner (team-learners current))
        (let* ((action (learner-action learner))
               (payload (and (eq (action-type action) :atomic)
                             (action-action action))))
          (when (target-response-36-action-p payload)
            (let ((index
                    (semantic-36-pair-index
                     (target-response-36-action-target payload)
                     (target-response-36-action-response payload))))
              (when index
                (setf mask (logior mask (ash 1 index)))))))))))

(defun structural-opportunity-ranking-mask (ranking)
  (let ((mask 0))
    (dolist (pair ranking mask)
      (let ((index (semantic-36-pair-index (first pair) (second pair))))
        (when index
          (setf mask (logior mask (ash 1 index))))))))

(defun structural-opportunity-feasible-mask (controller before)
  "Resolve every catalogue pair from the recorded pre-action Controller state."
  (replace (cage2-controller-scan-state controller) (getf before :scan))
  (setf (cage2-controller-decoy-mask controller)
        (getf before :decoy-mask)
        (cage2-controller-step controller)
        (getf before :step))
  (loop with mask = 0
        for index below (length *semantic-36-catalogue*)
        for pair = (semantic-36-index-pair index)
        for decision =
          (cage2-controller-resolve-pair-ranking controller (list pair))
        do (when (and (not (cage2-controller-decision-fallback-p decision))
                      (equal pair (official-pilot-pair decision)))
             (setf mask (logior mask (ash 1 index))))
        finally (return mask)))

(defun structural-opportunity-local-bid-margin (team observation)
  (let ((bids
          (sort
           (loop for learner in (team-learners team)
                 collect
                   (bid learner observation
                        (make-array +num-registers+
                                    :element-type 'double-float)))
           #'>)))
    (if (rest bids)
        (- (first bids) (second bids))
        0.0d0)))

(defun structural-opportunity-observation-string (observation)
  (format nil "~{~A~^,~}" (coerce observation 'list)))

(defun structural-opportunity-path-string (path)
  (format nil "~{~A~^>~}" (mapcar #'team-id path)))

(defun run-structural-opportunity-audit
       (checkpoint output-file &key (seed-root 11000000) (count 100))
  "Collect frozen-incumbent official traces without testing alternative actions."
  (unless (and (integerp seed-root) (<= 0 seed-root)
               (integerp count) (plusp count))
    (error "Invalid Level-1 seed root or count."))
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
         (policy (rare-failure-load-policy :structural-audit checkpoint))
         (team (getf policy :team))
         (metadata (getf policy :metadata))
         (env nil)
         (controller nil)
         (resolver nil)
         (direct-cache (make-hash-table :test #'eq))
         (reachable-cache (make-hash-table :test #'eq)))
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
    (with-open-file (catalogue
                      (make-pathname :name "catalogue" :type "tsv"
                                     :defaults (pathname output-file))
                      :direction :output :if-exists :supersede
                      :if-does-not-exist :create)
      (format catalogue "index~Ctarget~Cresponse~%" #\Tab #\Tab)
      (loop for index below (length *semantic-36-catalogue*)
            for pair = (semantic-36-index-pair index)
            do (format catalogue "~D~C~D~C~D~%"
                       index #\Tab (first pair) #\Tab (second pair))))
    (unwind-protect
         (with-open-file (out output-file :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
           (format out
                   "seed~Cstep~Cepisode_return~Creward~Cterminal~Cpath~Cobservation~Cselected_index~Cdirect_mask~Creachable_mask~Ctop8_mask~Cfeasible_mask~Cbid_margin~Cstate_digest~%"
                   #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab
                   #\Tab #\Tab #\Tab #\Tab)
           (loop for index below count
                 for seed = (+ seed-root (* 197 index))
                 for episode =
                   (official-pilot-run-episode
                    env controller team environment-name seed)
                 do (loop for state across (getf episode :steps)
                          for step = (getf state :step)
                          unless (< step 3)
                            do (let ((observation
                                       (getf state :policy-observation)))
                                 (multiple-value-bind
                                       (ranking path terminal)
                                     (execute-team-semantic-ranked
                                      team observation)
                                   (unless (and terminal
                                                (equal
                                                 (mapcar
                                                  #'semantic-action-category-pair
                                                  ranking)
                                                 (getf state :ranking)))
                                     (error
                                      "Ranking or terminal changed at seed ~D step ~D."
                                      seed step))
                                   (let* ((pair
                                            (getf state :incumbent-pair))
                                          (selected-index
                                            (semantic-36-pair-index
                                             (first pair) (second pair)))
                                          (direct
                                            (or (gethash terminal direct-cache)
                                                (setf (gethash terminal direct-cache)
                                                      (structural-opportunity-mask-for-team
                                                       terminal))))
                                          (reachable
                                            (or (gethash terminal reachable-cache)
                                                (setf
                                                 (gethash terminal reachable-cache)
                                                 (structural-opportunity-mask-for-team
                                                  terminal t)))))
                                     (unless selected-index
                                       ;; Monitor fallback has no Semantic-36 index.
                                       (setf selected-index -1))
                                     (format out
                                             "~D~C~D~C~A~C~A~C~A~C~A~C~A~C~D~C~D~C~D~C~D~C~D~C~A~C~A~%"
                                             seed #\Tab step #\Tab
                                             (getf episode :return) #\Tab
                                             (getf state :reward) #\Tab
                                             (team-id terminal) #\Tab
                                             (structural-opportunity-path-string
                                              path) #\Tab
                                             (structural-opportunity-observation-string
                                              observation) #\Tab
                                             selected-index #\Tab
                                             direct #\Tab reachable #\Tab
                                             (structural-opportunity-ranking-mask
                                              (getf state :ranking)) #\Tab
                                             (structural-opportunity-feasible-mask
                                              resolver
                                              (getf state :controller-before))
                                             #\Tab
                                             (structural-opportunity-local-bid-margin
                                              terminal observation) #\Tab
                                             (getf state :state-digest))))))
                    (finish-output out)
                    (when (zerop (mod (1+ index) 10))
                      (format t "Level-1 official rollouts ~D/~D~%"
                              (1+ index) count)
                      (finish-output))))
      (when env
        (ignore-errors (py4cl2:pymethod env "close"))))
    (list :protocol +structural-opportunity-protocol+
          :checkpoint checkpoint
          :seed-root seed-root
          :count count
          :output-file output-file)))