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
  "Return the first register after executing the learner's program.
   The first register indicates how confident the learner is in its action."
  (let ((program (learner-program learner)))
    (aref (execute-program program observations) 0)))

(defun clone-learner (learner)
  "Deep copy a learner."
  (make-learner
   :program (clone-program (learner-program learner))
   :action (clone-action (learner-action learner))))
