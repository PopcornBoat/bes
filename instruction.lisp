(in-package :cl-tpg)

(defun random-register ()
  "Return a random register symbol."
  (intern (format nil "R~D" (1+ (random +num-registers+)))))

(defun random-observation  ()
  "Return a random observation symbol."
  (intern (format nil "OBS~D" (1+ (random *num-observations*)))))

(defun random-argument ()
  "Returns a random register or a random observation."
  (case (random-choice '(:reg :obs))
    (:reg (random-register))
    (:obs (random-observation))))

(defun random-constant ()
  "Returns a random constant in the range of [-5.0, 5.0]"
  (random-range -5.0 5.0))

(defun random-argument-or-constant ()
  "Returns either a random register, a random observation, or a random constant."
  (case (random-choice '(:arg
			 :constant))
    (:arg (random-argument))
    (:constant (random-constant))))

(defun opcode-arity (opcode)
  "Returns the arity of a given OPCODE."
  (ecase opcode
    ((:ADD :SUB :MUL :DIV :MOD :MAX) 2)
    ((:SIN :COS :TAN :EXP :LOG) 1)))

(defun decode-symbol (sym)
  "Convert symbols like registers (RXX) or observations (OBSYY) into types and indices."
  (if (numberp sym)
      (values :const (coerce sym 'double-float))
      (let ((name (symbol-name sym)))
	(cond
	  ((string= (subseq name 0 1) "R")
	   (values :reg (coerce (1- (parse-integer (subseq name 1))) 'double-float)))
	  ((string= (subseq name 0 3) "OBS")
	   (values :obs (coerce (1- (parse-integer (subseq name 3))) 'double-float)))
	  (t (error "Unknown operand: ~A" sym))))))

(defstruct (instruction
            (:type vector)
            (:constructor %make-instruction)
            (:constructor make-instruction
             (&aux
              ;; 1. Generate the opcode and arity
              (op (random-choice '(:ADD :SUB :MUL :DIV :MAX :EXP :LOG :SIN :COS :TAN :MOD)))
              (arity (opcode-arity op))
              ;; 2. Generate destination index directly
              (dest (truncate (nth-value 1 (decode-symbol (random-register)))))
              ;; 3. Handle Operands
              ;; We use temporary variables to store the decoded pairs
              (tmp1 (multiple-value-list (decode-symbol (random-argument))))
              (src1-type (first tmp1))
              (src1-val  (second tmp1))
              ;; Logic for arg2
              (tmp2 (multiple-value-list 
                     (if (= arity 2)
                         (decode-symbol (random-argument-or-constant))
                         (values :const 0.0d0))))
              (src2-type (first tmp2))
              (src2-val  (second tmp2)))))
  (dest 0 :type fixnum)
  (op :NO-OP :type keyword)
  (src1-type :const :type keyword)
  (src1-val 0.0d0 :type double-float)
  (src2-type :const :type keyword)
  (src2-val 0.0d0 :type double-float)
  (arity 2 :type fixnum))

(defun instruction->sexp (instr)
  "Converts a raw instruction vector back into a readable format."
  (flet ((render (type val)
	   (case type
	     (:reg (intern (format nil "R~D" (1+ (truncate val)))))
	     (:obs (intern (format nil "OBS~D" (1+ (truncate val)))))
	     (t val))))
    (let ((dest (render :reg (float (instruction-dest instr) 1.0d0)))
	  (op (instruction-op instr))
	  (arg1 (render (instruction-src1-type instr) (instruction-src1-val instr)))
	  (arg2 (render (instruction-src2-type instr) (instruction-src2-val instr))))
      (if (= (instruction-arity instr) 1)
	  (list dest op arg1)
	  (list dest op arg1 arg2)))))

(defun instruction-has-constant-p (instr)
  "Returns T the instruction has a constant."
  (and (> (instruction-arity instr) 1)
       (or (eq (instruction-src1-type instr) :const)
	   (eq (instruction-src2-type instr) :const))))
    
