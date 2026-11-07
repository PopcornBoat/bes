(in-package :cl-tpg)

;; Offline analysis may inspect simulator internals. Every policy invocation
;; below still receives the original Controller's 62-dimensional observation.
(defparameter +privileged-search-protocol+ :fixed-seed-privileged-search-v1)

(defun brute-append-record (path record)
  (with-open-file (stream path :direction :output :if-exists :append
                              :if-does-not-exist :create)
    (let ((*print-readably* t) (*print-pretty* nil))
      (write record :stream stream)
      (terpri stream)
      (finish-output stream))))

(defun brute-episode (env controller team environment seed work-log
                      &rest options)
  (let ((episode (apply #'official-pilot-run-episode
                        env controller team environment seed options)))
    (brute-append-record
     work-log (list :seed seed :return (getf episode :return)
                    :completed-transitions (length (getf episode :steps))
                    :intervention-step (getf episode :intervention-step)
                    :intervention-pair (getf episode :intervention-pair)))
    episode))

(defun brute-verify-observer (observed plain)
  "Detect changes introduced by diagnostic observation."
  (unless (= (getf observed :return) (getf plain :return))
    (error "Privileged observer changed episode return."))
  (unless (= (length (getf observed :steps)) (length (getf plain :steps)))
    (error "Privileged observer changed episode length."))
  (loop for a across (getf observed :steps)
        for b across (getf plain :steps)
        do (dolist (key '(:state-digest :policy-observation :controller-before
                          :incumbent-concrete :actual-concrete :reward
                          :next-observation :controller-after))
             (unless (equalp (getf a key) (getf b key))
               (error "Privileged observer changed ~A at step ~D."
                      key (getf a :step)))))
  t)

(defun brute-restore-controller (controller state)
  (replace (cage2-controller-scan-state controller) (getf state :scan))
  (setf (cage2-controller-decoy-mask controller) (getf state :decoy-mask)
        (cage2-controller-step controller) (getf state :step)))

(defun brute-executable-p (controller event pair)
  (brute-restore-controller controller (getf event :controller-before))
  (let ((decision (cage2-controller-resolve-pair-ranking controller (list pair))))
    (and (equal pair (official-pilot-pair decision))
         (not (cage2-controller-decision-fallback-p decision))
         (/= (getf event :incumbent-concrete)
             (cage2-controller-decision-concrete-action decision)))))

(defun brute-gate-matches-p (predicates observation)
  (every (lambda (predicate)
           (= (aref observation (first predicate))
              (aref (active-read-only-register-values) (second predicate))))
         predicates))

(defun brute-predicate-variants (probe background)
  "Enumerate all current-input one- and two-feature equality gates.

Rank by activation frequency on the frozen policy's observed states. Simulator
internals, episode number and step number are excluded from gate features."
  (let* ((values (active-read-only-register-values))
         (atoms
           (loop for value across probe for index from 0
                 for ror = (position value values :test #'=)
                 when ror collect (list index ror)))
         (single (mapcar #'list atoms))
         (double
           (loop for tail on atoms append
                 (loop for other in (rest tail)
                       collect (list (first tail) other)))))
    (flet ((activation (predicates)
             (count-if (lambda (obs) (brute-gate-matches-p predicates obs))
                       background)))
      (append (subseq (stable-sort single #'< :key #'activation)
                      0 (min 1 (length single)))
              (subseq (stable-sort double #'< :key #'activation)
                      0 (min 2 (length double)))))))

(defun brute-save-policy (team score path metadata environment)
  (write-best-team-checkpoint
   team score path :gym-environment-name environment
   :generation (getf metadata :generation) :online-fitness-episodes 1
   :search-seed (getf metadata :search-seed)
   :fitness-evaluation-protocol +privileged-search-protocol+
   :action-agreement-signature (getf metadata :action-agreement-signature)
   :num-observations 62 :decoy-order-mode :fixed :cage2-opening-mode :fixed
   :recurrent-policy-enabled nil
   :teacher-backend (getf metadata :teacher-backend :heuristic)
   :instruction-set-profile *instruction-set-profile*
   :read-only-register-profile *read-only-register-profile*
   :terminal-action-format :target-response-36))

(defun brute-canonicalize-ids (root)
  "Give diagnostics stable graph identities across checkpoint reloads."
  (let ((seen (make-hash-table :test #'eq)) (next 0))
    (labels ((walk (team)
               (unless (gethash team seen)
                 (setf (gethash team seen) t)
                 (let ((index (incf next)))
                   (setf (team-id team) (format nil "SEARCH-TEAM-~D" index))
                   (loop for learner in (team-learners team) for position from 0
                         do (setf (learner-id learner)
                                  (format nil "SEARCH-LEARNER-~D-~D" index position))
                            (when (eq (action-type (learner-action learner)) :reference)
                              (walk (action-action (learner-action learner)))))))))
      (walk root)))
  root)

(defun brute-path-bids (team observation)
  "Report actual bid competition on each team of the preferred path."
  (multiple-value-bind (ranking path terminal)
      (execute-team-semantic-ranked team observation)
    (declare (ignore ranking terminal))
    (mapcar
     (lambda (current)
       (list :team (team-id current)
             :learners
             (stable-sort
              (loop for learner in (team-learners current)
                    for act = (learner-action learner)
                    collect
                    (list :learner (learner-id learner)
                          :bid (bid learner observation)
                          :action
                          (if (eq (action-type act) :reference)
                              (list :team (team-id (action-action act)))
                              (semantic-action-category-pair
                               (make-semantic-action-from-terminal
                                (action-action act) nil)))))
              #'> :key (lambda (entry) (getf entry :bid)))))
     path)))

(defun brute-round (checkpoint directory environment seeds steps actions
                     max-branches max-candidates top-opportunities)
  (let* ((source (multiple-value-list (load-best-team checkpoint)))
         (team (brute-canonicalize-ids (first source))) (metadata (third source))
         (env (cl-gym::make environment))
         (controller (make-cage2-controller
                      :decoy-order-profile
                      (cage2-heuristic-controller-profile environment)))
         (observer (lambda (env) (py4cl2:pycall "_bes_privileged_state" env)))
         (work-log (merge-pathnames "completed-rollouts.sexp" directory))
         (baselines nil) (records nil) (background nil) (trials 0)
         (best-path checkpoint) (best-mean nil) (variants nil))
    (unless (and (= (getf metadata :num-observations) 62)
                 (eq (getf metadata :terminal-action-format) :target-response-36)
                 (not (getf metadata :recurrent-policy-enabled)))
      (error "Brute search requires a stateless Semantic-36 / 62-input checkpoint."))
    (setf *instruction-set-profile* (getf metadata :instruction-set-profile)
          *read-only-register-profile* (getf metadata :read-only-register-profile))
    (unless (and (member :eq (active-instruction-opcodes))
                 (plusp (active-read-only-register-count)))
      (error "Conditional synthesis requires EQ and a read-only constant bank."))
    (ensure-directories-exist (merge-pathnames "placeholder" directory))
    (cl-gym::configure-cage2-controller-option-orders env controller)
    (unwind-protect
         (progn
           (dolist (seed seeds)
             (let* ((baseline
                      (brute-episode env controller team environment seed work-log
                                     :observer observer))
                    (plain
                      (brute-episode env controller team environment seed work-log)))
               (brute-verify-observer baseline plain)
               (push (cons seed baseline) baselines)
               (write-readable-object-atomically
                baseline (merge-pathnames (format nil "baseline-~D.sexp" seed)
                                          directory))
               (loop for state across (getf baseline :steps)
                     do (push (getf state :policy-observation) background))))
           (setf baselines (nreverse baselines)
                 best-mean (arithmetic-mean
                            (mapcar (lambda (entry)
                                      (getf (cdr entry) :return)) baselines)))
           (let ((parent-mean best-mean))
             (block enumerate
               (dolist (entry baselines)
                 (let* ((seed (car entry)) (baseline (cdr entry))
                        (trace (getf baseline :steps)))
                   (dolist (step steps)
                     (when (< step (length trace))
                       (let ((event (aref trace step)))
                         (dolist (index actions)
                           (let ((pair (semantic-36-index-pair index)))
                             (when (brute-executable-p controller event pair)
                               (when (>= trials max-branches)
                                 (return-from enumerate))
                               (incf trials)
                               (let* ((path
                                        (merge-pathnames
                                         (format nil "trial-~D-~D-~D.sexp"
                                                 seed step index) directory))
                                      (record
                                        (if (probe-file path)
                                            (rare-failure-read-form path)
                                            (let* ((branch
                                                     (brute-episode
                                                      env controller team environment
                                                      seed work-log :observer observer
                                                      :intervention-step step
                                                      :intervention-pair pair
                                                      :expected-prefix trace))
                                                   (delta (- (getf branch :return)
                                                             (getf baseline :return)))
                                                   (result
                                                     (list :seed seed :step step
                                                           :action-index index :pair pair
                                                           :delta delta
                                                           :baseline-return
                                                           (getf baseline :return)
                                                           :branch-return
                                                           (getf branch :return)
                                                           :event event
                                                           :path-bids
                                                           (brute-path-bids
                                                            team (getf event
                                                                       :policy-observation))
                                                           :intervention
                                                           (aref (getf branch :steps)
                                                                 step))))
                                              (when (plusp delta)
                                                (write-readable-object-atomically
                                                 branch
                                                 (merge-pathnames
                                                  (format nil "positive-~D-~D-~D.sexp"
                                                          seed step index) directory)))
                                              (write-readable-object-atomically result path)
                                              result))))
                                 (push record records)
                                 (format t "~&TRIAL ~D seed=~D step=~D action=~D delta=~,4F~%"
                                         trials seed step index (getf record :delta))
                                 (finish-output)))))))))))
             (setf records (stable-sort records #'> :key (lambda (r) (getf r :delta))))
             (with-open-file (out (merge-pathnames "interventions.tsv" directory)
                                  :direction :output :if-exists :supersede)
               (format out "seed~Cstep~Caction~Cdelta~Cbaseline~Cbranch~%" #\Tab #\Tab #\Tab #\Tab #\Tab)
               (dolist (record records)
                 (format out "~D~C~D~C~D~C~,6F~C~,6F~C~,6F~%"
                         (getf record :seed) #\Tab (getf record :step) #\Tab
                         (getf record :action-index) #\Tab (getf record :delta) #\Tab
                         (getf record :baseline-return) #\Tab (getf record :branch-return))))

             (write-readable-object-atomically
              (list :protocol +privileged-search-protocol+ :source checkpoint
                    :baseline-mean parent-mean :trials trials :opportunities records)
              (merge-pathnames "opportunities.sexp" directory))
             (let ((candidate-count 0) (opportunity-count 0)
                   (seen (make-hash-table :test #'equal)))
               (dolist (record records)
                 (when (and (plusp (getf record :delta))
                            (< opportunity-count top-opportunities))
                   (let* ((event (getf record :event))
                          (probe (getf event :policy-observation))
                          (pair (getf record :pair))
                          (gates (brute-predicate-variants probe background)))
                     (incf opportunity-count)
                     (dolist (gate gates)
                       (dolist (insertion '(:terminal :root))
                         (dolist (margin '(250.0d0 1000.0d0))
                           (let ((key (list pair gate insertion margin)))
                             (when (and (< candidate-count max-candidates)
                                        (not (gethash key seen)))
                               (setf (gethash key seen) t)
                               (incf candidate-count)
                               (let* ((id (format nil "candidate-~D" candidate-count))
                                      (spec (list :id id :probe probe :target (first pair)
                                                  :response (second pair) :predicates gate
                                                  :margin margin :insertion insertion
                                                  :terminal (getf event :terminal-team)))
                                      (path (merge-pathnames
                                             (format nil "~A.lisp" id) directory))
                                      (result-path (merge-pathnames
                                                    (format nil "~A-result.sexp" id)
                                                    directory))
                                      (child (incubation-child team spec))
                                      (outcome
                                        (cond
                                          ((probe-file result-path)
                                           (rare-failure-read-form result-path))
                                          ((null child)
                                           (list :id id :spec spec :status :team-limit))
                                          ((not (equal pair (incubation-policy-pair child probe)))
                                           (list :id id :spec spec :status :inactive))
                                          (t
                                           (let* ((returns
                                                    (loop for seed in seeds
                                                          collect
                                                          (getf
                                                           (brute-episode
                                                            env controller child environment
                                                            seed work-log)
                                                           :return)))
                                                  (mean (arithmetic-mean returns))
                                                  (collateral
                                                    (loop for obs in background
                                                          count (not
                                                           (equal
                                                            (incubation-policy-pair team obs)
                                                            (incubation-policy-pair child obs))))))
                                             (brute-save-policy child mean path metadata environment)
                                             ;; Reload and replay: the standalone genotype must
                                             ;; reproduce the same discovered return.
                                             (let ((loaded (load-best-team path)))
                                               (loop for seed in seeds for expected in returns
                                                     for actual =
                                                       (getf (brute-episode
                                                              env controller loaded environment
                                                              seed work-log) :return)
                                                     unless (= actual expected)
                                                       do (error "Saved candidate replay differs.")))
                                             (list :id id :spec spec :status :evaluated
                                                   :checkpoint (namestring path)
                                                   :returns returns :mean mean
                                                   :delta (- mean parent-mean)
                                                   :changed-background collateral
                                                   :background-count (length background)))))))
                                 (write-readable-object-atomically outcome result-path)
                                 (push outcome variants)
                                 (when (and (getf outcome :mean)
                                            (> (getf outcome :mean) best-mean))
                                   (setf best-mean (getf outcome :mean)
                                         best-path (getf outcome :checkpoint)))
                                 (format t "~&CANDIDATE ~A status=~A delta=~A~%"
                                         id (getf outcome :status) (getf outcome :delta))
                                 (finish-output)))))))))))
             (let ((summary (list :source checkpoint :source-mean parent-mean
                                  :best-path best-path :best-mean best-mean
                                  :improved (> best-mean parent-mean)
                                  :trials trials :candidates (nreverse variants))))
               (write-readable-object-atomically summary
                                        (merge-pathnames "round-summary.sexp" directory))
               summary)))
      (py4cl2:pymethod env "close"))))

(defun run-privileged-brute-search
       (&key checkpoint output environment seeds steps actions rounds
             max-branches max-candidates top-opportunities)
  (let* ((*num-observations* 62) (*num-actions* 36)
         (*factored-actions-enabled* t) (*terminal-action-format* :target-response-36)
         (*instruction-set-profile* :reduced-eq)
         (*read-only-register-profile* :cage2-categorical-v1)
         (*decoy-order-mode* :fixed) (*cage2-opening-mode* :fixed)
         (*recurrent-policy-enabled* nil) (*hamming-space-enabled* nil)
         (*random-state* (sb-ext:seed-random-state 153))
         (directory (uiop:ensure-directory-pathname output))
         (current checkpoint) (summaries nil))
    (py4cl2:pyexec (uiop:read-file-string
                   (merge-pathnames "scripts/privileged-state.py"
                                    (asdf:system-source-directory :cl-tpg))))
    (loop for round from 1 to rounds
          for round-directory =
            (merge-pathnames (format nil "round-~D/" round) directory)
          for completed = (merge-pathnames "round-summary.sexp" round-directory)
          for summary =
            (if (probe-file completed) (rare-failure-read-form completed)
                (brute-round current round-directory environment seeds steps actions
                             max-branches max-candidates top-opportunities))
          do (push summary summaries)
             (setf current (getf summary :best-path))
             (format t "~&ROUND ~D source=~A best=~A improved=~A~%"
                     round (getf summary :source-mean) (getf summary :best-mean)
                     (getf summary :improved))
             (finish-output)
          unless (getf summary :improved) do (return))
    (write-readable-object-atomically
     (list :protocol +privileged-search-protocol+ :source checkpoint
           :search-seeds seeds :best-path current
           :rounds (nreverse summaries)
           :evidence :fixed-seed-discovery-only)
     (merge-pathnames "search-summary.sexp" directory))
    (format t "~&done~%")))
