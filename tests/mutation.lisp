;;; Focused mutation regression checks.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(let* ((instructions
         (make-array
          2
          :fill-pointer t
          :adjustable t
          :initial-contents
          (list
           (cl-tpg::%make-instruction
            :dest 0 :op :sin
            :src1-type :reg :src1-val 0.0d0
            :src2-type :const :src2-val 0.0d0
            :arity 1)
           (cl-tpg::%make-instruction
            :dest 1 :op :div
            :src1-type :obs :src1-val 0.0d0
            :src2-type :obs :src2-val 1.0d0
            :arity 2))))
       (program (cl-tpg::make-program :instructions instructions)))
  ;; REMOVE-IF-NOT returns #() for this vector.  MUTATE-CONSTANT must treat
  ;; that as empty instead of passing it to RANDOM-CHOICE/RANDOM 0.
  (assert (eq program (cl-tpg::mutate-constant program)))
  (assert (= (length (cl-tpg::program-instructions program)) 2)))

(format t "Mutation regression checks passed.~%")
