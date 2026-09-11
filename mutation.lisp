					; program mutations

(in-package :cl-tpg)

(defun soft-growth-probability (base-probability current-size soft-size)
  "Reduce growth pressure smoothly above SOFT-SIZE without forbidding growth.

The inverse-square taper keeps every size below the hard limit reachable, but
causes additions and deletions to approach neutral expected drift rather than
allowing permanent positive bloat pressure."
  (if (<= current-size soft-size)
      base-probability
      (* base-probability
         (expt (/ (coerce soft-size 'double-float)
                  (coerce current-size 'double-float))
               2))))

(defun add-instruction-p (current-size)
  "Return true using soft-limited instruction-addition pressure."
  (coin-flip
   (soft-growth-probability
    *p-add-instr* current-size *soft-program-size*)))

(defun delete-instruction-p ()
  "Returns T with *p-del* likelihood."
  (coin-flip *p-del-instr*))

(defun swap-instructions-p ()
  "Returns T with *p-swap* likelihood."
  (coin-flip *p-swap-instrs*))

(defun mutate-constant-p ()
  "Returns T with *p-mut-constant* likelihood."
  (coin-flip *p-mut-constant*))

(defun mutate-constant-sign-p ()
  "Returns T with *p-mut-constant-sign* likelihood."
  (coin-flip *p-mut-constant-sign*))

(defun mutate-program-p ()
  "Returns T with *p-mut* likelihood."
  (coin-flip *p-mut*))

(defun add-instruction (program)
  "Adds a new instruction to a program at a random position."
  (let* ((instructions (program-instructions program))
	 (num-instructions (length instructions))
	 (i (random (1+ num-instructions))))
    (when (< num-instructions *max-program-size*)
      (vector-push-extend nil instructions)
      (loop for j downfrom num-instructions above i
	    do (setf (aref instructions j) (aref instructions (1- j))))
      (setf (aref instructions i) (make-instruction)))
    program))

(defun delete-instruction (program)
  "Remove a random instruction from a program."
  (let* ((instructions (program-instructions program))
	 (num-instructions (length instructions)))
    (when (> num-instructions 1)
      (let ((i (random num-instructions)))
	(loop for j from i below (1- num-instructions)
	      do (setf (aref instructions j) (aref instructions (1+ j))))
	(vector-pop instructions)))
    program))

(defun swap-instructions (program)
  "Swap two random instructions in a program."
  (let* ((instructions (program-instructions program))
	 (num-instructions (length instructions)))
    (when (> num-instructions 1)
      (let ((i (random num-instructions))
	    (j (random num-instructions)))
	(rotatef (aref instructions i)
		 (aref instructions j))))
    program))

(defun mutate-constant (program)
  "Mutate a random constant in a program."
  (flet ((add-noise (c)
	   (let* ((u1 (max 1e-12 (random 1.0)))
		  (u2 (random 1.0))
		  (z (* (sqrt (* -2.0 (log u1)))
			(cos (* 2.0 pi u2)))))
	     (+ c (* 0.1 z)))))
    (let* ((instructions (program-instructions program))
	   (instructions-with-constants
	     (remove-if-not #'instruction-has-constant-p instructions)))
	;; REMOVE-IF-NOT preserves the vector type.  An empty result is therefore
	;; #(), which is true in Common Lisp, rather than NIL.  Test its length so
	;; unary/observation-only programs do not call RANDOM-CHOICE on #().
      (when (plusp (length instructions-with-constants))
	(let* ((instr (random-choice instructions-with-constants))
	       (slots (remove nil
			      (list (when (eq (instruction-src1-type instr) :const)
				      :src1)
				    (when (eq (instruction-src2-type instr) :const)
				      :src2)))))
	  (case (random-choice slots)
	    (:src1
	     (setf (instruction-src1-val instr)
		   (add-noise (instruction-src1-val instr)))
	     (when (mutate-constant-sign-p)
	       (setf (instruction-src1-val instr)
		     (- (instruction-src1-val instr)))))

	    (:src2
	     (setf (instruction-src2-val instr)
		   (add-noise (instruction-src2-val instr)))
	     (when (mutate-constant-sign-p)
	       (setf (instruction-src2-val instr)
		     (- (instruction-src2-val instr))))))))

      program)))

(defun mutate-program (program)
  "Mutate a program by adding/deleting/swapping instructions
   or mutating constants with likelihood *p-mut*."
  (when (mutate-program-p)
    (when (add-instruction-p
           (length (program-instructions program)))
      (add-instruction program))
    (when (delete-instruction-p)
      (delete-instruction program))
    (when (swap-instructions-p)
      (swap-instructions program))
    (when (mutate-constant-p)
      (mutate-constant program)))
  program)
  					; team mutations

(defun add-learner-p (current-size)
  "Return true using soft-limited learner-addition pressure."
  (coin-flip
   (soft-growth-probability
    *p-add* current-size *soft-num-learners*)))

(defun delete-learner-p ()
  "Returns T with likelihood *p-del*."
  (coin-flip *p-del*))

(defun mutate-action-p ()
  "Returns T with likelihood *p-act*."
  (coin-flip *p-act*))

(defun mutate-learner-p ()
  "Returns T with likelihood *p-mut*."
  (coin-flip *p-mut*))

(defun swap-learners-p ()
  "Returns T with likelihood *p-swap*."
  (coin-flip *p-swap*))

(defun add-learner (team)
  "Add a new learner to a team."
  (when (< (length (team-learners team)) *max-num-learners*)
    (push (make-learner) (team-learners team)))
  team)

(defun delete-learner (team)
  "Delete a random learner from a team."
  (let* ((learners (team-learners team))
	 (num-learners (length learners))
	 (idx (random num-learners))
	 (learner (nth idx learners)))
    (when (> num-learners 1)
      (when (eq (action-type (learner-action learner)) :reference)
	(delete-reference (action-action (learner-action learner))))
      (setf (team-learners team) (delete learner learners :count 1 :test #'eq))))
  team)

(defun swap-learners (team)
  "Swap the actions of two random learners on a team."
  (let* ((learners (team-learners team))
	 (num-learners (length learners)))
    (when (> num-learners 1)
      (let* ((learner-1 (random-choice learners))
	     (learner-1-action (learner-action learner-1))
	     (learner-2 (random-choice (remove learner-1 learners :test #'eq)))
	     (learner-2-action (learner-action learner-2)))
	(setf (learner-action learner-1) learner-2-action)
	(setf (learner-action learner-2) learner-1-action))))
  team)

(defun random-different-category (current category-count)
  "Return a category distinct from CURRENT when CATEGORY-COUNT permits it."
  (if (<= category-count 1)
      current
      (let ((candidate (random (1- category-count))))
        (if (>= candidate current) (1+ candidate) candidate))))

(defun mutate-factored-atomic-value (payload)
  "Copy PAYLOAD and mutate exactly one categorical policy component."
  (let ((mutated (copy-factored-action payload)))
    (if (zerop (random 2))
        (setf (factored-action-primary mutated)
              (random-different-category
               (factored-action-primary mutated) *num-actions*))
        (setf (factored-action-secondary mutated)
              (random-different-category
               (factored-action-secondary mutated)
               +num-semantic-responses+)))
    mutated))

(defun mutated-atomic-action-value (old-payload)
  "Return an atomic payload appropriate for the active action contract."
  (cond
    ((not *factored-actions-enabled*)
     (random *num-actions*))
    ((factored-action-p old-payload)
     (mutate-factored-atomic-value old-payload))
    (t
     ;; A legacy numeric checkpoint entering factored training is upgraded the
     ;; first time this learner's action mutates.
     (make-random-atomic-action-value))))

(defun mutate-action (team)
  "Choose a random learner on a team and change its action.
   Its new action might be a new atomic action or a reference
   to a team."
  (let* ((learners (team-learners team))
	 (learner (random-choice learners))
	 (action (learner-action learner))
	 (new-type (random-choice '(:atomic :reference))))
    ;; if the old action was a reference, we decrement the target's count.
    (when (eq (action-type action) :reference)
      (delete-reference (action-action action)))
    (case new-type
      (:atomic
       (let ((old-payload (and (eq (action-type action) :atomic)
                               (action-action action))))
	 (setf (action-type action) :atomic
               (action-action action)
               (mutated-atomic-action-value old-payload))))
      (:reference
       (let ((target (random-choice (remove team *teams* :test #'equal))))
	 (if (creates-cycle-p team target)
	     ;; Cycle detected, fallback to an atomic action.
	     (progn
	       (setf (action-type action) :atomic)
	       (setf (action-action action)
                     (make-random-atomic-action-value)))
	     (progn
	       (setf (action-type action) :reference)
	       (setf (action-action action) target)
	       (add-reference target)))))))
  team)

(defun mutate-learner (team)
  "Mutate the learner by mutating its program."
  (let* ((learners (team-learners team))
	 (learner (random-choice learners)))
    (mutate-program (learner-program learner))))

(defun mutate-team (team)
  "Mutate a team by swapping the actions of two randomly chosen learners,
   or by adding learners, by removing learners, changing learners' actions
   or by mutating the learners' programs."
  (when (add-learner-p (length (team-learners team)))
    (add-learner team))
  (when (delete-learner-p)
    (delete-learner team))
  (when (mutate-learner-p)
    (mutate-learner team))
  (when (mutate-action-p)
    (mutate-action team))
  (when (swap-learners-p)
    (swap-learners team))
  team)
