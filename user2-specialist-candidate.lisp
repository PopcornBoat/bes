(in-package :cl-tpg)

(defparameter +user2-specialist-pair+ '(8 2))
(defparameter +user2-specialist-conjunction+
  '(:left (:observation-index 42 :ror-index 0 :value 0.0d0)
    :right (:observation-index 43 :ror-index 1 :value 1.0d0)))

(defun user2-specialist-observation (values)
  (make-array (length values) :element-type 'double-float
              :initial-contents values))

(defun user2-specialist-discovery-probes (directory)
  "Return discovery event observations and unique baseline policy observations."
  (let* ((summary
           (rare-failure-read-form
            (merge-pathnames "summary.sexp" (pathname directory))))
         (events nil)
         (probes nil)
         (seen (make-hash-table :test #'equalp)))
    (dolist (record (getf summary :records))
      (when (eq (getf record :status) :eligible)
        (let* ((seed (getf record :seed))
               (episode
                 (rare-failure-read-form
                  (merge-pathnames
                   (format nil "episodes/seed-~D.sexp" seed)
                   (pathname directory)))))
          (push (user2-specialist-observation
                 (getf record :policy-observation))
                events)
          (loop for state across
                  (getf (getf episode :baseline) :steps)
                for observation =
                  (getf state :policy-observation)
                unless (gethash observation seen)
                  do (setf (gethash observation seen) t)
                     (push (copy-seq observation) probes)))))
    (values (nreverse events) (nreverse probes))))

(defun user2-specialist-terminal (team observation)
  (nth-value 2 (execute-team-semantic-ranked team observation)))

(defun user2-specialist-majority-terminal (team observations)
  (let ((counts (make-hash-table :test #'eq))
        (selected nil)
        (best-count 0))
    (dolist (observation observations)
      (let* ((terminal
               (user2-specialist-terminal team observation))
             (count (incf (gethash terminal counts 0))))
        (when (> count best-count)
          (setf selected terminal best-count count))))
    (values selected best-count)))

(defun user2-specialist-parent-bids (team observations terminal)
  (loop for observation in observations
        when (eq terminal
                 (user2-specialist-terminal team observation))
          collect
          (incumbent-conservative-root-winning-bid
           terminal observation)))

(defun user2-specialist-thresholds (bids)
  "Bid quantiles yield several intervention strengths without an arbitrary boost."
  (remove-duplicates
   (loop for quantile in '(0.25d0 0.50d0 0.75d0 0.95d0 1.0d0)
         collect
           (max -999.0d0
                (min 999.0d0
                     (+ 1.0d-5
                        (official-guided-quantile bids quantile)))))
   :test #'=))

(defun user2-specialist-child (parent observation threshold)
  "Deep-copy the entire graph, then add one direct terminal to its active team."
  (let* ((child
           (deserialize-team
            (serialize-team parent (make-hash-table :test #'equal))
            (make-hash-table :test #'equal)))
         (terminal
           (user2-specialist-terminal child observation)))
    (unless terminal
      (error "Cannot identify the candidate's terminal team."))
    (setf (team-learners terminal)
          (append
           (team-learners terminal)
           (list
            (make-learner
             :program
               (incumbent-conservative-gate-program
                +user2-specialist-conjunction+ threshold)
             :action
               (make-action
                :type :atomic
                :action
                  (make-target-response-36-action
                   :target 8 :response 2))))))
    child))

(defun user2-specialist-top-pair (team observation)
  (semantic-action-category-pair
   (first (execute-team-semantic-ranked team observation))))

(defun user2-specialist-screen (parent child events probes)
  "Count event coverage and collateral Top-1 changes on discovery states."
  (let ((event-hits 0)
        (event-terminal 0)
        (probe-changes 0)
        (nonmarker-changes 0)
        (marker-changes 0)
        (marker-probes 0))
    (let ((target-terminal
            (user2-specialist-majority-terminal parent events)))
      (dolist (observation events)
        (when (eq target-terminal
                  (user2-specialist-terminal parent observation))
          (incf event-terminal))
        (when (equal +user2-specialist-pair+
                     (user2-specialist-top-pair child observation))
          (incf event-hits))))
    (dolist (observation probes)
      (let ((marker
              (incumbent-conservative-conjunction-match-p
               +user2-specialist-conjunction+ observation)))
        (when marker (incf marker-probes))
        (unless (equal
                 (user2-specialist-top-pair parent observation)
                 (user2-specialist-top-pair child observation))
          (incf probe-changes)
          (if marker
              (incf marker-changes)
              (incf nonmarker-changes)))))
    (list :event-count (length events)
          :event-terminal-count event-terminal
          :event-restore-count event-hits
          :event-restore-rate
            (/ event-hits (coerce (max 1 (length events)) 'double-float))
          :probe-count (length probes)
          :probe-marker-count marker-probes
          :probe-top1-changes probe-changes
          :probe-marker-changes marker-changes
          :probe-nonmarker-changes nonmarker-changes)))

(defun user2-specialist-save-candidate (team path teacher-backend)
  "Write an unscored experimental checkpoint; never touch the saved best."
  (write-best-team-checkpoint
   team nil path
   :gym-environment-name "Cage2-meander-100-v0"
   :fitness-evaluation-protocol :user2-specialist-experiment-v1
   :num-observations 62
   :instruction-set-profile *instruction-set-profile*
   :read-only-register-profile *read-only-register-profile*
   :terminal-action-format :target-response-36
   :decoy-order-mode :fixed
   :cage2-opening-mode :fixed
   :recurrent-policy-enabled nil
   :teacher-backend teacher-backend
   :action-agreement-signature (action-agreement-signature)))

(defun run-user2-specialist-screen
       (checkpoint discovery-directory output-directory)
  "Construct independent specialists and report their discovery behavior."
  (let* ((*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*instruction-set-profile* :reduced-eq)
         (*read-only-register-profile* :cage2-categorical-v1)
         (*decoy-order-mode* :fixed)
         (*cage2-opening-mode* :fixed)
         (*teacher-backend* :heuristic)
         (*recurrent-policy-enabled* nil)
         (*hamming-space-enabled* nil)
         (policy (rare-failure-load-policy :parent checkpoint))
         (parent (getf policy :team))
         (directory
           (uiop:ensure-directory-pathname output-directory)))
    (setf *instruction-set-profile*
          (or (getf (getf policy :metadata) :instruction-set-profile)
              :reduced-eq)
          *read-only-register-profile*
          (or (getf (getf policy :metadata) :read-only-register-profile)
              :cage2-categorical-v1))
    (multiple-value-bind (events probes)
        (user2-specialist-discovery-probes discovery-directory)
      (unless events
        (error "Discovery data has no eligible events."))
      (multiple-value-bind (target-team routed-count)
          (user2-specialist-majority-terminal parent events)
        (let* ((bids
                 (user2-specialist-parent-bids
                  parent events target-team))
               (thresholds
                 (user2-specialist-thresholds bids))
               (representative
                 (find-if
                  (lambda (observation)
                    (eq target-team
                        (user2-specialist-terminal
                         parent observation)))
                  events))
               (results nil))
          (format t "~&Discovery events=~D unique-probes=~D majority-team=~A routed=~D bid-range=~F..~F thresholds=~S~%"
                  (length events) (length probes)
                  (team-id target-team) routed-count
                  (reduce #'min bids) (reduce #'max bids)
                  thresholds)
          (finish-output)
          (loop for threshold in thresholds
                for index from 1
                do (let* ((child
                            (user2-specialist-child
                             parent representative threshold))
                          (screen
                            (user2-specialist-screen
                             parent child events probes))
                          (name
                            (format nil "candidate-~D.lisp" index))
                          (path
                            (merge-pathnames name directory)))
                     (user2-specialist-save-candidate
                      child path
                      (getf (getf policy :metadata)
                            :teacher-backend))
                     (push (list :candidate name
                                 :threshold threshold
                                 :screen screen)
                           results)
                     (format t "~&~A threshold=~F screen=~S~%"
                             name threshold screen)
                     (finish-output)))
          (setf results (nreverse results))
          (rare-failure-write-form
           (list :protocol :user2-specialist-screen-v1
                 :parent checkpoint
                 :discovery discovery-directory
                 :majority-terminal-routed routed-count
                 :majority-terminal-id (team-id target-team)
                 :parent-terminal-bids bids
                 :candidates results)
           (merge-pathnames "screen.sexp" directory))
          results)))))
(defun user2-specialist-restore-count (episode)
  (count 142 (getf episode :steps)
         :key (lambda (step)
                (getf step :actual-concrete))))

(defun user2-specialist-user2-marker-count (episode)
  (count-if
   (lambda (step)
     (let ((observation
             (getf step :policy-observation)))
       (and (= (aref observation 42) 0.0d0)
            (= (aref observation 43) 1.0d0))))
   (getf episode :steps)))

(defun user2-specialist-evaluation-summary (records)
  (let* ((deltas
           (mapcar (lambda (item)
                     (getf item :paired-delta))
                   records))
         (count (length deltas))
         (mean (and (plusp count)
                    (arithmetic-mean deltas)))
         (se (and mean (sample-standard-error deltas))))
    (list :episodes count
          :mean-parent
            (and records
                 (arithmetic-mean
                  (mapcar (lambda (item)
                            (getf item :parent-return))
                          records)))
          :mean-candidate
            (and records
                 (arithmetic-mean
                  (mapcar (lambda (item)
                            (getf item :candidate-return))
                          records)))
          :mean-paired-delta mean
          :standard-error se
          :normal-95-percent-interval
            (and se
                 (list (- mean (* 1.96d0 se))
                       (+ mean (* 1.96d0 se))))
          :positive (count-if #'plusp deltas)
          :negative (count-if #'minusp deltas)
          :zero (count 0.0d0 deltas)
          :mean-parent-restores
            (and records
                 (arithmetic-mean
                  (mapcar
                   (lambda (item)
                     (getf item :parent-restores))
                   records)))
          :mean-candidate-restores
            (and records
                 (arithmetic-mean
                  (mapcar
                   (lambda (item)
                     (getf item :candidate-restores))
                   records)))
          :mean-parent-user2-marker-steps
            (and records
                 (arithmetic-mean
                  (mapcar
                   (lambda (item)
                     (getf item :parent-user2-marker-steps))
                   records)))
          :mean-candidate-user2-marker-steps
            (and records
                 (arithmetic-mean
                  (mapcar
                   (lambda (item)
                     (getf item :candidate-user2-marker-steps))
                   records))))))

(defun run-user2-specialist-official
       (parent-path candidate-path output-path seeds cohort
        &optional (horizon 100))
  "Evaluate complete closed-loop episodes on paired official seeds."
  (let* ((*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*instruction-set-profile* :reduced-eq)
         (*read-only-register-profile* :cage2-categorical-v1)
         (*decoy-order-mode* :fixed)
         (*cage2-opening-mode* :fixed)
         (*teacher-backend* :heuristic)
         (*recurrent-policy-enabled* nil)
         (*hamming-space-enabled* nil)
         (parent-policy
           (rare-failure-load-policy :parent parent-path))
         (candidate-policy
           (rare-failure-load-policy :candidate candidate-path))
         (environment-name (cage2-validation-environment-name "meander" horizon))
         (records nil))
    (unless (= (length seeds)
               (length (remove-duplicates seeds)))
      (error "Official specialist evaluation needs distinct seeds."))
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
                (cage2-heuristic-controller-profile
                 environment-name))))
      (cl-gym::configure-cage2-controller-option-orders
       env controller)
      (unwind-protect
           (loop for seed in seeds
                 for index from 1
                 do (let* ((parent
                             (official-pilot-run-episode
                              env controller
                              (getf parent-policy :team)
                              environment-name seed))
                           (candidate
                             (official-pilot-run-episode
                              env controller
                              (getf candidate-policy :team)
                              environment-name seed))
                           (record
                             (list :seed seed
                                   :parent-return
                                     (getf parent :return)
                                   :candidate-return
                                     (getf candidate :return)
                                   :paired-delta
                                     (- (getf candidate :return)
                                        (getf parent :return))
                                   :parent-restores
                                     (user2-specialist-restore-count
                                      parent)
                                   :candidate-restores
                                     (user2-specialist-restore-count
                                      candidate)
                                   :parent-user2-marker-steps
                                     (user2-specialist-user2-marker-count
                                      parent)
                                   :candidate-user2-marker-steps
                                     (user2-specialist-user2-marker-count
                                      candidate))))
                      (push record records)
                      (when (zerop (mod index 5))
                        (format t "~&~A official: ~D/~D seeds, mean paired delta=~,4F~%"
                                cohort index (length seeds)
                                (arithmetic-mean
                                 (mapcar
                                  (lambda (item)
                                    (getf item :paired-delta))
                                  records)))
                        (finish-output))
                      (rare-failure-write-form
                       (list :protocol :user2-specialist-official-v1
                             :cohort cohort
                             :environment environment-name
                             :parent-path parent-path
                             :candidate-path candidate-path
                             :seeds (subseq seeds 0 index)
                             :summary
                               (user2-specialist-evaluation-summary
                                records)
                             :records (nreverse (copy-list records)))
                       output-path)))
        (ignore-errors (py4cl2:pymethod env "close"))))
    (setf records (nreverse records))
    (format t "~&~A complete: ~S~%"
            cohort
            (user2-specialist-evaluation-summary records))
    (finish-output)
    (user2-specialist-evaluation-summary records)))