;;; Atomic categorical-predicate mutation checks.

(in-package :cl-user)

(defvar *categorical-predicate-checks* 0)

(defun check-categorical-predicate (condition message)
  (incf *categorical-predicate-checks*)
  (unless condition
    (error "Categorical-predicate check failed: ~A" message)))

(defun categorical-predicate-read-request ()
  (with-open-file
      (stream
        (asdf:system-relative-pathname
         "cl-tpg" "experiments/categorical-predicate-mutation.sexp")
        :direction :input)
    (read stream)))

(let ((request (categorical-predicate-read-request)))
  (check-categorical-predicate
   (eq (getf request :categorical-predicate-mutation-enabled) :enabled)
   "the controlled experiment explicitly enables the compound operator")
  (check-categorical-predicate
   (cl-tpg::valid-search-parameters-p
    (getf request :mode) (getf request :gym-environment-name)
    (getf request :dataset-name) (getf request :num-observations)
    (getf request :num-actions) (getf request :population-size)
    (getf request :init-num-learners) (getf request :max-num-learners)
    (getf request :p-add) (getf request :p-del) (getf request :p-mut)
    (getf request :p-act) (getf request :p-swap) (getf request :gap)
    (getf request :init-program-size) (getf request :max-program-size)
    (getf request :p-add-instr) (getf request :p-del-instr)
    (getf request :p-swap-instrs) (getf request :p-mut-constant)
    (getf request :p-mut-constant-sign) (getf request :migration-interval)
    (getf request :batch-size) (getf request :seed)
    nil :none (getf request :decoy-order-mode)
    (getf request :cage2-opening-mode) nil
    (getf request :teacher-forcing-rollout-mode)
    (getf request :teacher-backend) (getf request :instruction-set-profile)
    (getf request :instruction-mutation-mode) t t nil
    (getf request :read-only-register-profile) t)
   "the controlled compound-predicate request is server-valid")
  (setf (getf request :instruction-set-profile) :reduced)
  (check-categorical-predicate
   (not
    (cl-tpg::valid-search-parameters-p
     (getf request :mode) (getf request :gym-environment-name)
     (getf request :dataset-name) (getf request :num-observations)
     (getf request :num-actions) (getf request :population-size)
     (getf request :init-num-learners) (getf request :max-num-learners)
     (getf request :p-add) (getf request :p-del) (getf request :p-mut)
     (getf request :p-act) (getf request :p-swap) (getf request :gap)
     (getf request :init-program-size) (getf request :max-program-size)
     (getf request :p-add-instr) (getf request :p-del-instr)
     (getf request :p-swap-instrs) (getf request :p-mut-constant)
     (getf request :p-mut-constant-sign) (getf request :migration-interval)
     (getf request :batch-size) (getf request :seed)
     nil :none (getf request :decoy-order-mode)
     (getf request :cage2-opening-mode) nil
     (getf request :teacher-forcing-rollout-mode)
     (getf request :teacher-backend) (getf request :instruction-set-profile)
     (getf request :instruction-mutation-mode) t t nil
     (getf request :read-only-register-profile) t))
   "the compound operator is rejected when EQ is unavailable"))

(let* ((cl-tpg::*instruction-set-profile* :reduced-eq)
       (cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*behavioral-locality-enabled* t)
       (cl-tpg::*active-mutation-events* nil)
       (instruction
         (cl-tpg::%make-instruction
          :dest 5 :op :add
          :src1-type :reg :src1-val 1.0d0
          :src2-type :const :src2-val 7.0d0
          :arity 2)))
  (cl-tpg::mutate-instruction-categorical-predicate instruction)
  (check-categorical-predicate
   (member :categorical-predicate-mutation
           cl-tpg::*active-mutation-events* :test #'eq)
   "the compound edit has a distinct behavioral-locality event")
  (check-categorical-predicate
   (and (= (cl-tpg::instruction-dest instruction) 5)
        (eq (cl-tpg::instruction-op instruction) :eq)
        (= (cl-tpg::instruction-arity instruction) 2)
        (eq (cl-tpg::instruction-src1-type instruction) :obs)
        (<= 0 (cl-tpg::instruction-src1-val instruction) 61)
        (eq (cl-tpg::instruction-src2-type instruction) :ror)
        (<= 0 (cl-tpg::instruction-src2-val instruction) 3))
   "one mutation forms a complete predicate while preserving destination")
  (let* ((observation-index
           (truncate (cl-tpg::instruction-src1-val instruction)))
         (category-index
           (truncate (cl-tpg::instruction-src2-val instruction)))
         (observations
           (make-array 62 :element-type 'double-float
                          :initial-element -1.0d0))
         (program
           (cl-tpg::make-program
            :instructions
            (make-array 1 :fill-pointer t :adjustable t
                          :initial-contents (list instruction)))))
    (setf (aref observations observation-index)
          (coerce category-index 'double-float))
    (check-categorical-predicate
     (= (aref (cl-tpg::execute-program program observations) 5) 1.0d0)
     "the injected predicate recognizes its selected category")
    (setf (aref observations observation-index)
          (coerce (mod (1+ category-index) 4) 'double-float))
    (check-categorical-predicate
     (= (aref (cl-tpg::execute-program program observations) 5) 0.0d0)
     "the injected predicate rejects another category")))

(let* ((cl-tpg::*instruction-set-profile* :reduced-eq)
       (cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
       (cl-tpg::*categorical-predicate-mutation-enabled* t)
       (cl-tpg::*categorical-predicate-mutation-probability* 1.0d0)
       (cl-tpg::*num-observations* 62)
       (instruction
         (cl-tpg::%make-instruction
          :dest 0 :op :add
          :src1-type :obs :src1-val 0.0d0
          :src2-type :const :src2-val 1.0d0
          :arity 2))
       (program
         (cl-tpg::make-program
          :instructions
          (make-array 1 :fill-pointer t :adjustable t
                        :initial-contents (list instruction)))))
  (cl-tpg::mutate-program-field-local program)
  (check-categorical-predicate
   (eq (cl-tpg::instruction-op
        (aref (cl-tpg::program-instructions program) 0))
       :eq)
   "probability one routes field-local mutation through the compound operator"))

(let* ((cl-tpg::*categorical-predicate-mutation-enabled* t)
       (cl-tpg::*current-search-mode* :online)
       (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0")
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*num-actions* 36)
       (cl-tpg::*instruction-set-profile* :reduced-eq)
       (cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
       (cl-tpg::*decoy-order-mode* :fixed)
       (cl-tpg::*teacher-backend* :heuristic)
       (cl-tpg::*cage2-opening-mode* :fixed)
       (cl-tpg::*hamming-space-enabled* nil)
       (cl-tpg::*recurrent-policy-enabled* nil)
       (team (cl-tpg::%make-team :learners nil))
       (data (cl-tpg::make-best-team-checkpoint-data team 0.0d0)))
  (check-categorical-predicate
   (getf data :categorical-predicate-mutation-enabled)
   "checkpoint metadata records the compound mutation operator")
  (check-categorical-predicate
   (search "categorical-predicate-on"
           (cl-tpg::best-team-checkpoint-filename))
   "checkpoint filenames isolate compound-predicate experiments"))

(format t "~D categorical-predicate checks passed.~%"
        *categorical-predicate-checks*)
