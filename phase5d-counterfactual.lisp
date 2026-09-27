(in-package :cl-tpg)

(defconstant +phase5d-counterfactual-credit-protocol+
  :phase5d-counterfactual-credit-v1)

(defconstant +phase5d-counterfactual-request-protocol+
  :phase5d-counterfactual-credit-request-v1)

(defun phase5d-valid-pair-p (pair)
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

(defun phase5d-validate-request (request)
  "Validate and return one frozen Phase 5D counterfactual request."
  (unless (eq (getf request :protocol)
              +phase5d-counterfactual-request-protocol+)
    (error "Unknown Phase 5D request protocol: ~S"
           (getf request :protocol)))
  (dolist (key '(:checkpoint :discovery-seeds :holdout-seeds
                 :teacher-pair :behavior-pair))
    (unless (getf request key)
      (error "Phase 5D request is missing ~S." key)))
  (dolist (key '(:teacher-pair :behavior-pair))
    (unless (phase5d-valid-pair-p (getf request key))
      (error "Phase 5D request has invalid ~S: ~S"
             key (getf request key))))
  (let ((discovery (getf request :discovery-seeds))
        (holdout (getf request :holdout-seeds)))
    (dolist (entry (append discovery holdout))
      (unless (and (integerp entry) (<= 0 entry) (< entry 9999999))
        (error "Phase 5D seed must be an integer in [0, 9999999): ~S"
               entry)))
    (unless (= (length discovery)
               (length (remove-duplicates discovery)))
      (error "Phase 5D discovery seeds contain duplicates."))
    (unless (= (length holdout)
               (length (remove-duplicates holdout)))
      (error "Phase 5D holdout seeds contain duplicates."))
    (when (intersection discovery holdout)
      (error "Phase 5D discovery and holdout seed blocks overlap.")))
  request)

(defun phase5d-matching-event-p
       (step teacher-pair behavior-pair)
  "Return true when STEP is the requested non-opening disagreement group."
  (and (null (getf step :opening-pairs))
       (getf step :teacher-disagreement-p)
       (equal teacher-pair
              (getf (getf step :teacher-decision) :pair))
       (equal behavior-pair
              (getf (getf step :executed-decision) :pair))))

(defun phase5d-find-event (episode teacher-pair behavior-pair)
  "Return the first matching baseline step, or NIL.

Phase 5D intentionally performs one intervention per episode so its paired
return difference has a single causal action change at the divergence point."
  (find-if
   (lambda (step)
     (phase5d-matching-event-p step teacher-pair behavior-pair))
   (getf episode :steps)))

(defun phase5d-concrete-prefix (episode intervention-step)
  "Return the exact concrete-action prefix before INTERVENTION-STEP."
  (loop for step in (getf episode :steps)
        while (< (getf step :step) intervention-step)
        collect (getf step :actual-concrete-action)))

(defun phase5d-prefix-return (episode intervention-step)
  "Return reward accumulated strictly before INTERVENTION-STEP."
  (loop for step in (getf episode :steps)
        while (< (getf step :step) intervention-step)
        sum (getf step :reward) into total
        finally (return (coerce total 'double-float))))

(defun phase5d-make-intervention (event &key (source :teacher))
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

(defun phase5d-paired-result
       (cohort seed baseline intervention event)
  "Build the serializable paired credit record for one intervention."
  (let* ((step (getf event :step))
         (prefix-return (phase5d-prefix-return baseline step))
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
      (error "Phase 5D intervention audit failed for seed ~D step ~D."
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

(defun phase5d-mean (values)
  (when values
    (/ (reduce #'+ values) (coerce (length values) 'double-float))))

(defun phase5d-sample-standard-deviation (values)
  (cond
    ((null values) nil)
    ((null (rest values)) 0.0d0)
    (t
     (let ((mean (phase5d-mean values)))
       (sqrt
        (/ (loop for value in values
                 sum (expt (- value mean) 2))
           (1- (length values))))))))

(defun phase5d-cohort-summary (cohort records requested-count)
  "Summarize paired counterfactual deltas for one frozen seed cohort."
  (let* ((evaluated
           (remove :evaluated records :key (lambda (x) (getf x :status))
                   :test-not #'eq))
         (deltas (mapcar (lambda (x) (getf x :paired-delta)) evaluated))
         (mean (phase5d-mean deltas))
         (std (phase5d-sample-standard-deviation deltas))
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

(defun phase5d-run-cohort
       (cohort seeds env controller policies environment-name
        teacher-pair behavior-pair source)
  "Run baseline/intervention pairs for one independent seed block."
  (let ((records nil)
        (trajectories nil))
    (dolist (seed seeds)
      (let* ((baseline
               (phase5c-trace-episode
                env controller policies :v17 environment-name seed))
             (event
               (phase5d-find-event baseline teacher-pair behavior-pair)))
        (if (null event)
            (progn
              (push (list :cohort cohort :seed seed
                          :status :no-eligible-event)
                    records)
              (push (list :cohort cohort :seed seed :baseline baseline
                          :intervention nil)
                    trajectories)
              (format t "Phase5D cohort=~A seed=~D no eligible event.~%"
                      cohort seed))
            (let* ((step (getf event :step))
                   (spec (phase5d-make-intervention event :source source))
                   (intervention
                     (phase5c-trace-episode
                      env controller policies :v17 environment-name seed
                      :intervention spec
                      :expected-prefix
                        (phase5d-concrete-prefix baseline step)))
                   (record
                     (phase5d-paired-result
                      cohort seed baseline intervention event)))
              (push record records)
              (push (list :cohort cohort :seed seed :baseline baseline
                          :intervention intervention)
                    trajectories)
              (format t
                      "Phase5D cohort=~A seed=~D step=~D baseline=~,4F intervention=~,4F delta=~,4F~%"
                      cohort seed step
                      (getf record :baseline-return)
                      (getf record :intervention-return)
                      (getf record :paired-delta))))
        (finish-output)))
    (values (nreverse records) (nreverse trajectories))))

(defun run-phase5d-counterfactual-credit (request-path output-directory)
  "Measure one systematic disagreement with official paired interventions."
  (let* ((request (phase5d-validate-request (phase5c-read-form request-path)))
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
           (list (phase5c-load-policy :v17 (getf request :checkpoint))))
         (env nil)
         (controller nil)
         (all-records nil)
         (all-trajectories nil))
    (unless (member source '(:teacher :semantic-pair))
      (error "Unsupported Phase 5D intervention source: ~S" source))
    (phase5c-write-form
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
               (phase5d-run-cohort
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
              :protocol +phase5d-counterfactual-credit-protocol+
              :checkpoint (getf request :checkpoint)
              :environment environment-name
              :intervention-source source
              :teacher-pair (getf request :teacher-pair)
              :behavior-pair (getf request :behavior-pair)
              :discovery
                (phase5d-cohort-summary
                 :discovery discovery-records
                 (length (getf request :discovery-seeds)))
              :holdout
                (phase5d-cohort-summary
                 :holdout holdout-records
                 (length (getf request :holdout-seeds))))))
      (phase5c-write-form
       all-records (merge-pathnames "paired-results.sexp" output-directory))
      (phase5c-write-form
       all-trajectories
       (merge-pathnames "counterfactual-trajectories.sexp" output-directory))
      (phase5c-write-form
       summary (merge-pathnames "summary.sexp" output-directory))
      summary)))

(defun run-phase5d-counterfactual-credit-from-environment ()
  "Run Phase 5D from launcher-supplied paths."
  (flet ((required (name)
           (or (uiop:getenv name)
               (error "Required environment variable ~A is missing." name))))
    (run-phase5d-counterfactual-credit
     (required "PHASE5D_REQUEST")
     (required "PHASE5D_OUTPUT_DIRECTORY"))))
