;;; Instruction-set profile and checkpoint provenance checks.

(in-package :cl-user)

(defvar *instruction-set-checks* 0)

(defun check-instruction-set (condition message)
  (incf *instruction-set-checks*)
  (unless condition
    (error "Instruction-set check failed: ~A" message)))

(defun instruction-set-test-read-request (relative-path)
  (with-open-file
      (stream (asdf:system-relative-pathname "cl-tpg" relative-path)
              :direction :input)
    (read stream)))

(defun instruction-set-test-valid-request-p (request)
  (cl-tpg::valid-search-parameters-p
   (getf request :mode)
   (getf request :gym-environment-name)
   (getf request :dataset-name)
   (getf request :num-observations)
   (getf request :num-actions)
   (getf request :population-size)
   (getf request :init-num-learners)
   (getf request :max-num-learners)
   (getf request :p-add)
   (getf request :p-del)
   (getf request :p-mut)
   (getf request :p-act)
   (getf request :p-swap)
   (getf request :gap)
   (getf request :init-program-size)
   (getf request :max-program-size)
   (getf request :p-add-instr)
   (getf request :p-del-instr)
   (getf request :p-swap-instrs)
   (getf request :p-mut-constant)
   (getf request :p-mut-constant-sign)
   (getf request :migration-interval)
   (getf request :batch-size)
   (getf request :seed)
   (eq (getf request :hamming-space-enabled) :enabled)
   (getf request :hamming-dataset-name)
   (getf request :decoy-order-mode)
   (getf request :cage2-opening-mode)
   (eq (getf request :recurrent-policy-enabled) :enabled)
   (getf request :teacher-forcing-rollout-mode)
   (getf request :teacher-backend)
   (getf request :instruction-set-profile)
   (getf request :instruction-mutation-mode :legacy)
   (eq (getf request :effective-aware-mutation-enabled :disabled) :enabled)
   (eq (getf request :compression-reseed-enabled :disabled) :enabled)
   (eq (getf request :compression-reseed-force-next-event :disabled) :enabled)
   (getf request :read-only-register-profile :disabled)
   (eq (getf request :categorical-predicate-mutation-enabled :disabled)
       :enabled)))

(check-instruction-set
 (equal (cl-tpg::active-instruction-opcodes :full)
        '(:add :sub :mul :div :max :exp :log :sin :cos :tan :mod))
 "the full profile preserves the historical opcode catalogue")

(check-instruction-set
 (equal (cl-tpg::active-instruction-opcodes :reduced)
        '(:add :sub :mul :div))
 "the reduced profile contains only the compiled-heuristic arithmetic core")

(check-instruction-set
 (equal (cl-tpg::active-instruction-opcodes :reduced-eq)
        '(:add :sub :mul :div :eq))
 "the reduced-EQ profile adds only exact equality to the arithmetic core")

(check-instruction-set
 (and (cl-tpg::valid-instruction-set-profile-p :full)
      (cl-tpg::valid-instruction-set-profile-p :reduced)
      (cl-tpg::valid-instruction-set-profile-p :reduced-eq)
      (not (cl-tpg::valid-instruction-set-profile-p :unknown)))
 "only the versioned profiles are accepted")

(check-instruction-set
 (= (cl-tpg::opcode-arity :eq) 2)
 "EQ is a binary instruction")

;; EQ is deliberately exact: categorical observations and ROR values are
;; transported as exact double-float encodings of small integers.
(let* ((cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
       (equal-instruction
         (cl-tpg::%make-instruction
          :dest 0 :op :eq
          :src1-type :obs :src1-val 0.0d0
          :src2-type :ror :src2-val 2.0d0
          :arity 2))
       (program
         (cl-tpg::make-program
          :instructions
          (make-array 1 :fill-pointer t :adjustable t
                      :initial-contents (list equal-instruction)))))
  (check-instruction-set
   (= (aref (cl-tpg::execute-program
             program
             (make-array 1 :element-type 'double-float
                           :initial-contents '(2.0d0)))
            0)
      1.0d0)
   "EQ returns one for an observation matching a categorical ROR")
  (check-instruction-set
   (= (aref (cl-tpg::execute-program
             program
             (make-array 1 :element-type 'double-float
                           :initial-contents '(1.0d0)))
            0)
      0.0d0)
   "EQ returns zero for a categorical mismatch"))

(let ((full
        (instruction-set-test-read-request
         "experiments/instruction-set-full.sexp"))
      (reduced
        (instruction-set-test-read-request
         "experiments/instruction-set-reduced.sexp")))
  (check-instruction-set
   (instruction-set-test-valid-request-p full)
   "the full-profile controlled request passes server validation")
  (check-instruction-set
   (instruction-set-test-valid-request-p reduced)
   "the reduced-profile controlled request passes server validation")
  (setf (getf reduced :instruction-set-profile) :unknown)
  (check-instruction-set
   (not (instruction-set-test-valid-request-p reduced))
   "server validation rejects an unknown profile"))

(let ((request
        (instruction-set-test-read-request
         "experiments/effective-local-compression.sexp")))
  (check-instruction-set
   (instruction-set-test-valid-request-p request)
   "the field-local/effective/compression request passes server validation")
  (setf (getf request :effective-aware-mutation-enabled) :disabled)
  (check-instruction-set
   (not (instruction-set-test-valid-request-p request))
   "compression is rejected without effective-aware selection"))

(let ((request
        (instruction-set-test-read-request
         "experiments/categorical-equality.sexp")))
  (check-instruction-set
   (instruction-set-test-valid-request-p request)
   "the ROR+EQ controlled request passes server validation")
  (check-instruction-set
   (and (eq (getf request :instruction-set-profile) :reduced-eq)
        (eq (getf request :read-only-register-profile)
            :cage2-categorical-v1))
   "the ROR+EQ request keeps both experimental factors explicit"))

;; Fresh instructions and instruction additions obey the selected profile.
(let ((cl-tpg::*instruction-set-profile* :reduced)
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*max-program-size* 8))
  (check-instruction-set
   (loop repeat 256
         always (member (cl-tpg::instruction-op (cl-tpg::make-instruction))
                        cl-tpg::+reduced-instruction-opcodes+
                        :test #'eq))
   "fresh reduced-profile instructions never sample excluded opcodes")
  (let ((program
          (cl-tpg::make-program
           :instructions
           (make-array 0 :fill-pointer t :adjustable t))))
    (cl-tpg::add-instruction program)
    (check-instruction-set
     (and (= (length (cl-tpg::program-instructions program)) 1)
          (member
           (cl-tpg::instruction-op
            (aref (cl-tpg::program-instructions program) 0))
           cl-tpg::+reduced-instruction-opcodes+
           :test #'eq))
     "ADD-INSTRUCTION uses the selected profile")))

;; The profile limits creation, not execution. Historical nonlinear checkpoint
;; instructions remain valid when a reduced-profile experiment is active.
(let* ((cl-tpg::*instruction-set-profile* :reduced)
       (instruction
         (cl-tpg::%make-instruction
          :dest 0 :op :sin
          :src1-type :obs :src1-val 0.0d0
          :src2-type :const :src2-val 0.0d0
          :arity 1))
       (program
         (cl-tpg::make-program
          :instructions
          (make-array 1
                      :fill-pointer t
                      :adjustable t
                      :initial-contents (list instruction))))
       (observation
         (make-array 1
                     :element-type 'double-float
                     :initial-contents '(0.5d0))))
  (check-instruction-set
   (= (aref (cl-tpg::execute-program program observation) 0)
      (sin 0.5d0))
   "reduced mode does not invalidate an inherited historical opcode"))

;; The deterministic compiled teacher establishes that the four-opcode set can
;; encode the complete reference policy, rather than merely toy programs.
(multiple-value-bind (team fitness metadata)
    (cl-tpg::load-best-team
     (asdf:system-relative-pathname
      "cl-tpg"
      "oracles/checkpoints/bline-62-36-compiled-heuristic.lisp"))
  (declare (ignore fitness metadata))
  (check-instruction-set
   (loop for graph-team in (cl-tpg::closure team)
         always
         (loop for learner in (cl-tpg::team-learners graph-team)
               always
               (loop for instruction across
                       (cl-tpg::program-instructions
                        (cl-tpg::learner-program learner))
                     always
                     (member (cl-tpg::instruction-op instruction)
                             cl-tpg::+reduced-instruction-opcodes+
                             :test #'eq))))
   "the compiled B-line heuristic is expressible in the reduced set"))

;; Checkpoint provenance and filenames isolate the ablation conditions.
(let* ((cl-tpg::*instruction-set-profile* :reduced)
       (cl-tpg::*instruction-mutation-mode* :field-local)
       (cl-tpg::*effective-aware-mutation-enabled* t)
       (cl-tpg::*compression-reseed-enabled* t)
       (cl-tpg::*current-search-mode* :online)
       (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0")
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*num-actions* 36)
       (cl-tpg::*decoy-order-mode* :fixed)
       (cl-tpg::*teacher-backend* :heuristic)
       (cl-tpg::*cage2-opening-mode* :fixed)
       (cl-tpg::*hamming-space-enabled* nil)
       (cl-tpg::*recurrent-policy-enabled* nil)
       (team (cl-tpg::%make-team :learners nil))
       (data (cl-tpg::make-best-team-checkpoint-data team 0.0d0)))
  (check-instruction-set
   (eq (getf data :instruction-set-profile) :reduced)
   "checkpoint metadata records the active profile")
  (check-instruction-set
   (and (eq (getf data :instruction-mutation-mode) :field-local)
        (getf data :effective-aware-mutation-enabled)
        (getf data :compression-reseed-enabled)
        (eq (getf data :compression-reseed-protocol)
            cl-tpg::+compression-reseed-protocol+))
   "checkpoint metadata records local/effective/compression provenance")
  (check-instruction-set
   (search "operators-reduced"
           (cl-tpg::best-team-checkpoint-filename))
   "checkpoint filenames isolate reduced-profile experiments"))

;; A warm start may still inject a checkpoint under another profile, but its
;; stored score must be re-evaluated rather than treated as comparable.
(let* ((cl-tpg::*current-search-mode* :online)
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*terminal-action-format* :target-response-36)
       (cl-tpg::*instruction-set-profile* :reduced)
       (cl-tpg::*decoy-order-mode* :fixed)
       (cl-tpg::*cage2-opening-mode* :fixed)
       (cl-tpg::*recurrent-policy-enabled* nil)
       (cl-tpg::*teacher-backend* :heuristic)
       (cl-tpg::*hamming-space-enabled* nil)
       (metadata
         (list
          :gym-environment-name "Cage2-b_line-100-v0"
          :num-observations 62
          :terminal-action-format :target-response-36
          :instruction-set-profile :reduced
          :decoy-order-mode :fixed
          :cage2-opening-mode :fixed
          :recurrent-policy-enabled nil
          :teacher-backend :heuristic
          :hamming-space-enabled nil
          :fitness-evaluation-protocol cl-tpg::+cage2-online-fitness-protocol+
          :online-reference-episodes
            cl-tpg::+cage2-online-reference-episodes+
          :action-agreement-signature
            (cl-tpg::action-agreement-signature))))
  (check-instruction-set
   (cl-tpg::checkpoint-fitness-comparable-p
    0.0d0 metadata "Cage2-b_line-100-v0")
   "matching-profile stored fitness remains comparable")
  (setf (getf metadata :instruction-set-profile) :full)
  (check-instruction-set
   (not
    (cl-tpg::checkpoint-fitness-comparable-p
     0.0d0 metadata "Cage2-b_line-100-v0"))
   "cross-profile warm starts must re-evaluate stored fitness"))

(format t "~D instruction-set checks passed.~%" *instruction-set-checks*)
