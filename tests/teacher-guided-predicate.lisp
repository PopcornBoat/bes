;;; Teacher-guided categorical predicate checks.

(in-package :cl-user)

(defvar *teacher-guided-predicate-checks* 0)

(defun check-teacher-guided-predicate (condition message)
  (incf *teacher-guided-predicate-checks*)
  (unless condition
    (error "Teacher-guided predicate check failed: ~A" message)))

(defun teacher-guided-read-request ()
  (with-open-file
      (stream
        (asdf:system-relative-pathname
         "cl-tpg" "experiments/teacher-guided-predicate-injection.sexp")
        :direction :input)
    (read stream)))

(let ((request (teacher-guided-read-request)))
  (check-teacher-guided-predicate
   (and (eq (getf request :teacher-guided-predicate-injection-enabled)
            :enabled)
        (eq (getf request :categorical-predicate-mutation-enabled)
            :disabled))
   "the experiment isolates guided predicates from random compound mutation")
  (check-teacher-guided-predicate
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
    (getf request :read-only-register-profile) nil t)
   "the guided experiment request is server-valid"))

(let* ((cl-tpg::*instruction-set-profile* :reduced-eq)
       (cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
       (cl-tpg::*num-observations* 2)
       (target-a (make-array 2 :element-type 'double-float
                               :initial-contents '(2.0d0 1.0d0)))
       (target-b (make-array 2 :element-type 'double-float
                               :initial-contents '(2.0d0 0.0d0)))
       (background-a (make-array 2 :element-type 'double-float
                                   :initial-contents '(0.0d0 1.0d0)))
       (background-b (make-array 2 :element-type 'double-float
                                   :initial-contents '(1.0d0 0.0d0)))
       (cl-tpg::*behavioral-probe-archive*
         (list (list :observation background-a :step 40
                     :teacher-pair '(3 0))
               (list :observation background-b :step 60
                     :teacher-pair '(4 1))))
       (contexts
         (list (list :observation target-a)
               (list :observation target-b)
               (list :observation target-a)))
       (issue (list :phase :early :teacher-pair '(2 3)))
       (records
         (cl-tpg::teacher-guided-predicate-records contexts issue))
       (best (first records)))
  (check-teacher-guided-predicate
   (and best
        (= (getf best :observation-index) 0)
        (= (getf best :ror-index) 2)
        (= (getf best :coverage) 1.0d0)
        (= (getf best :collision-rate) 0.0d0))
   "predicate scoring selects the separating categorical equality")
  (let* ((program (cl-tpg::teacher-guided-new-gate-program best))
         (on-registers (cl-tpg::execute-program program target-a))
         (off-registers (cl-tpg::execute-program program background-a)))
    (check-teacher-guided-predicate
     (= (aref on-registers cl-tpg::+bid-register+) 1000.0d0)
     "a matching new specialist saturates its bid")
    (check-teacher-guided-predicate
     (= (aref off-registers cl-tpg::+bid-register+) -1000.0d0)
     "a nonmatching new specialist is suppressed")))

(let ((cl-tpg::*teacher-guided-predicate-rng-root* nil))
  (cl-tpg::initialize-teacher-guided-predicate-state 153)
  (cl-tpg::teacher-guided-predicate-random-below 10)
  (let ((saved (cl-tpg::teacher-guided-predicate-state-copy)))
    (cl-tpg::initialize-teacher-guided-predicate-state 999)
    (cl-tpg::restore-teacher-guided-predicate-state saved)
    (check-teacher-guided-predicate
     (equal saved (cl-tpg::teacher-guided-predicate-state-copy))
     "guided scheduling resumes with the exact isolated cursor")))

(let* ((cl-tpg::*teacher-guided-predicate-injection-enabled* t)
       (cl-tpg::*current-search-mode* :official-guided)
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
  (check-teacher-guided-predicate
   (getf data :teacher-guided-predicate-injection-enabled)
   "checkpoint metadata records the guided treatment")
  (check-teacher-guided-predicate
   (search "teacher-guided-predicate"
           (cl-tpg::best-team-checkpoint-filename))
   "checkpoint filenames isolate guided-predicate results"))

(format t "~D teacher-guided predicate checks passed.~%"
        *teacher-guided-predicate-checks*)
