;;; Non-mutating effective-code and intron-analysis checks.

(in-package :cl-user)

(defun effective-test-instruction
       (dest op source1-type source1-value source2-type source2-value)
  (cl-tpg::%make-instruction
   :dest dest
   :op op
   :src1-type source1-type
   :src1-val (coerce source1-value 'double-float)
   :src2-type source2-type
   :src2-val (coerce source2-value 'double-float)
   :arity 2))

(defun effective-test-program (&rest instructions)
  (cl-tpg::make-program
   :instructions
   (make-array (length instructions)
               :fill-pointer t
               :adjustable t
               :initial-contents instructions)))

;; R2 is dead, and the write after the final R0 value is dead. R1 and R0 are
;; the exact backward slice required for the bid.
(let* ((program
         (effective-test-program
          (effective-test-instruction 1 :add :obs 0 :const 1)
          (effective-test-instruction 2 :add :obs 1 :const 1)
          (effective-test-instruction 0 :mul :reg 1 :const 2)
          (effective-test-instruction 3 :add :obs 2 :const 1)))
       (analysis (cl-tpg:analyze-program-effective-code program)))
  (assert (equal (getf analysis :effective-indices) '(0 2)))
  (assert (equalp (getf analysis :effective-mask) #*1010))
  (assert (= (getf analysis :effective-instruction-count) 2))
  (assert (= (getf analysis :intron-count) 2))
  (assert (equal (getf analysis :observation-indices) '(0)))
  (assert (null (getf analysis :initial-register-indices))))

;; A later overwrite kills the earlier R0 write completely.
(let* ((program
         (effective-test-program
          (effective-test-instruction 0 :add :obs 0 :const 1)
          (effective-test-instruction 0 :add :obs 1 :const 1)))
       (analysis (cl-tpg:analyze-program-effective-code program)))
  (assert (equal (getf analysis :effective-indices) '(1)))
  (assert (equal (getf analysis :observation-indices) '(1))))

;; Self-dependency keeps both writes and records an initial-register
;; dependency when no earlier instruction defines the source register.
(let* ((program
         (effective-test-program
          (effective-test-instruction 0 :add :reg 0 :obs 0)
          (effective-test-instruction 0 :mul :reg 0 :const 2)))
       (analysis (cl-tpg:analyze-program-effective-code program)))
  (assert (equal (getf analysis :effective-indices) '(0 1)))
  (assert (equal (getf analysis :initial-register-indices) '(0))))

;; Multiple output registers support auditing legacy register-decoded policies.
(let* ((program
         (effective-test-program
          (effective-test-instruction 0 :add :obs 0 :const 1)
          (effective-test-instruction 1 :add :obs 1 :const 1)
          (effective-test-instruction 2 :add :obs 2 :const 1)
          (effective-test-instruction 3 :add :obs 3 :const 1)))
       (analysis
         (cl-tpg:analyze-program-effective-code
          program :output-registers '(0 1 2))))
  (assert (equal (getf analysis :effective-indices) '(0 1 2)))
  (assert (equal (getf analysis :observation-indices) '(0 1 2))))

;; The compiled heuristic is intentionally fully effective. This also checks
;; the analyzer against a real, versioned checkpoint rather than only fixtures.
(multiple-value-bind (team fitness metadata)
    (cl-tpg::load-best-team
     (asdf:system-relative-pathname
      "cl-tpg"
      "oracles/checkpoints/bline-62-36-compiled-heuristic.lisp"))
  (declare (ignore fitness metadata))
  (let* ((before (cl-tpg::serialize-team team))
         (analysis (cl-tpg:analyze-team-effective-code team))
         (after (cl-tpg::serialize-team team)))
    (assert (equal before after))
    (assert (= (getf analysis :team-count) 1))
    (assert (= (getf analysis :learner-count) 29))
    (assert (= (getf analysis :instruction-count) 197))
    (assert (= (getf analysis :effective-instruction-count) 197))
    (assert (= (getf analysis :intron-count) 0))
    (assert (= (getf analysis :effective-ratio) 1.0d0))))

(format t "Effective-code analysis checks passed.~%")
