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

(defun perturbed-constant-value (value)
  "Return VALUE plus bounded Gaussian mutation noise and optional sign flip."
  (let* ((u1 (max 1.0d-12 (random 1.0d0)))
         (u2 (random 1.0d0))
         (z (* (sqrt (* -2.0d0 (log u1)))
               (cos (* 2.0d0 pi u2))))
         (result (+ (coerce value 'double-float) (* 0.1d0 z))))
    (if (mutate-constant-sign-p) (- result) result)))

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
		   (perturbed-constant-value
                    (instruction-src1-val instr))))

	    (:src2
	     (setf (instruction-src2-val instr)
		   (perturbed-constant-value
                    (instruction-src2-val instr)))))))

      program))

(defun instruction-source-slots (instruction)
  "Return the source slots that participate in INSTRUCTION execution."
  (if (= (instruction-arity instruction) 1)
      '(:src1)
      '(:src1 :src2)))

(defun instruction-source-type-at (instruction slot)
  (ecase slot
    (:src1 (instruction-src1-type instruction))
    (:src2 (instruction-src2-type instruction))))

(defun instruction-source-value-at (instruction slot)
  (ecase slot
    (:src1 (instruction-src1-val instruction))
    (:src2 (instruction-src2-val instruction))))

(defun set-instruction-source (instruction slot type value)
  "Set one source SLOT to a validated TYPE and double-float VALUE."
  (let ((value (coerce value 'double-float)))
    (ecase slot
      (:src1
       (setf (instruction-src1-type instruction) type
             (instruction-src1-val instruction) value))
      (:src2
       (setf (instruction-src2-type instruction) type
             (instruction-src2-val instruction) value))))
  instruction)

(defun random-source-value (type)
  "Return a valid encoded value for one instruction source TYPE."
  (ecase type
    (:reg (coerce (random +num-registers+) 'double-float))
    (:obs (coerce (random *num-observations*) 'double-float))
    (:const (coerce (random-constant) 'double-float))))

(defun random-different-integer (current count)
  "Return an integer below COUNT distinct from CURRENT when possible."
  (if (<= count 1)
      current
      (let ((candidate (random (1- count))))
        (if (>= candidate current) (1+ candidate) candidate))))

(defun field-local-instruction-index (program)
  "Choose one program index, preferring the current R0 backward slice."
  (let* ((instructions (program-instructions program))
         (count (length instructions)))
    (when (plusp count)
      (if (and *effective-aware-mutation-enabled*
               (coin-flip *effective-instruction-selection-probability*))
          (let ((effective
                  (getf (analyze-program-effective-code program)
                        :effective-indices)))
            (if effective
                (random-choice effective)
                (random count)))
          (random count)))))

(defun mutate-instruction-opcode (instruction)
  "Change INSTRUCTION's opcode within the active creation profile."
  (let* ((old-op (instruction-op instruction))
         (choices (remove old-op (active-instruction-opcodes) :test #'eq)))
    (when choices
      (let* ((new-op (random-choice choices))
             (old-arity (instruction-arity instruction))
             (new-arity (opcode-arity new-op)))
        (setf (instruction-op instruction) new-op
              (instruction-arity instruction) new-arity)
        (cond
          ((and (= old-arity 1) (= new-arity 2))
           (multiple-value-bind (type value)
               (decode-symbol (random-argument-or-constant))
             (set-instruction-source instruction :src2 type value)))
          ((= new-arity 1)
           (set-instruction-source instruction :src2 :const 0.0d0)))
        t))))

(defun mutate-instruction-destination (instruction)
  "Change INSTRUCTION's destination register."
  (let ((old (instruction-dest instruction)))
    (setf (instruction-dest instruction)
          (random-different-integer old +num-registers+))
    (/= old (instruction-dest instruction))))

(defun mutate-instruction-source-type (instruction)
  "Change one source between register, observation, and constant addressing."
  (let* ((slot (random-choice (instruction-source-slots instruction)))
         (old-type (instruction-source-type-at instruction slot))
         (new-type
           (random-choice (remove old-type '(:reg :obs :const) :test #'eq))))
    (set-instruction-source
     instruction slot new-type (random-source-value new-type))
    t))

(defun mutate-instruction-source-index (instruction)
  "Change one register/observation source index without changing its type."
  (let ((slots
          (remove-if-not
           (lambda (slot)
             (member (instruction-source-type-at instruction slot)
                     '(:reg :obs) :test #'eq))
           (instruction-source-slots instruction))))
    (when slots
      (let* ((slot (random-choice slots))
             (type (instruction-source-type-at instruction slot))
             (old (truncate (instruction-source-value-at instruction slot)))
             (count (if (eq type :reg)
                        +num-registers+
                        *num-observations*)))
        (set-instruction-source
         instruction slot type (random-different-integer old count))
        (/= old (truncate (instruction-source-value-at instruction slot)))))))

(defun mutate-instruction-constant (instruction)
  "Perturb one constant source in INSTRUCTION when one exists."
  (let ((slots
          (remove-if-not
           (lambda (slot)
             (eq (instruction-source-type-at instruction slot) :const))
           (instruction-source-slots instruction))))
    (when slots
      (let* ((slot (random-choice slots))
             (old (instruction-source-value-at instruction slot)))
        (set-instruction-source
         instruction slot :const (perturbed-constant-value old))
        (/= old (instruction-source-value-at instruction slot))))))

(defun field-local-mutation-kinds (instruction)
  "Return field-level edits currently applicable to INSTRUCTION."
  (let ((kinds '(:opcode :destination :source-type)))
    (when (some (lambda (slot)
                  (member (instruction-source-type-at instruction slot)
                          '(:reg :obs) :test #'eq))
                (instruction-source-slots instruction))
      (push :source-index kinds))
    (when (some (lambda (slot)
                  (eq (instruction-source-type-at instruction slot) :const))
                (instruction-source-slots instruction))
      (push :constant kinds))
    kinds))

(defun mutate-program-field-local (program)
  "Apply one local instruction edit or a low-probability full replacement."
  (let* ((instructions (program-instructions program))
         (count (length instructions)))
    (cond
      ((zerop count)
       (vector-push-extend (make-instruction) instructions)
       (note-mutation-event :whole-instruction-replacement))
      (t
       (let ((index (field-local-instruction-index program)))
         (if (coin-flip *whole-instruction-replacement-probability*)
             (progn
               (setf (aref instructions index) (make-instruction))
               (note-mutation-event :whole-instruction-replacement))
             (let* ((instruction (aref instructions index))
                    (kind (random-choice
                           (field-local-mutation-kinds instruction)))
                    (changed-p
                      (ecase kind
                        (:opcode
                         (mutate-instruction-opcode instruction))
                        (:destination
                         (mutate-instruction-destination instruction))
                        (:source-type
                         (mutate-instruction-source-type instruction))
                        (:source-index
                         (mutate-instruction-source-index instruction))
                        (:constant
                         (mutate-instruction-constant instruction)))))
               (when changed-p
                 (note-mutation-event
                  (ecase kind
                    (:opcode :instruction-opcode-mutation)
                    (:destination :instruction-destination-mutation)
                    (:source-type :instruction-source-type-mutation)
                    (:source-index :instruction-source-index-mutation)
                    (:constant :constant-mutation))))))))))
  (note-mutation-event :field-local-instruction-mutation)
  (note-mutation-event :program-mutation)
  program)

(defun mutate-program-legacy (program)
  "Apply the historical independent structural/constant mutation operators."
  (let ((changed-p nil))
    (when (add-instruction-p
           (length (program-instructions program)))
      (let ((before (length (program-instructions program))))
        (add-instruction program)
        (when (> (length (program-instructions program)) before)
          (setf changed-p t)
          (note-mutation-event :instruction-add))))
    (when (delete-instruction-p)
      (let ((before (length (program-instructions program))))
        (delete-instruction program)
        (when (< (length (program-instructions program)) before)
          (setf changed-p t)
          (note-mutation-event :instruction-delete))))
    (when (swap-instructions-p)
      (let ((before (copy-seq (program-instructions program))))
        (swap-instructions program)
        (unless (and (= (length before)
                        (length (program-instructions program)))
                     (loop for prior across before
                           for current across (program-instructions program)
                           always (eq prior current)))
          (setf changed-p t)
          (note-mutation-event :instruction-swap))))
    (when (mutate-constant-p)
      (let ((before (pprint-program program)))
        (mutate-constant program)
        (unless (equal before (pprint-program program))
          (setf changed-p t)
          (note-mutation-event :constant-mutation))))
    (when changed-p
      (note-mutation-event :program-mutation)))
  program)

(defun mutate-program (program)
  "Mutate PROGRAM under the configured instruction-level policy."
  (when (mutate-program-p)
    (ecase *instruction-mutation-mode*
      (:legacy (mutate-program-legacy program))
      (:field-local (mutate-program-field-local program))))
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
    (push (make-learner) (team-learners team))
    (note-mutation-event :learner-add))
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
      (setf (team-learners team) (delete learner learners :count 1 :test #'eq))
      (note-mutation-event :learner-delete)))
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
	(setf (learner-action learner-2) learner-1-action)
        (note-mutation-event :learner-action-swap))))
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
        (progn
          (setf (factored-action-primary mutated)
                (random-different-category
                 (factored-action-primary mutated) *num-actions*))
          (note-mutation-event :terminal-target-mutation))
        (progn
          (setf (factored-action-secondary mutated)
                (random-different-category
                 (factored-action-secondary mutated)
                 +num-semantic-responses+))
          (note-mutation-event :terminal-response-mutation)))
    mutated))

(defun mutate-target-response-36-atomic-value (payload)
  "Copy PAYLOAD and directly mutate exactly one stored semantic field."
  (let ((mutated (copy-target-response-36-action payload)))
    (if (zerop (random 2))
        (let* ((target (target-response-36-action-target mutated))
               (current-position
                 (position target *semantic-36-targets* :test #'=))
               (new-position
                 (random-different-category
                  current-position (length *semantic-36-targets*))))
          (setf (target-response-36-action-target mutated)
                (aref *semantic-36-targets* new-position))
          (note-mutation-event :terminal-target-mutation))
        (progn
          (setf (target-response-36-action-response mutated)
                (random-different-category
                 (target-response-36-action-response mutated)
                 +num-semantic-responses+))
          (note-mutation-event :terminal-response-mutation)))
    mutated))

(defun mutate-flat-36-atomic-value (payload)
  "Copy a flat PAYLOAD and remap one decoded semantic component.

The catalogue order is external compatibility data, so mutation operates on
the decoded semantic pair and then maps the result back to its stable index."
  (let* ((old-pair
           (semantic-36-index-pair (flat-36-action-index payload)))
         (target (and old-pair (first old-pair)))
         (response-index (and old-pair (second old-pair))))
    (unless old-pair
      (return-from mutate-flat-36-atomic-value
        (make-flat-36-action)))
    (if (zerop (random 2))
        (let* ((current-position
                 (position target *semantic-36-targets* :test #'=))
               (new-position
                 (random-different-category
                  current-position (length *semantic-36-targets*))))
          (setf target (aref *semantic-36-targets* new-position))
          (note-mutation-event :terminal-target-mutation))
        (progn
          (setf response-index
                (random-different-category
                 response-index +num-semantic-responses+))
          (note-mutation-event :terminal-response-mutation)))
    (make-flat-36-action
     :index (or (semantic-36-pair-index target response-index)
                (error "Semantic-36 catalogue is missing (~D ~D)."
                       target response-index)))))

(defun mutated-atomic-action-value (old-payload)
  "Return an atomic payload appropriate for the active action contract."
  (cond
    ((not *factored-actions-enabled*)
     (random *num-actions*))
    ((eq *terminal-action-format* :factored)
     (if (factored-action-p old-payload)
         (mutate-factored-atomic-value old-payload)
         (make-factored-action)))
    ((eq *terminal-action-format* :target-response-36)
     (if (target-response-36-action-p old-payload)
         (mutate-target-response-36-atomic-value old-payload)
         (make-target-response-36-action)))
    ((eq *terminal-action-format* :flat-36)
     (if (flat-36-action-p old-payload)
         (mutate-flat-36-atomic-value old-payload)
         (make-flat-36-action)))
    (t
     (error "Unsupported terminal action format: ~S"
            *terminal-action-format*))))

(defun mutate-action-option-orders (team)
  "Swap two entries in one host's policy-owned option permutation."
  (when (eq *decoy-order-mode* :evolved)
    (let ((orders (or (team-option-orders team)
                      (setf (team-option-orders team)
                            (make-default-action-option-orders)))))
      (when orders
        (let* ((target (1+ (random (1- (length orders)))))
               (order (aref orders target))
               (first (random (length order)))
               (second
                 (random-different-category first (length order))))
          (rotatef (aref order first) (aref order second))))))
  (when (eq *decoy-order-mode* :evolved)
    (note-mutation-event :decoy-order-mutation))
  team)

(defun mutate-action (team)
  "Choose a random learner on a team and change its action.
   Its new action might be a new atomic action or a reference
   to a team."
  (let* ((learners (team-learners team))
	 (learner (random-choice learners))
	 (action (learner-action learner))
	 (old-type (action-type action))
	 (old-payload (and (eq old-type :atomic)
                           (action-action action)))
	 (new-type (random-choice '(:atomic :reference))))
    ;; if the old action was a reference, we decrement the target's count.
    (when (eq (action-type action) :reference)
      (delete-reference (action-action action)))
    (case new-type
      (:atomic
	 (setf (action-type action) :atomic
               (action-action action)
               (mutated-atomic-action-value old-payload)))
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
	       (add-reference target))))))
    (cond
      ((or (eq old-type :reference) (eq new-type :reference))
       (note-mutation-event :team-edge-mutation))
      ((not (or (factored-action-p old-payload)
                (target-response-36-action-p old-payload)
                (flat-36-action-p old-payload)))
       (note-mutation-event :terminal-action-mutation))))
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
  ;; The policy's ordered-option table evolves independently from its terminal
  ;; target/response action, using the existing action-mutation probability.
  (when (and *factored-actions-enabled*
             (eq *decoy-order-mode* :evolved)
             (mutate-action-p))
    (mutate-action-option-orders team))
  (when (swap-learners-p)
    (swap-learners team))
  team)
