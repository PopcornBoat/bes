(in-package :cl-tpg)

(defstruct action
  (type :atomic)
  (action (random *num-actions*)))

(defstruct semantic-action
  "Structured BES policy output for the hierarchical CAGE2 action space.

TARGET is the terminal learner's atomic target integer. RESPONSE is one of
:MONITOR, :ANALYSE, :REMOVE, :RESTORE, or :DECOY. OPTION is NIL except for
:DECOY, where it is an integer from 0 through 7. The Python bridge is
responsible for converting this representation into a concrete CAGE2 action."
  target
  response
  option)

(defparameter *semantic-target-names*
  #(:global :defender :enterprise0 :enterprise1 :enterprise2
    :op-server0 :user0 :user1 :user2 :user3 :user4)
  "Names corresponding to terminal target values 0 through 10.")

(defparameter *semantic-response-types*
  #(:analyse :remove :restore :decoy)
  "Host response types decoded from the final terminal learner's registers.")

(defun decode-register-index (value category-count)
  "Map a finite numeric register VALUE deterministically into a category.
Return NIL when VALUE cannot be decoded safely."
  (handler-case
      (mod (floor (abs value)) category-count)
    (arithmetic-error () nil)
    (type-error () nil)))

(defun make-semantic-action-from-terminal (target registers)
  "Decode TARGET and final terminal learner REGISTERS into a semantic action.

GLOBAL always means Monitor. Host responses use +RESPONSE-REGISTER+; a Decoy
also uses +DECOY-OPTION-REGISTER+. Invalid register values safely fall back to
Monitor. Atomic terminal actions represent targets, not complete CAGE2 actions."
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

(defun serialize-action (action seen)
  `(:type ,(action-type action)
    :action ,(let ((action (action-action action)))
	      (etypecase action
		(number action)
		(team (serialize-team action seen))))))

(defun deserialize-action (data registry)
  (make-action :type (getf data :type)
	       :action (let ((action (getf data :action)))
			 (typecase action
			   (number action)
			   (otherwise (deserialize-team action registry nil))))))

(defmethod print-object ((act action) stream)
  "Updates the default printer to pretty print actions
   in format either ATOMIC(i) or GOTO TEAM-i."
  (let ((type (action-type act)))
    (ecase type
      (:atomic
       (format stream "ACTION-~A" (action-action act)))
      (:reference
       (format stream "GOTO ~A" (team-id (action-action act)))))))

(defun clone-action (action)
  (let ((new-action (copy-action action)))
    (when (eq (action-type new-action) :reference)
      ;; We don't copy the target team.
      ;; We just tell the target team: "Hey, another arrow is pointing at you now."
      (add-reference (action-action new-action)))
    new-action))
    
