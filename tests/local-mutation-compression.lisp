;;; Field-local, effective-aware mutation and guarded compression checks.

(in-package :cl-user)

(defvar *local-compression-checks* 0)

(defun check-local-compression (condition message)
  (incf *local-compression-checks*)
  (unless condition
    (error "Local/compression check failed: ~A" message)))

(defun local-test-instruction
       (dest op source1-type source1-value source2-type source2-value)
  (cl-tpg::%make-instruction
   :dest dest :op op
   :src1-type source1-type
   :src1-val (coerce source1-value 'double-float)
   :src2-type source2-type
   :src2-val (coerce source2-value 'double-float)
   :arity (cl-tpg::opcode-arity op)))

(defun local-test-program (&rest instructions)
  (cl-tpg::make-program
   :instructions
   (make-array (length instructions)
               :fill-pointer t
               :adjustable t
               :initial-contents instructions)))

(check-local-compression
 (and (cl-tpg::valid-instruction-mutation-mode-p :legacy)
      (cl-tpg::valid-instruction-mutation-mode-p :field-local)
      (not (cl-tpg::valid-instruction-mutation-mode-p :unknown)))
 "only versioned instruction mutation modes are accepted")

(check-local-compression
 (and (= cl-tpg::*compression-reseed-min-generation* 1000)
      (= cl-tpg::*compression-reseed-check-interval* 1000)
      (= cl-tpg::*compression-reseed-cooldown-generations* 1000))
 "scheduled compression uses the versioned 1000-generation cadence")

(let* ((cl-tpg::*instruction-set-profile* :reduced)
       (instruction
         (local-test-instruction 0 :add :obs 0 :const 1)))
  (cl-tpg::mutate-instruction-opcode instruction)
  (check-local-compression
   (and (not (eq (cl-tpg::instruction-op instruction) :add))
        (member (cl-tpg::instruction-op instruction)
                cl-tpg::+reduced-instruction-opcodes+ :test #'eq))
   "opcode edits stay inside the reduced profile"))

(let ((instruction
        (local-test-instruction 0 :add :obs 0 :const 1)))
  (cl-tpg::mutate-instruction-destination instruction)
  (check-local-compression
   (/= (cl-tpg::instruction-dest instruction) 0)
   "destination mutation changes exactly the destination field"))

(let ((cl-tpg::*num-observations* 62)
      (instruction
        (local-test-instruction 0 :add :obs 0 :reg 1)))
  (cl-tpg::mutate-instruction-source-type instruction)
  (check-local-compression
   (or (not (eq (cl-tpg::instruction-src1-type instruction) :obs))
       (not (eq (cl-tpg::instruction-src2-type instruction) :reg)))
   "source-type mutation changes one source representation"))

(let ((cl-tpg::*num-observations* 62)
      (instruction
        (local-test-instruction 0 :add :obs 0 :reg 1)))
  (let ((before
          (list (cl-tpg::instruction-src1-val instruction)
                (cl-tpg::instruction-src2-val instruction))))
    (cl-tpg::mutate-instruction-source-index instruction)
    (check-local-compression
     (not (equal before
                 (list (cl-tpg::instruction-src1-val instruction)
                       (cl-tpg::instruction-src2-val instruction))))
     "source-index mutation changes one compatible index")))

(let ((cl-tpg::*p-mut-constant-sign* 0.0d0)
      (instruction
        (local-test-instruction 0 :add :obs 0 :const 1)))
  (let ((before (cl-tpg::instruction-src2-val instruction)))
    (cl-tpg::mutate-instruction-constant instruction)
    (check-local-compression
     (/= before (cl-tpg::instruction-src2-val instruction))
     "constant perturbation changes a constant source")))

;; Only indices 0 and 2 contribute to R0. With probability one, the selector
;; must never spend a field mutation on dead index 1.
(let* ((cl-tpg::*effective-aware-mutation-enabled* t)
       (cl-tpg::*effective-instruction-selection-probability* 1.0d0)
       (program
         (local-test-program
          (local-test-instruction 1 :add :obs 0 :const 1)
          (local-test-instruction 2 :add :obs 1 :const 1)
          (local-test-instruction 0 :mul :reg 1 :const 2))))
  (check-local-compression
   (loop repeat 100
         always (member (cl-tpg::field-local-instruction-index program)
                        '(0 2)))
   "effective-aware selection targets only the R0 slice when configured to 1.0"))

;; Pruning is exact for stateless execution and leaves the removed program
;; storage independent.
(let* ((cl-tpg::*recurrent-policy-enabled* nil)
       (program
         (local-test-program
          (local-test-instruction 1 :add :obs 0 :const 1)
          (local-test-instruction 2 :add :obs 1 :const 1)
          (local-test-instruction 0 :mul :reg 1 :const 2)
          (local-test-instruction 3 :add :obs 2 :const 1)))
       (observation
         (make-array 3 :element-type 'double-float
                       :initial-contents '(3.0d0 7.0d0 9.0d0)))
       (before (aref (cl-tpg::execute-program program observation) 0))
       (record (cl-tpg::prune-program-to-effective-code program))
       (after (aref (cl-tpg::execute-program program observation) 0)))
  (check-local-compression
   (and (= before after)
        (= (getf record :before) 4)
        (= (getf record :after) 2)
        (= (getf record :removed) 2))
   "program compression preserves R0 while removing introns"))

;; A full event works only on a serialize/deserialize copy, proves ranking
;; equivalence on the archive, and injects a compact root without modifying the
;; protected incumbent.
(let* ((cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*factored-actions-enabled* t)
       (cl-tpg::*terminal-action-format* :target-response-36)
       (cl-tpg::*instruction-mutation-mode* :field-local)
       (cl-tpg::*effective-aware-mutation-enabled* t)
       (cl-tpg::*compression-reseed-enabled* t)
       (cl-tpg::*recurrent-policy-enabled* nil)
       (cl-tpg::*num-observations* 3)
       (cl-tpg::*num-actions* 36)
       (cl-tpg::*population-size* 10)
       (cl-tpg::*generation* 10)
       (cl-tpg::*official-guided-incumbent-version* 4)
       (cl-tpg::*compression-reseed-last-incumbent-version* 4)
       (cl-tpg::*compression-reseed-last-improvement-generation* 1)
       (cl-tpg::*compression-reseed-last-event-generation* nil)
       (cl-tpg::*compression-reseed-event-count* 0)
       (cl-tpg::*compression-reseed-force-next-event* t)
       (instructions
         (append
          (loop repeat 19
                collect (local-test-instruction 3 :add :obs 0 :const 1))
          (list (local-test-instruction 0 :add :obs 0 :const 1))))
       (program (apply #'local-test-program instructions))
       (learner
         (cl-tpg::make-learner
          :program program
          :action
            (cl-tpg::make-action
             :type :atomic
             :action
               (cl-tpg::make-target-response-36-action
                :target 1 :response 0))))
       (best (cl-tpg::%make-team :learners (list learner)))
       (survivor (cl-tpg::%make-team :learners nil))
       (probe-observation
         (make-array 3 :element-type 'double-float
                       :initial-contents '(1.0d0 0.0d0 0.0d0)))
       (cl-tpg::*best-team* best)
       (cl-tpg::*teams* (list survivor))
       (cl-tpg::*behavioral-probe-archive*
         (list (list :observation probe-observation)))
       (protected-before (cl-tpg::serialize-team best)))
  (multiple-value-bind (compressed variants)
      (cl-tpg::maybe-install-compression-reseed-parent)
    (check-local-compression
     (and compressed
          (zerop variants)
          (= (length (cl-tpg::root-teams)) 2)
          (= (length
              (cl-tpg::program-instructions
               (cl-tpg::learner-program
                (first (cl-tpg::team-learners compressed)))))
             1)
          (equal protected-before (cl-tpg::serialize-team best))
          (not cl-tpg::*compression-reseed-force-next-event*)
          (= cl-tpg::*compression-reseed-event-count* 1))
     "forced compression bypasses scheduling once, injects an independent compact root, and protects BEST-TEAM")))

(format t "~D local-mutation/compression checks passed.~%"
        *local-compression-checks*)
