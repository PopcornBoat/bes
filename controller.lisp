(in-package :cl-tpg)

(defparameter +cage2-scan-observation-indices+
  #(0 4 8 12 28 32 36 40 44 48)
  "Raw observation indices used by the Cardiff-compatible scan tracker.")

(defstruct (cage2-controller
             (:constructor %make-cage2-controller))
  "Canonical episode-local state outside the evolved TPG policy.

TPG receives only the 52 raw values plus this controller's ten scan-history
values. Decoy availability is deliberately not policy input: the controller
uses it only to execute ranked target/response proposals safely."
  agreement
  decoy-order-profile
  option-orders
  (scan-state
    (make-array +cage2-scan-state-size+
                :element-type 'double-float
                :initial-element 0.0d0))
  (decoy-mask 0 :type integer)
  (step 0 :type integer))

(defstruct cage2-controller-decision
  "A pure proposal resolution result awaiting successful environment execution."
  semantic-action
  concrete-action
  rank
  option
  (fallback-p nil))

(defun make-cage2-controller
       (&key (agreement (ensure-cage2-action-agreement))
             (decoy-order-profile
               *cage2-controller-decoy-order-profile*))
  "Create an empty controller using an explicit fixed Decoy-order PROFILE.

PROFILE selection is independent from the teacher backend. This prevents a
teacher switch from silently changing deployment behavior."
  (let ((orders
          (action-agreement-decoy-orders-for-profile
           decoy-order-profile agreement)))
    (unless orders
      (error "Unknown CAGE2 controller Decoy-order profile: ~S"
             decoy-order-profile))
    (%make-cage2-controller
     :agreement agreement
     :decoy-order-profile decoy-order-profile
     :option-orders (copy-action-option-orders orders))))

(defun cage2-controller-reset (controller)
  "Clear all episode-local controller state and return CONTROLLER."
  (fill (cage2-controller-scan-state controller) 0.0d0)
  (setf (cage2-controller-decoy-mask controller) 0
        (cage2-controller-step controller) 0)
  controller)

(defun cage2-controller-observe (controller observation)
  "Consume one real CAGE2 observation and return the 62-value policy input.

Only the first 52 raw values are consumed, so callers may supply a raw or
already augmented bridge observation. Scan state is updated from observations
that actually occurred; policy and teacher proposal queries never call this
function. Values are 0=unseen, 1=previous scan, and 2=latest scan."
  (unless (and (typep observation 'sequence)
               (>= (length observation) +cage2-raw-observation-size+))
    (error "CAGE2 controller expected at least ~D observation values, got ~S."
           +cage2-raw-observation-size+
           (and (typep observation 'sequence) (length observation))))
  (let ((policy-observation
          (make-array +cage2-scan-observation-size+
                      :element-type 'double-float))
        (scan-state (cage2-controller-scan-state controller)))
    (dotimes (index +cage2-raw-observation-size+)
      (setf (aref policy-observation index)
            (coerce (elt observation index) 'double-float)))
    (loop for state-index below +cage2-scan-state-size+
          for observation-index across +cage2-scan-observation-indices+
          when (and (= (aref policy-observation observation-index) 1.0d0)
                    (= (aref policy-observation (1+ observation-index))
                       0.0d0))
            do (dotimes (index +cage2-scan-state-size+)
                 (when (= (aref scan-state index) 2.0d0)
                   (setf (aref scan-state index) 1.0d0)))
               (setf (aref scan-state state-index) 2.0d0)
               (loop-finish))
    (replace policy-observation scan-state
             :start1 +cage2-raw-observation-size+)
    policy-observation))

(defun cage2-controller-decoy-used-p (controller target option)
  "Return true when OPTION has already been executed on TARGET this episode."
  (and (integerp target)
       (< +global-target+ target +num-semantic-targets+)
       (integerp option)
       (<= 0 option 7)
       (logbitp (+ (* (1- target) 8) option)
                (cage2-controller-decoy-mask controller))))

(defun cage2-controller-first-available-decoy (controller target)
  "Return TARGET's first unused Decoy option under the controller order."
  (first-available-decoy-option
   target
   (cage2-controller-decoy-mask controller)
   (cage2-controller-option-orders controller)))

(defun cage2-controller-response-index (response)
  (position response *semantic-response-types* :test #'eq))

(defun cage2-semantic-pair-action (pair)
  "Convert one primitive (TARGET RESPONSE-INDEX) pair to a semantic action."
  (when (and (typep pair 'sequence)
             (= (length pair) 2))
    (let ((target (elt pair 0))
          (response (elt pair 1)))
      (when (and (integerp target)
                 (integerp response)
                 (<= 0 response)
                 (< response +num-semantic-responses+))
        (make-semantic-action
         :target target
         :response (if (= target +global-target+)
                       :monitor
                       (aref *semantic-response-types* response))
         :option nil)))))

(defun cage2-controller-resolve-pair-ranking (controller pairs)
  "Purely resolve primitive target/response PAIRS through CONTROLLER."
  (cage2-controller-resolve-ranking
   controller
   (loop for pair in (coerce pairs 'list)
         for action = (cage2-semantic-pair-action pair)
         when action collect action)))

(defun cage2-controller-valid-semantic-components (candidate)
  "Return TARGET, response index, and validity for CANDIDATE."
  (if (semantic-action-p candidate)
      (let ((target (semantic-action-target candidate))
            (response-index
              (cage2-controller-response-index
               (semantic-action-response candidate))))
        (cond
          ((and (integerp target) (= target +global-target+))
           (values target 0 t))
          ((and (integerp target)
                (< +global-target+ target +num-semantic-targets+)
                response-index)
           (values target response-index t))
          (t
           (values nil nil nil))))
      (values nil nil nil)))

(defun cage2-controller-concrete-action (controller target response-index option)
  "Map one validated semantic category to a concrete official CAGE2 action."
  (let* ((agreement (cage2-controller-agreement controller))
         (offsets (action-agreement-host-offsets agreement)))
    (if (= target +global-target+)
        (action-agreement-monitor-action agreement)
        (let ((offset (aref offsets target)))
          (case response-index
            (0 (+ (action-agreement-analyse-base agreement) offset))
            (1 (+ (action-agreement-remove-base agreement) offset))
            (2 (+ (action-agreement-restore-base agreement) offset))
            (3 (and option
                    (+ (aref (action-agreement-decoy-bases agreement) option)
                       offset)))
            (otherwise nil))))))

(defun make-cage2-controller-monitor-decision (controller &key (fallback-p t))
  (let ((monitor
          (make-semantic-action
           :target +global-target+ :response :monitor :option nil)))
    (make-cage2-controller-decision
     :semantic-action monitor
     :concrete-action
       (action-agreement-monitor-action
        (cage2-controller-agreement controller))
     :rank nil
     :option nil
     :fallback-p fallback-p)))

(defun cage2-controller-resolve-ranking (controller candidates)
  "Purely resolve ranked semantic CANDIDATES into an executable decision.

An exhausted Decoy advances to the next bid without re-running TPG. To retain
the established teacher/bridge rule, Restore is executable at rank zero but is
skipped after fallback has begun. Empty, malformed, or exhausted rankings end
in Monitor. This function never changes scan state, Decoy state, or step count;
only CAGE2-CONTROLLER-COMMIT-DECISION may do so after a real step succeeds."
  (block selected
    (loop for candidate in candidates
          for rank fixnum from 0 below +semantic-ranking-limit+
          do (multiple-value-bind (target response-index valid-p)
                 (cage2-controller-valid-semantic-components candidate)
               (when valid-p
                 (cond
                   ((= target +global-target+)
                    (let ((decision
                            (make-cage2-controller-monitor-decision
                             controller :fallback-p nil)))
                      (setf (cage2-controller-decision-rank decision) rank)
                      (return-from selected decision)))
                   ((and (> rank 0) (= response-index 2))
                    nil)
                   (t
                    (let ((option
                            (and (= response-index 3)
                                 (cage2-controller-first-available-decoy
                                  controller target))))
                      (when (or (/= response-index 3) option)
                        (let ((semantic
                                (make-semantic-action
                                 :target target
                                 :response
                                   (aref *semantic-response-types*
                                         response-index)
                                 :option option)))
                          (return-from selected
                            (make-cage2-controller-decision
                             :semantic-action semantic
                             :concrete-action
                               (cage2-controller-concrete-action
                                controller target response-index option)
                             :rank rank
                             :option option
                             :fallback-p nil))))))))))
    (make-cage2-controller-monitor-decision controller)))

(defun cage2-controller-clear-target-decoys (controller target)
  (let* ((shift (* (1- target) 8))
         (host-mask (ash #xff shift)))
    (setf (cage2-controller-decoy-mask controller)
          (logand (cage2-controller-decoy-mask controller)
                  (lognot host-mask)))))

(defun cage2-controller-commit-decision
       (controller decision &optional
                              (actual-concrete-action
                                (cage2-controller-decision-concrete-action
                                 decision)))
  "Commit DECISION after ACTUAL-CONCRETE-ACTION executed successfully.

The explicit concrete-action check prevents controller state from advancing
when a different teacher/student proposal was ultimately executed. Restore
clears only its target's Decoys; Decoy marks exactly the selected option."
  (unless (= actual-concrete-action
             (cage2-controller-decision-concrete-action decision))
    (error "Controller decision expected concrete action ~D, but ~D executed."
           (cage2-controller-decision-concrete-action decision)
           actual-concrete-action))
  (let* ((semantic (cage2-controller-decision-semantic-action decision))
         (target (semantic-action-target semantic))
         (response (semantic-action-response semantic)))
    (cond
      ((eq response :restore)
       (cage2-controller-clear-target-decoys controller target))
      ((eq response :decoy)
       (let ((option (cage2-controller-decision-option decision)))
         (unless (and (integerp option)
                      (not (cage2-controller-decoy-used-p
                            controller target option)))
           (error "Cannot commit unavailable Decoy target=~S option=~S."
                  target option))
         (setf (cage2-controller-decoy-mask controller)
               (logior (cage2-controller-decoy-mask controller)
                       (ash 1 (+ (* (1- target) 8) option)))))))
    (incf (cage2-controller-step controller))
    controller))

(defun cage2-controller-signature (controller)
  "Return the controller semantics needed for future checkpoint provenance."
  (list :protocol +cage2-controller-protocol+
        :agreement (action-agreement-signature
                    (cage2-controller-agreement controller))
        :decoy-order-profile
          (cage2-controller-decoy-order-profile controller)))
