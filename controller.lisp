(in-package :cl-tpg)

(defparameter *cage2-decoy-resolution* :ranked-decoy-hosts
  "Decoy arbitration after the first Decoy proposal.
:RANKED-DECOY-HOSTS uses Top-8 host order and each host's configured options.
:PROFILE uses global schedule priority for legacy scheduled profiles.
:RANKED follows the complete candidate order, including non-Decoys.")

;; Source: https://github.com/john-cardiff/-cyborg-cage-2/blob/main/Agents/PPOAgent.py
(defparameter +cardiff-ppo-decoy-actions+
  '((1 54 106 28 119)       ; Defender
    (2 55 107 120 29)       ; Enterprise0
    (3 43)                 ; Enterprise1
    (4 44)                 ; Enterprise2
    (5 61 35 113 126)      ; Op_Server0
    (7 37 115 76 102)      ; User1
    (8 51 116 38 90)       ; User2
    (9 130 91)             ; User3
    (10 131))              ; User4
  "Exact per-host greedy Decoy IDs in the public Cardiff PPOAgent deployment.")

(defun cage2-cardiff-decoy-schedule (agreement)
  "Convert the Cardiff host-local lists into shared target/option pairs."
  (loop for (target . concrete-actions) in +cardiff-ppo-decoy-actions+
        for offset = (aref (action-agreement-host-offsets agreement) target)
        append (loop for action in concrete-actions
                     for option = (position (- action offset)
                                            (action-agreement-decoy-bases agreement))
                     unless option do (error "Invalid Cardiff Decoy ~D for target ~D."
                                             action target)
                     collect (list target option))))

(defstruct (cage2-controller
             (:constructor %make-cage2-controller))
  "Canonical episode-local state outside the evolved TPG policy.

TPG receives the 62-value scan-state observation from the bridge. Decoy availability is deliberately not policy input: the controller
uses it only to execute ranked target/response proposals safely."
  agreement
  decoy-order-profile
  option-orders
  decoy-schedule
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
             (decoy-order-profile :ppo-greedy))
  "Create an empty Controller for the bridge and its fixed Decoy options."
  (check-type decoy-order-profile (member :model :ppo-greedy))
  (%make-cage2-controller
   :agreement agreement
   :decoy-order-profile decoy-order-profile
   :option-orders
     (action-agreement-decoy-orders-for-profile :model agreement)
   :decoy-schedule
     (when (eq decoy-order-profile :ppo-greedy)
       (cage2-cardiff-decoy-schedule agreement))))

(defun cage2-controller-reset (controller)
  "Clear all episode-local controller state and return CONTROLLER."
  (setf (cage2-controller-decoy-mask controller) 0
        (cage2-controller-step controller) 0)
  controller)

(defun cage2-controller-decoy-used-p (controller target option)
  "Return true when OPTION has already been executed on TARGET this episode."
  (and (integerp target)
       (< +global-target+ target +num-semantic-targets+)
       (integerp option)
       (<= 0 option 7)
       (logbitp (+ (* (1- target) 8) option)
                (cage2-controller-decoy-mask controller))))

(defun cage2-controller-first-available-decoy (controller target &optional ranked-p)
  "Return TARGET's first unused option, using its scheduled subset in ranked mode."
  (let ((schedule (cage2-controller-decoy-schedule controller)))
    (if (and schedule
             (or ranked-p (eq (cage2-controller-decoy-order-profile controller) :ppo-greedy)))
        (loop for (host option) in schedule
              when (and (= host target)
                        (not (cage2-controller-decoy-used-p controller host option)))
                return option)
        (first-available-decoy-option
         target
         (cage2-controller-decoy-mask controller)
         (cage2-controller-option-orders controller)))))

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

(defun cage2-controller-decoy-candidate-rank (candidates target)
  "Return the rank of TARGET's Decoy category, or NIL when absent."
  (loop for candidate in candidates
        for rank fixnum from 0 below +semantic-ranking-limit+
        do (multiple-value-bind (candidate-target response-index valid-p)
               (cage2-controller-valid-semantic-components candidate)
             (when (and valid-p
                        (= candidate-target target)
                        (= response-index 3))
               (return rank)))))

(defun cage2-controller-next-scheduled-decoy (controller candidates)
  "Return the first available scheduled target, option, and proposal rank.

Only targets represented by a Decoy category in CANDIDATES are eligible. The
schedule therefore resolves a TPG proposal; it does not create an action that
the policy omitted from its bounded semantic ranking."
  (loop for (target option) in (cage2-controller-decoy-schedule controller)
        unless (cage2-controller-decoy-used-p controller target option)
          do (let ((rank
                     (cage2-controller-decoy-candidate-rank
                      candidates target)))
               (when rank
                 (return (values target option rank))))))

(defun cage2-controller-next-ranked-decoy (controller candidates)
  "Return the first proposed Decoy host with an unused option and its rank."
  (loop for candidate in candidates
        for rank fixnum from 0 below +semantic-ranking-limit+
        do (multiple-value-bind (target response valid-p)
               (cage2-controller-valid-semantic-components candidate)
             (when (and valid-p (= response 3))
               (let ((option
                       (cage2-controller-first-available-decoy
                        controller target t)))
                 (when option
                   (return (values target option rank))))))))

(defun cage2-controller-resolve-ranking (controller candidates
                                         &key (decoy-resolution *cage2-decoy-resolution*))
  "Purely resolve ranked semantic CANDIDATES into an executable decision.

When resolving a Decoy in the default mode, exhaust its host's configured
options before trying the next Top-8 Decoy host. If no proposed host has an
option left, continue to the remaining non-Decoy proposals. Restore is
executable only at rank zero. Resolution never commits Controller state."
  (check-type decoy-resolution (member :profile :ranked :ranked-decoy-hosts))
  (block selected
    (loop with scheduled-decoy-considered-p = nil
          for candidate in candidates
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
                   ((and (= response-index 3)
                         (or (eq decoy-resolution :ranked-decoy-hosts)
                             (and (eq decoy-resolution :profile)
                                  (cage2-controller-decoy-schedule controller)
                                  (not (eq (cage2-controller-decoy-order-profile controller)
                                           :ppo-greedy)))))
                    (unless scheduled-decoy-considered-p
                      (setf scheduled-decoy-considered-p t)
                      (multiple-value-bind
                            (scheduled-target option scheduled-rank)
                          (if (eq decoy-resolution :ranked-decoy-hosts)
                              (cage2-controller-next-ranked-decoy
                               controller candidates)
                              (cage2-controller-next-scheduled-decoy
                               controller candidates))
                        (when scheduled-target
                          (let ((semantic
                                  (make-semantic-action
                                   :target scheduled-target
                                   :response :decoy
                                   :option option)))
                            (return-from selected
                              (make-cage2-controller-decision
                               :semantic-action semantic
                               :concrete-action
                                 (cage2-controller-concrete-action
                                  controller scheduled-target 3 option)
                               :rank scheduled-rank
                               :option option
                               :fallback-p nil)))))))
                   (t
                    (let ((option
                            (and (= response-index 3)
                                 (cage2-controller-first-available-decoy
                                  controller target (eq decoy-resolution :ranked)))))
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
