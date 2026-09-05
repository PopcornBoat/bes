(in-package :cl-tpg)

(defparameter *learner-id-generator* (make-counter))

(defstruct learner
  (id (format nil "LEARNER-~A-~A" (who-am-i) (funcall *learner-id-generator*)))
  (program (make-program))
  (action (make-action)))

(defun serialize-learner (learner seen)
  `(:id ,(learner-id learner)
    :program ,(serialize-program (learner-program learner))
    :action ,(serialize-action (learner-action learner) seen)))

(defun deserialize-learner (data registry)
  (make-learner :id (format nil "LEARNER-~A-~A" (who-am-i) (funcall *learner-id-generator*))
		:program (deserialize-program (getf data :program))
		:action (deserialize-action (getf data :action) registry)))

(defun bid (learner observations)
  "Execute LEARNER and return its bid and register array as two values.

+BID-REGISTER+ remains the confidence bid. The second value lets traversal
preserve the final terminal winner's registers without executing it twice;
existing callers that consume only the primary bid value remain compatible."
  (let ((registers
          (execute-program (learner-program learner) observations)))
    (values (aref registers +bid-register+) registers)))

(defun clone-learner (learner)
  "Deep copy a learner."
  (make-learner
   :program (clone-program (learner-program learner))
   :action (clone-action (learner-action learner))))
