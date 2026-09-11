(in-package :cl-tpg)

(defstruct factored-action
  "Categorical terminal payload evolved by BES.

PRIMARY identifies the environment target and SECONDARY identifies the response
category. The neutral names keep the TPG core reusable with other environments;
the loaded action agreement assigns their external meanings."
  (primary (random *num-actions*) :type integer)
  (secondary (random +num-semantic-responses+) :type integer))

(defun make-random-atomic-action-value ()
  "Create an atomic payload for the currently configured policy contract."
  (if *factored-actions-enabled*
      (make-factored-action)
      (random *num-actions*)))

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

TARGET and RESPONSE are explicit genes. Until the ordered decoy resolver is
introduced, the final terminal learner's decoy register continues to supply an
option so this incremental commit remains compatible with the current bridge
and offline fitness. GLOBAL always maps to Monitor."
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
         (if (eq response :decoy)
             (let ((option
                     (decode-register-index
                      (aref registers +decoy-option-register+)
                      8)))
               (if option
                   (make-semantic-action
                    :target target :response response :option option)
                   (make-semantic-action
                    :target target :response :monitor :option nil)))
             (make-semantic-action
              :target target :response response :option nil)))))))

(defun make-semantic-action-from-terminal (payload registers)
  "Decode a final terminal learner PAYLOAD into a SEMANTIC-ACTION.

Factored payloads use explicit target/response categories. Numeric payloads use
the legacy register decoder so existing checkpoints remain reproducible."
  (typecase payload
    (factored-action
     (make-semantic-action-from-factored-terminal payload registers))
    (number
     (make-semantic-action-from-legacy-terminal payload registers))
    (otherwise
     (error "Unsupported atomic action payload: ~S" payload))))

(defun atomic-action-primary (payload)
  "Return the compatibility integer represented by atomic PAYLOAD."
  (etypecase payload
    (factored-action (factored-action-primary payload))
    (number payload)))

(defun serialize-atomic-action-value (payload)
  "Serialize an atomic payload without changing legacy integer syntax."
  (etypecase payload
    (factored-action
     `(:factored-action
       :primary ,(factored-action-primary payload)
       :secondary ,(factored-action-secondary payload)))
    (number payload)))

(defun serialized-factored-action-p (data)
  (and (consp data) (eq (first data) :factored-action)))

(defun deserialize-factored-action (data)
  (make-factored-action
   :primary (getf (rest data) :primary)
   :secondary (getf (rest data) :secondary)))

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
         (if (serialized-factored-action-p payload)
             (deserialize-factored-action payload)
             payload)
         (deserialize-team payload registry nil)))))

(defmethod print-object ((act action) stream)
  "Updates the default printer to pretty print actions
   in format either ATOMIC(i) or GOTO TEAM-i."
  (let ((type (action-type act)))
    (ecase type
      (:atomic
       (let ((payload (action-action act)))
         (if (factored-action-p payload)
             (format stream "ACTION-(~A,~A)"
                     (factored-action-primary payload)
                     (factored-action-secondary payload))
             (format stream "ACTION-~A" payload))))
      (:reference
       (format stream "GOTO ~A" (team-id (action-action act)))))))

(defun clone-action (action)
  (let ((new-action (copy-action action)))
    (if (eq (action-type new-action) :reference)
        (add-reference (action-action new-action))
        (when (factored-action-p (action-action new-action))
          (setf (action-action new-action)
                (copy-factored-action (action-action new-action)))))
    new-action))
    
