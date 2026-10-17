(in-package :cl-tpg)

(defparameter *learner-id-generator* (make-counter))

(defstruct learner
  (id (format nil "LEARNER-~A-~A" (who-am-i) (funcall *learner-id-generator*)))
  (program (make-program))
  (action (make-action))
  ;; Seats are stable only within one team.  They survive cloning and
  ;; serialization so adding/removing a peer does not renumber every vote.
  (peer-seat nil)
  (peer-nominees nil))

(defun serialize-learner (learner seen)
  `(:id ,(learner-id learner)
    :program ,(serialize-program (learner-program learner))
    :action ,(serialize-action (learner-action learner) seen)
    :peer-seat ,(learner-peer-seat learner)
    :peer-nominees ,(copy-list (learner-peer-nominees learner))))

(defun deserialize-learner (data registry)
  (make-learner :id (format nil "LEARNER-~A-~A" (who-am-i) (funcall *learner-id-generator*))
		:program (deserialize-program (getf data :program))
		:action (deserialize-action (getf data :action) registry)
                :peer-seat (getf data :peer-seat)
                :peer-nominees (copy-list (getf data :peer-nominees))))

(defun make-zeroed-register-vector ()
  "Allocate one program register vector initialized to zero."
  (make-array +num-registers+
              :element-type 'double-float
              :initial-element 0.0d0))

(defun call-with-fresh-policy-episode (function)
  "Call FUNCTION with a fresh recurrent register bank for one episode.

The binding is active only when recurrent policy execution is enabled. Each
learner receives an independent vector, so bidding learners cannot leak state
into one another. Dropping this dynamic binding at episode exit resets every
learner without mutating or serializing the graph."
  (let ((*policy-episode-registers*
          (and *recurrent-policy-enabled*
               (make-hash-table :test #'eq))))
    (funcall function)))

(defun recurrent-learner-registers (learner)
  "Return LEARNER's register vector in the active episode, or NIL."
  (when *policy-episode-registers*
    (or (gethash learner *policy-episode-registers*)
        (setf (gethash learner *policy-episode-registers*)
              (make-zeroed-register-vector)))))

(defun bid (learner observations &optional register-buffer)
  "Execute LEARNER and return its bid and register array as two values.

+BID-REGISTER+ remains the historical bid, though peer election selects using
registers 1 and 2 instead. The second value lets traversal
preserve the final terminal winner's registers without executing it twice;
existing callers that consume only the primary bid value remain compatible."
  (let* ((recurrent-registers
           (recurrent-learner-registers learner))
         (registers
           (execute-program
            (learner-program learner)
            observations
            (or recurrent-registers register-buffer)
            (null recurrent-registers))))
    (values (aref registers +bid-register+) registers)))

(defun clone-learner (learner)
  "Deep copy a learner."
  (make-learner
   :program (clone-program (learner-program learner))
   :action (clone-action (learner-action learner))
   :peer-seat (learner-peer-seat learner)
   :peer-nominees (copy-list (learner-peer-nominees learner))))
