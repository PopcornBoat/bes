(in-package :cl-tpg)

(defconstant +counterfactual-credit-protocol+
  :counterfactual-credit-v1)

(defconstant +counterfactual-request-protocol+
  :counterfactual-credit-request-v1)

(defun counterfactual-valid-pair-p (pair)
  (and (typep pair 'sequence)
       (= (length pair) 2)
       (let ((target (elt pair 0))
             (response (elt pair 1)))
         (and (integerp target)
              (<= 0 target)
              (< target +num-semantic-targets+)
              (integerp response)
              (<= 0 response)
              (< response +num-semantic-responses+)
              (or (/= target +global-target+) (= response 0))))))

(defun counterfactual-validate-request (request)
  "Validate and return one frozen counterfactual repair counterfactual request."
  (unless (eq (getf request :protocol)
              +counterfactual-request-protocol+)
    (error "Unknown counterfactual repair request protocol: ~S"
           (getf request :protocol)))
  (dolist (key '(:checkpoint :discovery-seeds :holdout-seeds
                 :teacher-pair :behavior-pair))
    (unless (getf request key)
      (error "counterfactual repair request is missing ~S." key)))
  (dolist (key '(:teacher-pair :behavior-pair))
    (unless (counterfactual-valid-pair-p (getf request key))
      (error "counterfactual repair request has invalid ~S: ~S"
             key (getf request key))))
  (let ((discovery (getf request :discovery-seeds))
        (holdout (getf request :holdout-seeds)))
    (dolist (entry (append discovery holdout))
      (unless (and (integerp entry) (<= 0 entry) (< entry 9999999))
        (error "counterfactual repair seed must be an integer in [0, 9999999): ~S"
               entry)))
    (unless (= (length discovery)
               (length (remove-duplicates discovery)))
      (error "counterfactual repair discovery seeds contain duplicates."))
    (unless (= (length holdout)
               (length (remove-duplicates holdout)))
      (error "counterfactual repair holdout seeds contain duplicates."))
    (when (intersection discovery holdout)
      (error "counterfactual repair discovery and holdout seed blocks overlap.")))
  request)

(defun counterfactual-matching-event-p
       (step teacher-pair behavior-pair)
  "Return true when STEP is the requested non-opening disagreement group."
  (and (null (getf step :opening-pairs))
       (getf step :teacher-disagreement-p)
       (equal teacher-pair
              (getf (getf step :teacher-decision) :pair))
       (equal behavior-pair
              (getf (getf step :executed-decision) :pair))))

(defun counterfactual-find-event (episode teacher-pair behavior-pair)
  "Return the first matching baseline step, or NIL.

counterfactual repair intentionally performs one intervention per episode so its paired
return difference has a single causal action change at the divergence point."
  (find-if
   (lambda (step)
     (counterfactual-matching-event-p step teacher-pair behavior-pair))
   (getf episode :steps)))

(defun counterfactual-concrete-prefix (episode intervention-step)
  "Return the exact concrete-action prefix before INTERVENTION-STEP."
  (loop for step in (getf episode :steps)
        while (< (getf step :step) intervention-step)
        collect (getf step :actual-concrete-action)))

(defun counterfactual-prefix-return (episode intervention-step)
  "Return reward accumulated strictly before INTERVENTION-STEP."
  (loop for step in (getf episode :steps)
        while (< (getf step :step) intervention-step)
        sum (getf step :reward) into total
        finally (return (coerce total 'double-float))))

(defun counterfactual-make-intervention (event &key (source :teacher))
  "Freeze the baseline state and proposals needed for exact replay."
  (list :step (getf event :step)
        :source source
        :pair (getf (getf event :teacher-decision) :pair)
        :expected-policy-observation
          (copy-seq (getf event :policy-observation))
        :expected-teacher-pair
          (copy-list (getf (getf event :teacher-decision) :pair))
        :expected-behavior-pair
          (copy-list (getf (getf event :executed-decision) :pair))))

(defun counterfactual-paired-result
       (cohort seed baseline intervention event)
  "Build the serializable paired credit record for one intervention."
  (let* ((step (getf event :step))
         (prefix-return (counterfactual-prefix-return baseline step))
         (baseline-return (getf baseline :return))
         (intervention-return (getf intervention :return))
         (baseline-rtg (- baseline-return prefix-return))
         (intervention-rtg (- intervention-return prefix-return))
         (delta (- intervention-rtg baseline-rtg))
         (intervention-step
           (find step (getf intervention :steps)
                 :key (lambda (entry) (getf entry :step)))))
    (unless (and (getf intervention :intervention-executed-p)
                 (getf intervention :prefix-verified-p)
                 (getf intervention-step :intervention-p))
      (error "counterfactual repair intervention audit failed for seed ~D step ~D."
             seed step))
    (list :cohort cohort
          :seed seed
          :step step
          :status :evaluated
          :teacher-pair
            (getf (getf event :teacher-decision) :pair)
          :behavior-pair
            (getf (getf event :executed-decision) :pair)
          :teacher-rank-in-behavior
            (getf event :teacher-rank-in-behavior)
          :baseline-concrete-action
            (getf event :actual-concrete-action)
          :intervention-concrete-action
            (getf intervention-step :actual-concrete-action)
          :prefix-length step
          :prefix-return prefix-return
          :baseline-return baseline-return
          :intervention-return intervention-return
          :baseline-return-to-go baseline-rtg
          :intervention-return-to-go intervention-rtg
          :paired-delta delta
          :baseline-catastrophic-p (getf baseline :catastrophic-p)
          :intervention-catastrophic-p
            (getf intervention :catastrophic-p))))

(defun counterfactual-mean (values)
  (when values
    (/ (reduce #'+ values) (coerce (length values) 'double-float))))

(defun counterfactual-sample-standard-deviation (values)
  (cond
    ((null values) nil)
    ((null (rest values)) 0.0d0)
    (t
     (let ((mean (counterfactual-mean values)))
       (sqrt
        (/ (loop for value in values
                 sum (expt (- value mean) 2))
           (1- (length values))))))))

(defun counterfactual-cohort-summary (cohort records requested-count)
  "Summarize paired counterfactual deltas for one frozen seed cohort."
  (let* ((evaluated
           (remove :evaluated records :key (lambda (x) (getf x :status))
                   :test-not #'eq))
         (deltas (mapcar (lambda (x) (getf x :paired-delta)) evaluated))
         (mean (counterfactual-mean deltas))
         (std (counterfactual-sample-standard-deviation deltas))
         (se (and std
                  (/ std (sqrt (coerce (length deltas) 'double-float))))))
    (list :cohort cohort
          :requested-seeds requested-count
          :eligible-events (length evaluated)
          :coverage (if (plusp requested-count)
                        (/ (length evaluated)
                           (coerce requested-count 'double-float))
                        0.0d0)
          :positive (count-if (lambda (x) (plusp x)) deltas)
          :zero (count-if #'zerop deltas)
          :negative (count-if (lambda (x) (minusp x)) deltas)
          :mean-delta mean
          :standard-deviation std
          :standard-error se
          :normal-95-percent-interval
            (and mean se
                 (list (- mean (* 1.96d0 se))
                       (+ mean (* 1.96d0 se))))
          :minimum (and deltas (reduce #'min deltas))
          :maximum (and deltas (reduce #'max deltas)))))

(defun counterfactual-run-cohort
       (cohort seeds env controller policies environment-name
        teacher-pair behavior-pair source)
  "Run baseline/intervention pairs for one independent seed block."
  (let ((records nil)
        (trajectories nil))
    (dolist (seed seeds)
      (let* ((baseline
               (rare-failure-trace-episode
                env controller policies :v17 environment-name seed))
             (event
               (counterfactual-find-event baseline teacher-pair behavior-pair)))
        (if (null event)
            (progn
              (push (list :cohort cohort :seed seed
                          :status :no-eligible-event)
                    records)
              (push (list :cohort cohort :seed seed :baseline baseline
                          :intervention nil)
                    trajectories)
              (format t "counterfactual cohort=~A seed=~D no eligible event.~%"
                      cohort seed))
            (let* ((step (getf event :step))
                   (spec (counterfactual-make-intervention event :source source))
                   (intervention
                     (rare-failure-trace-episode
                      env controller policies :v17 environment-name seed
                      :intervention spec
                      :expected-prefix
                        (counterfactual-concrete-prefix baseline step)))
                   (record
                     (counterfactual-paired-result
                      cohort seed baseline intervention event)))
              (push record records)
              (push (list :cohort cohort :seed seed :baseline baseline
                          :intervention intervention)
                    trajectories)
              (format t
                      "counterfactual cohort=~A seed=~D step=~D baseline=~,4F intervention=~,4F delta=~,4F~%"
                      cohort seed step
                      (getf record :baseline-return)
                      (getf record :intervention-return)
                      (getf record :paired-delta))))
        (finish-output)))
    (values (nreverse records) (nreverse trajectories))))

(defun run-counterfactual-credit (request-path output-directory)
  "Measure one systematic disagreement with official paired interventions."
  (let* ((request (counterfactual-validate-request (rare-failure-read-form request-path)))
         (output-directory
           (uiop:ensure-directory-pathname output-directory))
         (environment-name
           (or (getf request :environment) "Cage2-b_line-100-v0"))
         (source (or (getf request :intervention-source) :teacher))
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
           (list (rare-failure-load-policy :v17 (getf request :checkpoint))))
         (env nil)
         (controller nil)
         (all-records nil)
         (all-trajectories nil))
    (unless (member source '(:teacher :semantic-pair))
      (error "Unsupported counterfactual repair intervention source: ~S" source))
    (rare-failure-write-form
     request (merge-pathnames "request.sexp" output-directory))
    (py4cl2:pyexec "import gymnasium as gym; import cage2_bridge")
    (setf env (cl-gym::make environment-name)
          controller
            (make-cage2-controller :decoy-order-profile :heuristic))
    (cl-gym::configure-cage2-controller-option-orders env controller)
    (unwind-protect
         (dolist (cohort-spec
                   (list (cons :discovery (getf request :discovery-seeds))
                         (cons :holdout (getf request :holdout-seeds))))
           (multiple-value-bind (records trajectories)
               (counterfactual-run-cohort
                (car cohort-spec) (cdr cohort-spec)
                env controller policies environment-name
                (getf request :teacher-pair)
                (getf request :behavior-pair)
                source)
             (setf all-records (nconc all-records records)
                   all-trajectories
                     (nconc all-trajectories trajectories))))
      (when env
        (ignore-errors (py4cl2:pymethod env "close"))))
    (let* ((discovery-records
             (remove :discovery all-records
                     :key (lambda (x) (getf x :cohort)) :test-not #'eq))
           (holdout-records
             (remove :holdout all-records
                     :key (lambda (x) (getf x :cohort)) :test-not #'eq))
           (summary
             (list
              :protocol +counterfactual-credit-protocol+
              :checkpoint (getf request :checkpoint)
              :environment environment-name
              :intervention-source source
              :teacher-pair (getf request :teacher-pair)
              :behavior-pair (getf request :behavior-pair)
              :discovery
                (counterfactual-cohort-summary
                 :discovery discovery-records
                 (length (getf request :discovery-seeds)))
              :holdout
                (counterfactual-cohort-summary
                 :holdout holdout-records
                 (length (getf request :holdout-seeds))))))
      (rare-failure-write-form
       all-records (merge-pathnames "paired-results.sexp" output-directory))
      (rare-failure-write-form
       all-trajectories
       (merge-pathnames "counterfactual-trajectories.sexp" output-directory))
      (rare-failure-write-form
       summary (merge-pathnames "summary.sexp" output-directory))
      summary)))

(defun run-counterfactual-credit-from-environment ()
  "Run counterfactual repair from launcher-supplied paths."
  (flet ((required (name)
           (or (uiop:getenv name)
               (error "Required environment variable ~A is missing." name))))
    (run-counterfactual-credit
     (required "COUNTERFACTUAL_REQUEST")
     (required "COUNTERFACTUAL_OUTPUT_DIRECTORY"))))

(defun counterfactual-step-bucket (step)
  (cond
    ((< step 20) :early)
    ((< step 50) :middle)
    (t :late)))

(defun counterfactual-delta-class (delta &optional (epsilon 1.0d-9))
  (cond
    ((> delta epsilon) :positive)
    ((< delta (- epsilon)) :negative)
    (t :zero)))

(defun counterfactual-delta-summary (records)
  "Summarize :PAIRED-DELTA values without treating floating noise as effect."
  (let* ((deltas (mapcar (lambda (x) (getf x :paired-delta)) records))
         (mean (counterfactual-mean deltas))
         (std (counterfactual-sample-standard-deviation deltas))
         (se (and std
                  (/ std (sqrt (coerce (length deltas) 'double-float))))))
    (list :count (length records)
          :positive
            (count :positive deltas :key #'counterfactual-delta-class)
          :zero (count :zero deltas :key #'counterfactual-delta-class)
          :negative
            (count :negative deltas :key #'counterfactual-delta-class)
          :mean-delta mean
          :standard-deviation std
          :standard-error se
          :normal-95-percent-interval
            (and mean se
                 (list (- mean (* 1.96d0 se))
                       (+ mean (* 1.96d0 se)))))))

(defun counterfactual-context-group-summaries
       (records key-function &key (minimum-count 1))
  "Group RECORDS by KEY-FUNCTION and return count-sorted delta summaries."
  (let ((groups (make-hash-table :test #'equal)))
    (dolist (record records)
      (push record (gethash (funcall key-function record) groups)))
    (sort
     (loop for key being the hash-keys of groups
             using (hash-value entries)
           when (>= (length entries) minimum-count)
             collect (list :key key
                           :statistics (counterfactual-delta-summary entries)))
     #'> :key (lambda (entry)
                (getf (getf entry :statistics) :count)))))

(defun counterfactual-find-v17-proposal (step)
  (or (find :v17 (getf step :policy-proposals)
            :key (lambda (proposal) (getf proposal :label))
            :test #'eq)
      (error "counterfactual repair context step has no V17 proposal.")))

(defun counterfactual-context-record (paired trajectory)
  "Join one compact paired result to its baseline/intervention context."
  (let* ((step-number (getf paired :step))
         (baseline (getf trajectory :baseline))
         (intervention (getf trajectory :intervention))
         (baseline-step
           (find step-number (getf baseline :steps)
                 :key (lambda (step) (getf step :step))))
         (intervention-step
           (find step-number (getf intervention :steps)
                 :key (lambda (step) (getf step :step))))
         (proposal (counterfactual-find-v17-proposal baseline-step))
         (observation (getf baseline-step :policy-observation))
         (delta (getf paired :paired-delta))
         (immediate-delta
           (- (getf intervention-step :reward)
              (getf baseline-step :reward))))
    (unless (and baseline-step intervention-step)
      (error "counterfactual repair context is missing seed ~D step ~D."
             (getf paired :seed) step-number))
    (list
     :cohort (getf paired :cohort)
     :seed (getf paired :seed)
     :step step-number
     :step-bucket (counterfactual-step-bucket step-number)
     :paired-delta delta
     :delta-class (counterfactual-delta-class delta)
     :immediate-reward-delta immediate-delta
     :downstream-delta (- delta immediate-delta)
     :baseline-return (getf paired :baseline-return)
     :intervention-return (getf paired :intervention-return)
     :teacher-rank-in-behavior (getf paired :teacher-rank-in-behavior)
     :teacher-option
       (getf (getf baseline-step :teacher-decision) :option)
     :teacher-concrete-action
       (getf paired :intervention-concrete-action)
     :behavior-concrete-action
       (getf paired :baseline-concrete-action)
     :behavior-winning-learner (getf proposal :winning-learner)
     :behavior-terminal-team (getf proposal :terminal-team)
     :behavior-path-length (length (getf proposal :preferred-path))
     :behavior-ranking (copy-tree (getf proposal :ranking))
     :decoy-mask-before (getf baseline-step :decoy-mask-before)
     :enterprise0-observation
       (coerce (subseq observation 4 8) 'list)
     :op-server0-observation
       (coerce (subseq observation 28 32) 'list)
     :scan-state
       (coerce (subseq observation
                       +cage2-raw-observation-size+
                       +cage2-scan-observation-size+)
               'list)
     :policy-observation (coerce observation 'list))))

(defun run-counterfactual-context-analysis (input-directory output-path)
  "Explain context dependence in a completed counterfactual repair paired experiment."
  (let* ((directory (uiop:ensure-directory-pathname input-directory))
         (paired
           (rare-failure-read-form
            (merge-pathnames "paired-results.sexp" directory)))
         (trajectories
           (rare-failure-read-form
            (merge-pathnames "counterfactual-trajectories.sexp" directory)))
         (evaluated
           (remove-if-not
            (lambda (record) (eq (getf record :status) :evaluated))
            paired))
         (contexts
           (mapcar
            (lambda (record)
              (let ((trajectory
                      (find-if
                       (lambda (entry)
                         (and (eq (getf entry :cohort)
                                  (getf record :cohort))
                              (= (getf entry :seed)
                                 (getf record :seed))))
                       trajectories)))
                (unless trajectory
                  (error "Missing trajectory for ~S seed ~D."
                         (getf record :cohort) (getf record :seed)))
                (counterfactual-context-record record trajectory)))
            evaluated))
         (report
           (list
            :protocol :counterfactual-context-analysis-v1
            :source-directory (namestring directory)
            :note
              "All inspected cohorts are discovery material; derived groups require a new holdout stream."
            :overall (counterfactual-delta-summary contexts)
            :by-cohort
              (counterfactual-context-group-summaries
               contexts (lambda (x) (getf x :cohort)))
            :by-step-bucket
              (counterfactual-context-group-summaries
               contexts (lambda (x) (getf x :step-bucket)))
            :by-teacher-rank
              (counterfactual-context-group-summaries
               contexts (lambda (x) (getf x :teacher-rank-in-behavior)))
            :by-teacher-option
              (counterfactual-context-group-summaries
               contexts (lambda (x) (getf x :teacher-option)))
            :by-immediate-reward-delta
              (counterfactual-context-group-summaries
               contexts (lambda (x) (getf x :immediate-reward-delta)))
            :by-decoy-mask
              (counterfactual-context-group-summaries
               contexts (lambda (x) (getf x :decoy-mask-before)))
            :by-scan-state
              (counterfactual-context-group-summaries
               contexts (lambda (x) (getf x :scan-state)))
            :by-winning-learner
              (counterfactual-context-group-summaries
               contexts (lambda (x) (getf x :behavior-winning-learner)))
            :by-path-length
              (counterfactual-context-group-summaries
               contexts (lambda (x) (getf x :behavior-path-length)))
            :repeated-policy-observations
              (counterfactual-context-group-summaries
               contexts (lambda (x) (getf x :policy-observation))
               :minimum-count 2)
            :contexts contexts)))
    (rare-failure-write-form report output-path)
    report))

(defun run-counterfactual-context-analysis-from-environment ()
  "Run context analysis from launcher-supplied paths."
  (flet ((required (name)
           (or (uiop:getenv name)
               (error "Required environment variable ~A is missing." name))))
    (run-counterfactual-context-analysis
     (required "COUNTERFACTUAL_INPUT_DIRECTORY")
     (required "COUNTERFACTUAL_CONTEXT_OUTPUT"))))
