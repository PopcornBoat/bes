(in-package :bes)

(defstruct action
  (type :atomic)
  (action (random *num-actions*)))

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
    
