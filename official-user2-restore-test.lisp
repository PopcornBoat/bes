(in-package :cl-tpg)

(defun user2-first-restore-event (episode)
  "Choose the first nonopening User2 User-compromise observation."
  (loop for state across (getf episode :steps)
        for step = (getf state :step)
        for observation = (getf state :policy-observation)
        when (and (>= step 3)
                  (= (aref observation 42) 0.0d0)
                  (= (aref observation 43) 1.0d0)
                  (not (equal '(8 2)
                              (getf state :incumbent-pair)))
                  (/= 142 (getf state :incumbent-concrete)))
          return state))

(defun user2-restore-summary (records)
  (let* ((eligible
           (remove-if-not
            (lambda (item) (eq :eligible (getf item :status)))
            records))
         (deltas (mapcar (lambda (item) (getf item :paired-delta))
                         eligible))
         (count (length deltas))
         (mean (when (plusp count)
                 (/ (reduce #'+ deltas) (coerce count 'double-float))))
         (sd
           (when (and mean (> count 1))
             (sqrt
              (/ (reduce #'+ deltas
                         :key (lambda (delta)
                                (expt (- delta mean) 2)))
                 (coerce (1- count) 'double-float)))))
         (se (when sd
               (/ sd (sqrt (coerce count 'double-float))))))
    (list :requested (length records)
          :eligible count
          :coverage (/ count (coerce (max 1 (length records)) 'double-float))
          :positive (count-if (lambda (x) (> x 1.0d-8)) deltas)
          :negative (count-if (lambda (x) (< x -1.0d-8)) deltas)
          :zero (count-if (lambda (x) (<= (abs x) 1.0d-8)) deltas)
          :mean-delta mean
          :standard-deviation sd
          :standard-error se
          :normal-95-percent-interval
            (and se (list (- mean (* 1.96d0 se))
                          (+ mean (* 1.96d0 se))))
          :mean-across-all-requested
            (/ (reduce #'+ deltas)
               (coerce (max 1 (length records)) 'double-float))
          :minimum (and deltas (reduce #'min deltas))
          :maximum (and deltas (reduce #'max deltas))
          :event-step
            (loop for item in eligible
                  collect (getf item :step)))))

(defun run-user2-first-restore-test
       (checkpoint output-directory seeds cohort)
  "One teacher-free official User2 Restore intervention per eligible episode."
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
         (directory (uiop:ensure-directory-pathname output-directory))
         (policy (rare-failure-load-policy :user2-test checkpoint))
         (metadata (getf policy :metadata))
         (records nil)
         (transitions 0))
    (unless (= (length seeds) (length (remove-duplicates seeds)))
      (error "Intervention seeds must be distinct."))
    (setf *instruction-set-profile*
          (or (getf metadata :instruction-set-profile) :reduced-eq)
          *read-only-register-profile*
          (or (getf metadata :read-only-register-profile)
              :cage2-categorical-v1))
    (ensure-directories-exist
     (merge-pathnames "episodes/" directory))
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
    (let* ((env (cl-gym::make environment-name))
           (controller
             (make-cage2-controller
              :decoy-order-profile
                (cage2-heuristic-controller-profile environment-name))))
      (cl-gym::configure-cage2-controller-option-orders env controller)
      (unwind-protect
           (loop for seed in seeds
                 for index from 1
                 do (let* ((baseline
                             (official-pilot-run-episode
                              env controller (getf policy :team)
                              environment-name seed))
                           (event (user2-first-restore-event baseline)))
                      (incf transitions (length (getf baseline :steps)))
                      (if (null event)
                          (push (list :seed seed :status :no-eligible-event
                                      :baseline-return
                                        (getf baseline :return))
                                records)
                          (let* ((step (getf event :step))
                                 (branch
                                   (official-pilot-run-episode
                                    env controller (getf policy :team)
                                    environment-name seed
                                    :intervention-step step
                                    :intervention-pair '(8 2)
                                    :expected-prefix
                                      (getf baseline :steps)))
                                 (actual
                                   (getf (aref (getf branch :steps) step)
                                         :actual-concrete))
                                 (delta
                                   (- (getf branch :return)
                                      (getf baseline :return))))
                            (incf transitions
                                  (length (getf branch :steps)))
                            (unless (= actual 142)
                              (error "Expected concrete User2 Restore 142, got ~D on seed ~D."
                                     actual seed))
                            (rare-failure-write-form
                             (list :seed seed :cohort cohort
                                   :baseline baseline :branch branch)
                             (merge-pathnames
                              (format nil "episodes/seed-~D.sexp" seed)
                              directory))
                            (push
                             (list :seed seed :status :eligible
                                   :step step
                                   :policy-observation
                                     (coerce
                                      (getf event :policy-observation)
                                      'list)
                                   :baseline-pair
                                     (getf event :incumbent-pair)
                                   :baseline-concrete
                                     (getf event :incumbent-concrete)
                                   :branch-pair '(8 2)
                                   :branch-concrete actual
                                   :baseline-return
                                     (getf baseline :return)
                                   :branch-return
                                     (getf branch :return)
                                   :paired-delta delta)
                             records)))
                      (when (zerop (mod index 10))
                        (format t "~&~A first User2 Restore: ~D/~D seeds.~%"
                                cohort index (length seeds))
                        (finish-output))))
        (ignore-errors (py4cl2:pymethod env "close"))))
    (setf records (nreverse records))
    (let ((result
            (list :protocol :user2-first-restore-official-v1
                  :cohort cohort
                  :checkpoint checkpoint
                  :environment environment-name
                  :selection-rule
                    (list :first-eligible-step-at-least 3
                          :user2-compromised-bits '(0 1)
                          :force-pair '(8 2)
                          :resume-frozen-tpg t)
                  :seeds seeds
                  :official-transitions transitions
                  :summary (user2-restore-summary records)
                  :records records)))
      (rare-failure-write-form
       result (merge-pathnames "summary.sexp" directory))
      (format t "~&~A complete: ~S~%"
              cohort (getf result :summary))
      (finish-output)
      result)))
