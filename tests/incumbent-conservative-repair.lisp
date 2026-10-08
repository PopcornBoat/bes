;;; Incumbent-anchored conservative repair checks.

(in-package :cl-user)

(defvar *incumbent-conservative-checks* 0)

(defun check-incumbent-conservative (condition message)
  (incf *incumbent-conservative-checks*)
  (unless condition
    (error "Incumbent-conservative repair check failed: ~A" message)))

(defun incumbent-conservative-read-request ()
  (with-open-file
      (stream
        (asdf:system-relative-pathname
         "cl-tpg" "experiments/incumbent-conservative-repair.sexp")
        :direction :input)
    (read stream)))

(let ((request (incumbent-conservative-read-request)))
  (check-incumbent-conservative
   (and (eq (getf request :incumbent-conservative-repair-enabled)
            :enabled)
        (eq (getf request :teacher-guided-predicate-injection-enabled)
            :disabled)
        (eq (getf request :categorical-predicate-mutation-enabled)
            :disabled))
   "the experiment isolates incumbent repair from both older predicate paths")
  (check-incumbent-conservative
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
    (getf request :read-only-register-profile) nil nil t)
   "the incumbent-conservative request is server-valid"))

(let* ((cl-tpg::*instruction-set-profile* :reduced-eq)
       (cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
       (cl-tpg::*num-observations* 3)
       (target-a (make-array 3 :element-type 'double-float
                               :initial-contents '(1.0d0 2.0d0 0.0d0)))
       (target-b (make-array 3 :element-type 'double-float
                               :initial-contents '(1.0d0 2.0d0 3.0d0)))
       (only-left (make-array 3 :element-type 'double-float
                                :initial-contents '(1.0d0 0.0d0 0.0d0)))
       (only-right (make-array 3 :element-type 'double-float
                                 :initial-contents '(0.0d0 2.0d0 0.0d0)))
       (contexts (list (list :observation target-a)
                       (list :observation target-b)
                       (list :observation target-a)))
       (background (list only-left only-right))
       (conjunctions
         (cl-tpg::incumbent-conservative-conjunctions
          contexts background))
       (best (first conjunctions)))
  (check-incumbent-conservative
   (and best
        (zerop (getf best :background-hits))
        (= (getf best :target-hits) 3))
   "two individually ambiguous predicates form a collision-free conjunction")
  (let* ((program
           (cl-tpg::incumbent-conservative-gate-program best 7.5d0))
         (on-registers (cl-tpg::execute-program program target-a))
         (left-registers (cl-tpg::execute-program program only-left))
         (right-registers (cl-tpg::execute-program program only-right)))
    (check-incumbent-conservative
     (< (abs (- (aref on-registers cl-tpg::+bid-register+) 7.5d0))
        1.0d-9)
     "the AND gate emits its calibrated bid when both predicates match")
    (check-incumbent-conservative
     (and (= (aref left-registers cl-tpg::+bid-register+) -1000.0d0)
          (= (aref right-registers cl-tpg::+bid-register+) -1000.0d0))
     "either missing predicate suppresses the new specialist")))

(let* ((conjunction
         (list :left (list :observation-index 0 :value 1.0d0)
               :right (list :observation-index 1 :value 2.0d0)))
       (target (make-array 2 :element-type 'double-float
                             :initial-contents '(1.0d0 2.0d0)))
       (context (list (list :observation target)))
       (learner
         (cl-tpg::make-learner
          :program
            (cl-tpg::make-program
             :instructions (make-array 0 :fill-pointer 0 :adjustable t))
          :action
            (cl-tpg::make-action
             :type :atomic
             :action
               (cl-tpg::make-target-response-36-action
                :target 2 :response 0))))
       (team (cl-tpg::%make-team :learners (list learner))))
  (check-incumbent-conservative
   (null
    (cl-tpg::incumbent-conservative-gate-threshold
     team context conjunction (list target)))
   "threshold calibration rejects a target/background collision without a safe bid interval"))

(let* ((cl-tpg::*max-num-learners* 4)
       (cl-tpg::*active-mutation-events* nil)
       (existing
         (cl-tpg::make-learner
          :program
            (cl-tpg::make-program
             :instructions (make-array 0 :fill-pointer 0 :adjustable t))
          :action
            (cl-tpg::make-action
             :type :atomic
             :action
               (cl-tpg::make-target-response-36-action
                :target 2 :response 0))))
       (team (cl-tpg::%make-team :learners (list existing)))
       (conjunction
         (list :left (list :observation-index 0 :ror-index 1 :value 1.0d0)
               :right (list :observation-index 1 :ror-index 2 :value 2.0d0)))
       (installation
         (cl-tpg::incumbent-conservative-install-specialist
          team '(2 3) conjunction 4.0d0)))
  (check-incumbent-conservative
   (and (eq (first (cl-tpg::team-learners team)) existing)
        (= (getf installation :learner-index) 1))
   "the new specialist is appended so an off-gate -1000 tie preserves the incumbent"))

(let* ((cl-tpg::*incumbent-conservative-repair-enabled* t)
       (cl-tpg::*teacher-guided-predicate-injection-enabled* nil)
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
  (check-incumbent-conservative
   (and (getf data :incumbent-conservative-repair-enabled)
        (eq (getf data :incumbent-conservative-repair-protocol)
            cl-tpg::+incumbent-conservative-repair-protocol+))
   "checkpoint metadata records the conservative protocol")
  (check-incumbent-conservative
   (search "incumbent-conservative-repair"
           (cl-tpg::best-team-checkpoint-filename))
   "checkpoint filenames isolate incumbent-conservative results"))

(format t "~D incumbent-conservative repair checks passed.~%"
        *incumbent-conservative-checks*)
