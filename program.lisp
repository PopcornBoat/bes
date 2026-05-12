(in-package :cl-tpg)

(defstruct program
  (instructions (make-array *init-program-size*
			    :fill-pointer t 
			    :adjustable t
			    :initial-contents
			    (loop repeat *init-program-size*
				  collect (make-instruction)))
   :type (vector t *)))

(defun serialize-program (program)
  "Makes a machine-readable program that can be sent over the wire."
  `(:instructions ,(coerce (program-instructions program) 'list)))

(defun deserialize-program (data)
  "From a serialized program back into the actual struct."
  (let ((instructions (getf data :instructions)))
    (make-program
     :instructions (make-array (length instructions)
		:fill-pointer t
		:adjustable t
		:initial-contents
		instructions))))

(defun execute-program (program observations)
  "Given an encoded program and a double-array of OBSERVATIONS
  representing the state. Execute the program and return its
  registers."
  (declare (optimize (speed 3) (safety 0) (debug 0))
	   (type (simple-array double-float (*)) observations)
           (type program program))
  (let* ((instructions (program-instructions program))
         (registers (make-array +num-registers+
                               :element-type 'double-float
                               :initial-element 0.0d0)))
    (declare (type (simple-array double-float (*)) registers)
             (type (vector t *) instructions))
    
    (loop for ins across instructions do
      (let* ((op   (instruction-op ins))
             (dest (instruction-dest ins))
             (v1   (the double-float (instruction-src1-val ins)))
             (arg1 (case (instruction-src1-type ins)
                     (:reg (aref registers (the fixnum (truncate v1))))
                     (:obs (aref observations (the fixnum (truncate v1))))
                     (t v1))))
        (declare (type double-float arg1) (type fixnum dest))
        
        (let ((result
                (if (= (the fixnum (instruction-arity ins)) 1)
                    (case op
                      (:SIN (sin arg1))
                      (:COS (cos arg1))
                      (:TAN (let ((r (tan arg1)))
                              (if (> (abs r) 1.0d4) 0.0d0 r)))
                      (:EXP (if (< arg1 7.0d0) (exp arg1) 1.0d3))
                      (:LOG (if (> arg1 0.0d0) (log arg1) 0.0d0))
                      (t 0.0d0))
                    (let* ((v2   (the double-float (instruction-src2-val ins)))
                           (arg2 (case (instruction-src2-type ins)
                                   (:reg (aref registers (the fixnum (truncate v2))))
                                   (:obs (aref observations (the fixnum (truncate v2))))
                                   (t v2))))
                      (declare (type double-float arg2))
                      (case op
                        (:ADD (+ arg1 arg2))
                        (:SUB (- arg1 arg2))
                        (:MUL (* arg1 arg2))
                        (:DIV (if (zerop arg2) 0.0d0 (/ arg1 arg2)))
                        (:MOD (if (zerop arg2)
                                  0.0d0
                                  (let ((q (ffloor (/ arg1 arg2))))
                                    (declare (type double-float q))
                                    (the double-float (- arg1 (the double-float (* q arg2)))))))
                        (:MAX (max arg1 arg2))
                        (t 0.0d0))))))
          (declare (type double-float result))
          (when (> result 1.0d3)
            (setf result 1.0d3))
          (when (< result -1.0d3)
            (setf result -1.0d3))
          (setf (aref registers dest) result))))
    registers))

(defun pprint-program (program)
  "Transforms a program into a list of symbolic instructions."
  (map 'list #'instruction->sexp (program-instructions program)))

(defmethod print-object ((p program) stream)
  "Updates the default printer to pretty print instructions symbolically."
  (print-unreadable-object (p stream :type t :identity t)
    (format stream "~%~{ ~A~%~}" (pprint-program p))))

(defun clone-program (program)
  "Deep-copies a program."
  (make-program
   :instructions (alexandria:copy-array (program-instructions program))))
