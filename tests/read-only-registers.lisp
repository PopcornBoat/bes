;;; CAGE2 categorical read-only-register checks.

(in-package :cl-user)

(defvar *ror-checks* 0)

(defun check-ror (condition message)
  (incf *ror-checks*)
  (unless condition
    (error "ROR check failed: ~A" message)))

(check-ror
 (and (cl-tpg::valid-read-only-register-profile-p :disabled)
      (cl-tpg::valid-read-only-register-profile-p :cage2-categorical-v1)
      (not (cl-tpg::valid-read-only-register-profile-p :unknown)))
 "only versioned ROR profiles are accepted")

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
