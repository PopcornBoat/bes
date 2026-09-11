(in-package :cl-tpg)

(defparameter *team-id-generator* (make-counter))

(defstruct (team (:constructor %make-team))
  (id (format nil "TEAM-~A-~A" (who-am-i) (funcall *team-id-generator*)))
  (references 0) ;; Track how many learners point here.
  (type :root)
  (learners (loop repeat *init-num-learners*
		  collect (make-learner))))

(defun serialize-team (team &optional (seen (make-hash-table)))
  (let ((id (team-id team)))
    (if (gethash id seen)
	`(:id ,id :type :already-serialized)
	(progn
	  (setf (gethash id seen) t)
	  `(:id ,id
	    :type ,(team-type team)
	    :learners ,(mapcar (lambda (l) (serialize-learner l seen))
			       (team-learners team)))))))

(defun deserialize-team (data registry &optional (is-root t))
  (let* ((id (getf data :id))
	 (existing-team (gethash id registry)))
    (cond (existing-team
	   ;; Scenario: We've seen this team before (e.g., via a different path)
	   (incf (team-references existing-team))
	   existing-team)
	  (t
	   ;; Scenario: First time seeing this team
	   (let ((new-team (%make-team
			    :id (format nil "TEAM-~A-~A" (who-am-i) (funcall *team-id-generator*))
			    :type (getf data :type)
			    :references (if is-root 0 1)
			    ;; Avoid creating throwaway random learners. Fresh-process
			    ;; deserialization must not depend on training parameters.
			    :learners nil)))
	     (setf (gethash id registry) new-team)
	     ;; Now fill the learners
	     (setf (team-learners new-team)
		   (mapcar (lambda (l) (deserialize-learner l registry))
			   (getf data :learners)))
	     new-team)))))

(defun make-team (&rest args)
  "The primary team factory. Ensures every team is globally tracked."
  (let ((team (apply #'%make-team args)))
    (push team *teams*)
    team))

(defun add-reference (target-team)
  "Call this when a learner points to a team."
  (incf (team-references target-team))
  (setf (team-type target-team) :internal))

(defun delete-reference (target-team)
  "Call this when a learner is removed or mutated away from this team."
  (decf (team-references target-team))
  (when (<= (team-references target-team) 0)
    (setf (team-references target-team) 0)
    (setf (team-type target-team) :root)))

(defun execute-team-to-terminal (team observation)
  "Traverse TEAM and return the terminal winner and its registers.

Every learner program executes once per visited team and bids through register
0 as before. A winning team-reference action recursively continues traversal.
Only the learner that finally wins with an atomic target contributes registers
to the semantic policy output; intermediate winners' registers are discarded."
  (labels ((traverse (current visited depth)
             (when (>= depth +max-team-traversal-depth+)
               (error "TPG traversal exceeded the ~D-team safety limit."
                      +max-team-traversal-depth+))
             (when (member current visited :test #'eq)
               (error "Cycle encountered while executing TPG at team ~A."
                      (team-id current)))
             (let ((winner nil)
                   (winning-bid nil)
                   (winning-registers
                     (make-array +num-registers+
                                 :element-type 'double-float))
                   (register-buffer
                     (make-array +num-registers+
                                 :element-type 'double-float)))
               ;; Retain only the current winner instead of allocating an
               ;; evaluation triple and list for every learner on every row.
               (dolist (learner (team-learners current))
                 (multiple-value-bind (learner-bid registers)
                     (bid learner observation register-buffer)
                   (when (or (null winner)
                             (> learner-bid winning-bid))
                     (setf winner learner
                           winning-bid learner-bid)
                     (replace winning-registers registers))))
               (unless winner
                 (error "Cannot execute empty team ~A." (team-id current)))
               (let ((act (learner-action winner)))
                 (if (eq (action-type act) :atomic)
                     (values winner winning-registers)
                     (traverse (action-action act)
                               (cons current visited)
                               (1+ depth)))))))
    (traverse team nil 0)))

(defun execute-team (team observation)
  "Execute TEAM and return the final terminal learner's atomic target.

This compatibility API retains the former integer return shape. Atomic values
now represent targets when the factored action contract is enabled."
  (multiple-value-bind (terminal-learner registers)
      (execute-team-to-terminal team observation)
    (declare (ignore registers))
    (atomic-action-primary
     (action-action (learner-action terminal-learner)))))

(defun execute-team-semantic (team observation)
  "Execute TEAM and return a SEMANTIC-ACTION from the final terminal learner.

New policies carry categorical target and response genes. Legacy numeric
checkpoints retain their register-decoded response behavior. Only registers
from the final terminal learner can contribute a transitional decoy option;
intermediate team-reference winners are never used. The Python bridge converts
the semantic result into a concrete environment action."
  (multiple-value-bind (terminal-learner registers)
      (execute-team-to-terminal team observation)
    (make-semantic-action-from-terminal
     (action-action (learner-action terminal-learner))
     registers)))

(defun execute-team-on-dataset (team dataset)
  "Batch executes a team across all the observations in DATASET."
  (map 'list (lambda (obs) (execute-team team obs)) (observations dataset)))

(defmethod print-object ((tm team) stream)
  "Updates the default printer to pretty print teams by showing
   whether they are root/internal and by enumerating their
   learner IDs, actions."
  (flet ((format-learner (learner)
	   (let ((id (learner-id learner))
		 (action (learner-action learner)))
	   (format nil "~A: ~A" id action))))
    (print-unreadable-object (tm stream :type nil :identity nil)
      (format stream "~A-TEAM ~A~%~{~A~%~}"
	      (team-type tm)
	      (team-id tm)
	      (mapcar #'format-learner (team-learners tm))))))

(defun closure (team)
  "Returns a list of all teams reachable from TEAM (including itself)."
  (let ((visited (make-hash-table :test 'eq)))
    (labels ((traverse (current)
	       (unless (gethash current visited)
		 (setf (gethash current visited) t)
		 (dolist (learner (team-learners current))
		   (let ((act (learner-action learner)))
		     (when (eq (action-type act) :reference)
		       (traverse (action-action act))))))))
      (traverse team))
    (alexandria:hash-table-keys visited)))

(defun teams-complexity (teams)
  "Return team, learner, instruction, max-team, and max-program counts."
  (let ((team-count 0)
        (learner-count 0)
        (instruction-count 0)
        (max-team-size 0)
        (max-program-size 0))
    (dolist (team teams)
      (let ((team-size (length (team-learners team))))
        (incf team-count)
        (incf learner-count team-size)
        (setf max-team-size (max max-team-size team-size))
        (dolist (learner (team-learners team))
          (let ((program-size
                  (length
                   (program-instructions (learner-program learner)))))
            (incf instruction-count program-size)
            (setf max-program-size
                  (max max-program-size program-size))))))
    (values team-count learner-count instruction-count
            max-team-size max-program-size)))

(defun team-complexity (team)
  "Return complexity counts for the graph reachable from TEAM."
  (teams-complexity (closure team)))

(defun policy-complexity-key (team)
  "Return a lexicographic parsimony key for TEAM's reachable graph."
  (multiple-value-bind
        (teams learners instructions max-team max-program)
      (team-complexity team)
    (declare (ignore max-team max-program))
    (list instructions learners teams)))

(defun emit-policy-limit-warning (team)
  "Warn when a loaded policy already exceeds the configured hard limits."
  (multiple-value-bind
        (teams learners instructions max-team max-program)
      (team-complexity team)
    (when (or (> max-team *max-num-learners*)
              (> max-program *max-program-size*))
      (emit-message
       (format nil
               "Warm-start policy exceeds configured limits: teams=~D learners=~D instructions=~D max-team=~D/~D max-program=~D/~D. Existing structure is preserved, but future additions obey the limits."
               teams learners instructions
               max-team *max-num-learners*
               max-program *max-program-size*)))))

(defun creates-cycle-p (current-team target-team)
  "Returns T if the target-team has a path back to current-team."
  (member current-team (closure target-team) :test #'eq))

(defun root-teams ()
  "Returns all teams that are candidate solutions."
  (remove-if-not (lambda (team)
		   (eq (team-type team) :root))
		 *teams*))

(defun clone-team (team)
  "Deep copy a team."
  (make-team
   :type (team-type team)
   :learners (mapcar #'clone-learner (team-learners team))))

(defun delete-team (team)
  "Removes a team from the population and dereferences all of
   the internal teams it may reference."
  (setf *teams* (delete team *teams* :test #'eq))
  (dolist (learner (team-learners team))
    (let ((action (learner-action learner)))
      (when (eq (action-type action) :reference)
	(delete-reference (action-action action))))))
