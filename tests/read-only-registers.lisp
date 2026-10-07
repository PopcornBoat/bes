;;; CAGE2 categorical read-only-register checks.

(in-package :cl-user)

(defvar *ror-checks* 0)

(defun check-ror (condition message)
  (incf *ror-checks*)
  (unless condition
    (error "ROR check failed: ~A" message)))

(defun ror-read-request ()
  (with-open-file
      (stream (asdf:system-relative-pathname
               "cl-tpg" "experiments/read-only-registers.sexp")
              :direction :input)
    (read stream)))

(defun ror-valid-request-p (request)
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
   (eq (getf request :hamming-space-enabled) :enabled)
   (getf request :hamming-dataset-name) (getf request :decoy-order-mode)
   (getf request :cage2-opening-mode)
   (eq (getf request :recurrent-policy-enabled) :enabled)
   (getf request :teacher-forcing-rollout-mode) (getf request :teacher-backend)
   (getf request :instruction-set-profile) (getf request :instruction-mutation-mode)
   (eq (getf request :effective-aware-mutation-enabled) :enabled)
   (eq (getf request :compression-reseed-enabled) :enabled)
   (eq (getf request :compression-reseed-force-next-event) :enabled)
   (getf request :read-only-register-profile)
   (eq (getf request :categorical-predicate-mutation-enabled :disabled)
       :enabled)))

(check-ror
 (and (cl-tpg::valid-read-only-register-profile-p :disabled)
      (cl-tpg::valid-read-only-register-profile-p :cage2-categorical-v1)
      (not (cl-tpg::valid-read-only-register-profile-p :unknown)))
 "only versioned ROR profiles are accepted")

(let ((request (ror-read-request)))
  (check-ror (ror-valid-request-p request)
             "the checked-in ROR warm-start request is server-valid")
  (setf (getf request :read-only-register-profile) :unknown)
  (check-ror (not (ror-valid-request-p request))
             "server validation rejects an unknown ROR profile"))

(let ((cl-tpg::*read-only-register-profile* :cage2-categorical-v1))
  (check-ror
   (equalp (cl-tpg::active-read-only-register-values)
           #(0.0d0 1.0d0 2.0d0 3.0d0))
   "the categorical bank is exactly 0, 1, 2, 3")
  (multiple-value-bind (type index) (cl-tpg::decode-symbol 'cl-tpg::ror3)
    (check-ror (and (eq type :ror) (= index 3.0d0))
               "ROR symbols decode to zero-based source indices"))
  (let* ((instruction
           (cl-tpg::%make-instruction
            :dest 0 :op :add
            :src1-type :ror :src1-val 2.0d0
            :src2-type :ror :src2-val 3.0d0
            :arity 2))
         (program
           (cl-tpg::make-program
            :instructions
            (make-array 1 :fill-pointer t :adjustable t
                        :initial-contents (list instruction))))
         (observation
           (make-array 62 :element-type 'double-float
                          :initial-element 0.0d0)))
    (check-ror (= (aref (cl-tpg::execute-program program observation) 0)
                  5.0d0)
               "program execution resolves ROR values without writable state")
    (check-ror
     (equal (cl-tpg::instruction->sexp instruction)
            '(cl-tpg::r1 :add cl-tpg::ror2 cl-tpg::ror3))
     "pretty printing preserves ROR operands")))

(let ((cl-tpg::*read-only-register-profile* :disabled)
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*read-only-register-source-probability* 1.0d0))
  (dotimes (index 100)
    (check-ror
     (not (eq (nth-value 0 (cl-tpg::decode-symbol
                            (cl-tpg::random-argument)))
              :ror))
     "disabled profile never generates ROR sources")))

(let ((cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*read-only-register-source-probability* 1.0d0))
  (dotimes (index 100)
    (multiple-value-bind (type value)
        (cl-tpg::decode-symbol (cl-tpg::random-argument))
      (check-ror (and (eq type :ror) (<= 0 value 3))
                 "enabled forced generation returns a valid ROR source"))))

(let* ((cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
       (cl-tpg::*num-observations* 62)
       (team (cl-tpg::%make-team :learners nil))
       (data (cl-tpg::make-best-team-checkpoint-data team 0.0d0)))
  (check-ror
   (and (eq (getf data :read-only-register-profile)
            :cage2-categorical-v1)
        (equal (getf data :read-only-register-values)
               '(0.0d0 1.0d0 2.0d0 3.0d0)))
   "checkpoint metadata records the profile and exact constant bank"))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0")
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*num-actions* 36)
      (cl-tpg::*instruction-set-profile* :reduced)
      (cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
      (cl-tpg::*decoy-order-mode* :fixed)
      (cl-tpg::*teacher-backend* :heuristic)
      (cl-tpg::*cage2-opening-mode* :fixed)
      (cl-tpg::*hamming-space-enabled* nil)
      (cl-tpg::*recurrent-policy-enabled* nil))
  (check-ror
   (search "-ror-cage2-categorical-v1-"
           (cl-tpg::best-team-checkpoint-filename))
   "ROR treatment checkpoints have a distinct filename component"))

(format t "~D read-only-register checks passed.~%" *ror-checks*)
