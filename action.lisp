(in-package :cl-tpg)

(defstruct factored-action
  "Categorical terminal payload evolved by BES.

PRIMARY identifies the environment target and SECONDARY identifies the response
category. The neutral names keep the TPG core reusable with other environments;
the loaded action agreement assigns their external meanings."
  (primary (random *num-actions*) :type integer)
  (secondary (random +num-semantic-responses+) :type integer))

(defparameter *semantic-36-targets* #(1 2 3 4 5 7 8 9 10)
  "The nine learned CAGE2 hosts in the Semantic-36 policy head.

GLOBAL/Monitor is a controller fallback and User0 is not a learned response
target, matching the established teacher action vocabulary.")

(defparameter *semantic-36-catalogue*
  #((2 2) (3 2) (4 2) (5 2)
    (2 0) (3 0) (4 0) (5 0)
    (2 1) (3 1) (4 1) (5 1)
    (7 0) (8 0) (9 0) (10 0)
    (7 2) (8 2) (9 2) (10 2)
    (1 2) (1 0) (1 1)
    (7 1) (8 1) (9 1) (10 1)
    (2 3) (3 3) (4 3) (7 3) (8 3) (9 3) (10 3) (1 3) (5 3))
  "Version 1 Semantic-36 catalogue in the trained teacher's canonical order.

Every entry is (TARGET RESPONSE-INDEX), where response indices are Analyse=0,
Remove=1, Restore=2, and Decoy=3. This is exactly the Cartesian product of the
nine learned hosts and four response types, ordered to match the existing
36-output teacher vocabulary.")

(defconstant +semantic-36-catalogue-version+ :cage2-semantic-36-v1
  "Stable schema identifier for *SEMANTIC-36-CATALOGUE*.")

(defstruct semantic-36-action
  "One categorical terminal gene in the versioned Semantic-36 catalogue."
  (index (random +num-semantic-36-actions+) :type integer))

(defun semantic-36-index-pair (index)
  "Return a fresh (TARGET RESPONSE-INDEX) pair for valid INDEX, else NIL."
  (when (and (integerp index)
             (<= 0 index)
             (< index (length *semantic-36-catalogue*)))
    (copy-list (aref *semantic-36-catalogue* index))))

(defun semantic-36-pair-index (target response-index)
  "Return the Semantic-36 index for TARGET and RESPONSE-INDEX, else NIL."
  (position (list target response-index)
            *semantic-36-catalogue*
            :test #'equal))

(defun make-random-atomic-action-value ()
  "Create an atomic payload for the currently configured policy contract."
  (cond
    ((not *factored-actions-enabled*)
     (random *num-actions*))
    ((eq *terminal-action-format* :factored)
     (make-factored-action))
    ((eq *terminal-action-format* :semantic-36)
     (make-semantic-36-action))
    (t
     (error "Unsupported terminal action format: ~S"
            *terminal-action-format*))))

(defstruct action
  (type :atomic)
  (action (make-random-atomic-action-value)))

(defstruct semantic-action
  "Structured BES policy output for the hierarchical CAGE2 action space.

TARGET and host RESPONSE come from the final terminal learner's categorical
atomic payload in new policies. RESPONSE is one of :ANALYSE, :REMOVE, :RESTORE,
or :DECOY; :MONITOR is used for GLOBAL and defensive fallback. OPTION is NIL
except for :DECOY while the compatibility decoder remains active. The Python
bridge converts this representation into a concrete CAGE2 action."
  target
  response
  option)

(defparameter *semantic-target-names*
  #(:global :defender :enterprise0 :enterprise1 :enterprise2
    :op-server0 :user0 :user1 :user2 :user3 :user4)
  "Names corresponding to terminal target values 0 through 10.")

(defparameter *semantic-response-types*
  #(:analyse :remove :restore :decoy)
  "Host response types represented by categorical response values 0 through 3.")

(defun decode-register-index (value category-count)
  "Map a finite numeric register VALUE deterministically into a category.
Return NIL when VALUE cannot be decoded safely."
  (handler-case
      (mod (floor (abs value)) category-count)
    (arithmetic-error () nil)
    (type-error () nil)))

(defun make-semantic-action-from-legacy-terminal (target registers)
  "Decode TARGET and final terminal learner REGISTERS into a semantic action.

GLOBAL always means Monitor. Host responses use +RESPONSE-REGISTER+; a Decoy
also uses +DECOY-OPTION-REGISTER+. Invalid register values safely fall back to
Monitor. This path preserves historical numeric-action checkpoints."
  (if (= target +global-target+)
      (make-semantic-action :target target :response :monitor :option nil)
      (let* ((response-index
               (decode-register-index
                (aref registers +response-register+)
                (length *semantic-response-types*)))
             (response
               (and response-index
                    (aref *semantic-response-types* response-index))))
        (cond
          ((null response)
           (make-semantic-action
            :target target :response :monitor :option nil))
          ((eq response :decoy)
           (let ((option
                   (decode-register-index
                    (aref registers +decoy-option-register+)
                    8)))
             (if option
                 (make-semantic-action
                  :target target :response response :option option)
                 (make-semantic-action
                  :target target :response :monitor :option nil))))
          (t
           (make-semantic-action
            :target target :response response :option nil))))))

(defun make-semantic-action-from-factored-terminal (payload registers)
  "Convert categorical PAYLOAD into the current semantic policy result.

TARGET and RESPONSE are explicit genes. The environment bridge resolves DECOY
through the host's ordered option table, so new factored actions do not emit an
option. GLOBAL always maps to Monitor."
  (declare (ignore registers))
  (let ((target (factored-action-primary payload))
        (response-index (factored-action-secondary payload)))
    (cond
      ((= target +global-target+)
       (make-semantic-action :target target :response :monitor :option nil))
      ((not (and (<= 0 response-index)
                 (< response-index (length *semantic-response-types*))))
       (make-semantic-action :target target :response :monitor :option nil))
      (t
       (let ((response (aref *semantic-response-types* response-index)))
         (make-semantic-action
          :target target :response response :option nil))))))

(defun make-semantic-action-from-semantic-36-terminal (payload registers)
  "Decode the explicit Semantic-36 category in PAYLOAD.

The terminal gene supplies only target and response. Decoy availability and
the fixed option order remain controller responsibilities. Malformed indices
fall back defensively to GLOBAL/Monitor."
  (declare (ignore registers))
  (let ((pair (semantic-36-index-pair
               (semantic-36-action-index payload))))
    (if pair
        (make-semantic-action
         :target (first pair)
         :response (aref *semantic-response-types* (second pair))
         :option nil)
        (make-semantic-action
         :target +global-target+ :response :monitor :option nil))))

(defun make-semantic-action-from-terminal (payload registers)
  "Decode a final terminal learner PAYLOAD into a SEMANTIC-ACTION.

Factored payloads use explicit target/response categories. Numeric payloads use
the legacy register decoder so existing checkpoints remain reproducible."
  (typecase payload
    (factored-action
     (make-semantic-action-from-factored-terminal payload registers))
    (semantic-36-action
     (make-semantic-action-from-semantic-36-terminal payload registers))
    (number
     (make-semantic-action-from-legacy-terminal payload registers))
    (otherwise
     (error "Unsupported atomic action payload: ~S" payload))))

(defun semantic-action-category-pair (action)
  "Return ACTION as the bridge-level (target response) category pair.

GLOBAL and defensive Monitor results canonicalize to (0 0). Concrete Decoy
options are deliberately excluded: ranked policies learn host and response,
while the bridge owns ordered option selection and availability state."
  (let* ((target (semantic-action-target action))
         (response (semantic-action-response action))
         (response-index (position response *semantic-response-types*)))
    (if (or (not (integerp target))
            (= target +global-target+)
            (null response-index))
        (list +global-target+ 0)
        (list target response-index))))

(defun atomic-action-primary (payload)
  "Return the compatibility integer represented by atomic PAYLOAD."
  (etypecase payload
    (factored-action (factored-action-primary payload))
    (semantic-36-action
     (let ((pair (semantic-36-index-pair
                  (semantic-36-action-index payload))))
       (if pair (first pair) +global-target+)))
    (number payload)))

(defun serialize-atomic-action-value (payload)
  "Serialize an atomic payload without changing legacy integer syntax."
  (etypecase payload
    (factored-action
     `(:factored-action
       :primary ,(factored-action-primary payload)
       :secondary ,(factored-action-secondary payload)))
    (semantic-36-action
     `(:semantic-36-action
       :version ,+semantic-36-catalogue-version+
       :index ,(semantic-36-action-index payload)))
    (number payload)))

(defun serialized-factored-action-p (data)
  (and (consp data) (eq (first data) :factored-action)))

(defun serialized-semantic-36-action-p (data)
  (and (consp data) (eq (first data) :semantic-36-action)))

(defun deserialize-factored-action (data)
  (make-factored-action
   :primary (getf (rest data) :primary)
   :secondary (getf (rest data) :secondary)))

(defun deserialize-semantic-36-action (data)
  (let ((version (getf (rest data) :version))
        (index (getf (rest data) :index)))
    (unless (eq version +semantic-36-catalogue-version+)
      (error "Unsupported Semantic-36 catalogue version: ~S" version))
    (unless (semantic-36-index-pair index)
      (error "Invalid Semantic-36 action index: ~S" index))
    (make-semantic-36-action :index index)))

(defun serialize-action (action seen)
  `(:type ,(action-type action)
    :action ,(if (eq (action-type action) :atomic)
                 (serialize-atomic-action-value (action-action action))
                 (serialize-team (action-action action) seen))))

(defun deserialize-action (data registry)
  (let ((type (getf data :type))
        (payload (getf data :action)))
    (make-action
     :type type
     :action
     (if (eq type :atomic)
         (cond
           ((serialized-factored-action-p payload)
            (deserialize-factored-action payload))
           ((serialized-semantic-36-action-p payload)
            (deserialize-semantic-36-action payload))
           (t payload))
         (deserialize-team payload registry nil)))))

(defmethod print-object ((act action) stream)
  "Updates the default printer to pretty print actions
   in format either ATOMIC(i) or GOTO TEAM-i."
  (let ((type (action-type act)))
    (ecase type
      (:atomic
       (let ((payload (action-action act)))
         (cond
           ((factored-action-p payload)
            (format stream "ACTION-(~A,~A)"
                    (factored-action-primary payload)
                    (factored-action-secondary payload)))
           ((semantic-36-action-p payload)
            (format stream "ACTION-36-~A"
                    (semantic-36-action-index payload)))
           (t
            (format stream "ACTION-~A" payload)))))
      (:reference
       (format stream "GOTO ~A" (team-id (action-action act)))))))

(defun clone-action (action)
  (let ((new-action (copy-action action)))
    (if (eq (action-type new-action) :reference)
        (add-reference (action-action new-action))
        (cond
          ((factored-action-p (action-action new-action))
           (setf (action-action new-action)
                 (copy-factored-action (action-action new-action))))
          ((semantic-36-action-p (action-action new-action))
           (setf (action-action new-action)
                 (copy-semantic-36-action (action-action new-action))))))
    new-action))
    
