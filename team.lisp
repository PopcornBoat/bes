(in-package :cl-tpg)

(defparameter *team-id-generator* (make-counter))

(defstruct (team (:constructor %make-team))
  (id (format nil "TEAM-~A-~A" (who-am-i) (funcall *team-id-generator*)))
  (references 0) ;; Track how many learners point here.
  (type :root)
  (option-orders (make-default-action-option-orders))
  (learners (loop repeat *init-num-learners*
		  collect (make-learner))))

(defun ensure-team-peer-nominations (team)
  "Give TEAM stable local seats and repair only invalid peer nominations.

Legacy teams have no seats.  Initializing them deterministically makes their
first election reproducible, while later learner additions do not renumber
existing nominations.  A voter never nominates itself."
  (let* ((learners (team-learners team))
         (used (make-hash-table :test #'eql))
         (next-seat
           (loop for learner in learners
                 for seat = (learner-peer-seat learner)
                 when (and (integerp seat) (>= seat 0))
                   maximize seat into maximum
                 finally (return (1+ (or maximum -1))))))
    (dolist (learner learners)
      (let ((seat (learner-peer-seat learner)))
        (if (and (integerp seat) (>= seat 0)
                 (not (gethash seat used)))
            (setf (gethash seat used) t)
            (progn
              (setf (learner-peer-seat learner) next-seat
                    (gethash next-seat used) t)
              (incf next-seat)))))
    (loop for voter in learners
          for index fixnum from 0
          for peers = (loop for offset from 1 below (length learners)
                            collect (nth (mod (+ index offset)
                                              (length learners))
                                         learners))
          do (if (null peers)
                 (setf (learner-peer-nominees voter) nil)
                 (let* ((peer-seats (mapcar #'learner-peer-seat peers))
                        (saved (learner-peer-nominees voter))
                        (first-seat
                          (if (member (first saved) peer-seats :test #'eql)
                              (first saved)
                              (first peer-seats)))
                        (second-seat
                          (if (member (second saved) peer-seats :test #'eql)
                              (second saved)
                              (or (find-if (lambda (seat)
                                             (/= seat first-seat))
                                           peer-seats)
                                  first-seat))))
                   (setf (learner-peer-nominees voter)
                         (list first-seat second-seat)))))
    team))

(defun serialize-team (team &optional (seen (make-hash-table)))
  (let ((id (team-id team)))
    (if (gethash id seen)
	`(:id ,id :type :already-serialized)
	(progn
	  (setf (gethash id seen) t)
	  `(:id ,id
	    :type ,(team-type team)
	    :option-orders
              ,(let ((orders (team-option-orders team)))
                 (and orders
                      (loop for order across orders
                            collect (and order (coerce order 'list)))))
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
			    :option-orders
                              (let ((serialized (getf data :option-orders)))
                                (if serialized
                                    (map 'simple-vector
                                         (lambda (order)
                                           (and order
                                                (coerce order 'simple-vector)))
                                         serialized)
                                    (make-default-action-option-orders)))
			    ;; Avoid creating throwaway random learners. Fresh-process
			    ;; deserialization must not depend on training parameters.
			    :learners nil)))
	     (setf (gethash id registry) new-team)
	     ;; Now fill the learners
	     (setf (team-learners new-team)
		   (mapcar (lambda (l) (deserialize-learner l registry))
			   (getf data :learners)))
	     (ensure-team-peer-nominations new-team))))))

(defun make-team (&rest args)
  "The primary team factory. Ensures every team is globally tracked."
  (let* ((team (apply #'%make-team args))
         (fresh-peers-p
           (and (eq *team-selection-mode* :peer-election)
                (every (lambda (learner)
                         (null (learner-peer-seat learner)))
                       (team-learners team)))))
    (push team *teams*)
    (ensure-team-peer-nominations team)
    (when fresh-peers-p
      (dolist (voter (team-learners team))
        (let ((peers (remove voter (team-learners team) :test #'eq)))
          (when peers
            (let* ((first-peer (random-choice peers))
                   (second-peer (random-choice
                                 (or (remove first-peer peers :test #'eq)
                                     peers))))
              (setf (learner-peer-nominees voter)
                    (list (learner-peer-seat first-peer)
                          (learner-peer-seat second-peer))))))))
    team))

(defun effective-team-option-orders (team)
  "Return the Decoy orders selected by the active 2x2 experiment mode.

Fixed mode ignores serialized team variation and uses the teacher-derived agreement
order. Evolved mode uses the team's policy-owned table, initializing a missing
legacy table from the same agreement defaults."
  (ecase *decoy-order-mode*
    (:fixed
     (action-agreement-decoy-orders-for-backend))
    (:evolved
     (or (team-option-orders team)
         (setf (team-option-orders team)
               (make-default-action-option-orders))))))

(defun team-max-observation-index (team)
  "Return TEAM's largest referenced zero-based observation index, or -1."
  (loop with maximum = -1
        for reachable in (closure team)
        do (dolist (learner (team-learners reachable))
             (loop for instruction across
                     (program-instructions (learner-program learner))
                   do (when (eq (instruction-src1-type instruction) :obs)
                        (setf maximum
                              (max maximum
                                   (truncate
                                    (instruction-src1-val instruction)))))
                      (when (and (= (instruction-arity instruction) 2)
                                 (eq (instruction-src2-type instruction) :obs))
                        (setf maximum
                              (max maximum
                                   (truncate
                                    (instruction-src2-val instruction)))))))
        finally (return maximum)))

(defun ensure-team-observation-compatible (team observation-count)
  "Reject TEAM before execution when it addresses beyond OBSERVATION-COUNT."
  (let ((maximum (team-max-observation-index team)))
    (when (>= maximum observation-count)
      (error
       "Checkpoint references OBS~D but this operation exposes only ~D observations. Select the checkpoint's original observation size or start a fresh run."
       (1+ maximum)
       observation-count)))
  team)

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

(defun bounded-peer-confidence (value)
  "Map an arbitrary register value to finite support in [0,1]."
  (handler-case
      (cond ((not (realp value)) 0.5d0)
            ((>= value 20.0d0) 1.0d0)
            ((<= value -20.0d0) 0.0d0)
            (t (/ 1.0d0 (+ 1.0d0 (exp (- value))))))
    (arithmetic-error () 0.5d0)
    (type-error () 0.5d0)))

(defun learner-nominated-peer-seat (learner registers)
  "Choose one of LEARNER's stable peer seats from its program output."
  (let ((second-p
          (handler-case
              (< (aref registers +peer-nomination-register+) 0.0d0)
            (arithmetic-error () nil)
            (type-error () nil))))
    (if second-p
        (second (learner-peer-nominees learner))
        (first (learner-peer-nominees learner)))))

(defun team-ordered-evaluations (team observation)
  "Execute each learner once and return (LEARNER BID REGISTERS) in policy order.

:BID preserves the historical strict-max winner and stable bid ties.
:PEER-ELECTION counts one non-self nomination per voter, uses bounded support
only to break vote-count ties, then uses stable team-local seats for an exact
tie. A lone learner wins without a vote. Its action can still reference a team."
  (let ((evaluations nil)
        (winner nil)
        (winning-bid nil)
        (register-buffer
          (make-array +num-registers+ :element-type 'double-float)))
    (when (and (eq *team-selection-mode* :peer-election)
               (some (lambda (learner)
                       (or (null (learner-peer-seat learner))
                           (and (rest (team-learners team))
                                (null (learner-peer-nominees learner)))))
                     (team-learners team)))
      (ensure-team-peer-nominations team))
    (dolist (learner (team-learners team))
      (multiple-value-bind (learner-bid registers)
          (bid learner observation register-buffer)
        (let ((entry (list learner learner-bid (copy-seq registers))))
          (push entry evaluations)
          (when (and (eq *team-selection-mode* :bid)
                     (or (null winner) (> learner-bid winning-bid)))
            (setf winner entry winning-bid learner-bid)))))
    (unless evaluations
      (error "Cannot execute empty team ~A." (team-id team)))
    (setf evaluations (nreverse evaluations))
    (ecase *team-selection-mode*
      (:bid
       (cons winner
             (stable-sort
              (remove winner evaluations :test #'eq :count 1)
              #'> :key #'second)))
      (:peer-election
       (let ((by-seat (make-hash-table :test #'eql))
             (votes (make-hash-table :test #'eq))
             (support (make-hash-table :test #'eq)))
         (dolist (entry evaluations)
           (setf (gethash (learner-peer-seat (first entry)) by-seat)
                 (first entry)))
         (dolist (entry evaluations)
           (let* ((voter (first entry))
                  (seat (learner-nominated-peer-seat voter (third entry)))
                  (candidate (gethash seat by-seat)))
             (when (and candidate (not (eq candidate voter)))
               (incf (gethash candidate votes 0))
               (incf (gethash candidate support 0.0d0)
                     (bounded-peer-confidence
                      (aref (third entry)
                            +peer-confidence-register+))))))
         (stable-sort
          evaluations
          (lambda (left right)
            (let* ((left-learner (first left))
                   (right-learner (first right))
                   (left-votes (gethash left-learner votes 0))
                   (right-votes (gethash right-learner votes 0))
                   (left-support (gethash left-learner support 0.0d0))
                   (right-support (gethash right-learner support 0.0d0)))
              (or (> left-votes right-votes)
                  (and (= left-votes right-votes)
                       (or (> left-support right-support)
                           (and (= left-support right-support)
                                (< (learner-peer-seat left-learner)
                                   (learner-peer-seat right-learner))))))))))))))

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
             (when (eq *team-selection-mode* :peer-election)
               (let* ((entry
                        (first (team-ordered-evaluations
                                current observation)))
                      (winner (first entry))
                      (registers (third entry))
                      (act (learner-action winner)))
                 (return-from traverse
                   (if (eq (action-type act) :atomic)
                       (values winner registers)
                       (traverse (action-action act)
                                 (cons current visited)
                                 (1+ depth))))))
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

New policies carry categorical target and response genes; the Python bridge
resolves DECOY using its agreement-ordered table. Legacy numeric checkpoints
retain their final-terminal-register response and option behavior. Intermediate
team-reference winners never contribute registers."
  (multiple-value-bind (terminal-learner registers)
      (execute-team-to-terminal team observation)
    (make-semantic-action-from-terminal
     (action-action (learner-action terminal-learner))
     registers)))

(defun execute-team-semantic-ranked
       (team observation &optional (limit +semantic-ranking-limit+))
  "Return up to LIMIT unique semantic candidates in hierarchical selection order.

The first result follows exactly the existing winner-at-each-team traversal.
Alternatives are explored depth-first in the active local selection order. Every
candidate is decoded from its own terminal learner and saved register state;
registers from team-reference learners are never reused. Team evaluations are
cached for this call so shared subgraphs do not execute their programs twice."
  (unless (and (integerp limit) (> limit 0))
    (error "Semantic ranking limit must be positive, got ~S." limit))
  (let ((evaluation-cache (make-hash-table :test #'eq))
        (seen-actions (make-hash-table :test #'equal))
        (preferred-path nil)
        (preferred-terminal-team nil)
        (results nil))
    (labels
        ((evaluate-team (current)
           (or (gethash current evaluation-cache)
               (setf (gethash current evaluation-cache)
                     (team-ordered-evaluations current observation))))
         (record-terminal (entry)
           (let* ((learner (first entry))
                  (registers (third entry))
                  (semantic
                    (make-semantic-action-from-terminal
                     (action-action (learner-action learner))
                     registers))
                  (key (semantic-action-category-pair semantic)))
             (unless (gethash key seen-actions)
               (setf (gethash key seen-actions) t)
               (push semantic results))))
         (traverse (current visited depth preferred-path-p)
           (cond
             ((>= (length results) limit) nil)
             ((>= depth +max-team-traversal-depth+)
              (when preferred-path-p
                (error "TPG traversal exceeded the ~D-team safety limit."
                       +max-team-traversal-depth+)))
             ((member current visited :test #'eq)
              (when preferred-path-p
                (error "Cycle encountered while executing TPG at team ~A."
                       (team-id current))))
             (t
              (when preferred-path-p
                (push current preferred-path))
              (loop for entry in (evaluate-team current)
                    for local-rank fixnum from 0
                    until (>= (length results) limit)
                    do (let* ((learner (first entry))
                              (act (learner-action learner)))
                         (if (eq (action-type act) :atomic)
                             (progn
                               (when (and preferred-path-p
                                          (zerop local-rank))
                                 (setf preferred-terminal-team current))
                               (record-terminal entry))
                             (traverse (action-action act)
                                       (cons current visited)
                                       (1+ depth)
                                       (and preferred-path-p
                                            (zerop local-rank))))))))))
      (traverse team nil 0 t)
      (values (nreverse results)
              (nreverse preferred-path)
              preferred-terminal-team))))

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
   :option-orders (copy-action-option-orders (team-option-orders team))
   :learners (mapcar #'clone-learner (team-learners team))))

(defun delete-team (team)
  "Removes a team from the population and dereferences all of
   the internal teams it may reference."
  (setf *teams* (delete team *teams* :test #'eq))
  (dolist (learner (team-learners team))
    (let ((action (learner-action learner)))
      (when (eq (action-type action) :reference)
	(delete-reference (action-action action))))))
