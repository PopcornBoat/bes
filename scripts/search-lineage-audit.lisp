(in-package :cl-tpg)

(defun continuous-lineage-export (opponent checkpoint output)
  "Export deterministic graph slots, independent of reallocated runtime IDs."
  (continuous-call
   opponent
   (lambda ()
     (let* ((root (continuous-load checkpoint))
            (indices (make-hash-table :test #'eq))
            (nodes nil))
       (labels ((visit (team)
                  (multiple-value-bind (index present) (gethash team indices)
                    (declare (ignore index))
                    (unless present
                      (setf (gethash team indices) (hash-table-count indices))
                      (push team nodes)
                      (dolist (learner (team-learners team))
                        (when (eq :reference (action-type (learner-action learner)))
                          (visit (action-action (learner-action learner)))))))))
         (visit root))
       (let ((*print-pretty* nil))
         (with-open-file (out output :direction :output :if-exists :error)
           (continuous-row out "node" "slot" "runtime_team" "runtime_learner"
                           "action_kind" "action" "program")
           (dolist (team (nreverse nodes))
             (loop for learner in (team-learners team) for slot from 0
                   for action = (learner-action learner)
                   do (continuous-row
                       out (gethash team indices) slot (team-id team) (learner-id learner)
                       (action-type action)
                       (if (eq :reference (action-type action))
                           (gethash (action-action action) indices)
                           (format nil "~S" (serialize-atomic-action-value (action-action action))))
                       (format nil "~S" (map 'list #'instruction->sexp
                                            (program-instructions (learner-program learner)))))))))))))

