;;; Narrow checks for the v13 Decoy-priority causal intervention.

(in-package :cl-user)

(defvar *decoy-priority-intervention-checks* 0)

(defun check-decoy-priority-intervention (condition message)
  (incf *decoy-priority-intervention-checks*)
  (unless condition
    (error "Decoy-priority intervention check failed: ~A" message)))

(let* ((cl-tpg::*num-observations* 62)
       (instructions
         (make-array
          1 :fill-pointer t :adjustable t
          :initial-contents
            (list
             (cl-tpg::decoy-priority-instruction
              cl-tpg::+bid-register+ :add :const 7.0d0 :const 0.0d0))))
       (program (cl-tpg::make-program :instructions instructions))
       (matching (make-array 62 :element-type 'double-float
                                :initial-element 0.0d0))
       (nonmatching (copy-seq matching)))
  (setf (aref matching 4) 1.0d0
        (aref nonmatching 4) 0.0d0)
  (cl-tpg::append-exact-pattern-demotion-gate
   program '(4 5 6 7) '(1 0 0 0))
  (check-decoy-priority-intervention
   (= (aref (cl-tpg::execute-program program matching)
            cl-tpg::+bid-register+)
      7.0d0)
   "the exact E0 pattern preserves the original bid")
  (check-decoy-priority-intervention
   (= (aref (cl-tpg::execute-program program nonmatching)
            cl-tpg::+bid-register+)
      -993.0d0)
   "an unsupported E0 Analyse bid is demoted by exactly 1000"))

(flet ((terminal (observations effective-count)
         (let ((program
                 (cl-tpg::make-program
                  :instructions
                    (make-array
                     effective-count :fill-pointer t :adjustable t
                     :initial-contents
                       (loop for observation in observations
                             for first-p = t then nil
                             collect
                             (cl-tpg::decoy-priority-instruction
                              cl-tpg::+bid-register+ :add
                              :obs observation
                              (if first-p :const :reg)
                              (if first-p 1.0d0 cl-tpg::+bid-register+)))))))
           (cl-tpg::make-learner
            :program program
            :action
              (cl-tpg::make-action
               :type :atomic
               :action
                 (cl-tpg::make-target-response-36-action
                  :target 2 :response 0))))))
  (let* ((cl-tpg::*num-observations* 62)
         (proxy-a (terminal '(18 33) 2))
         (proxy-b (terminal '(27) 1))
         (direct (terminal '(4) 1))
         (team (cl-tpg::%make-team
                :learners (list proxy-a proxy-b direct)))
         (records
           (cl-tpg::apply-bline-decoy-priority-intervention
            team
            :learner-ids
              (list (cl-tpg::learner-id proxy-a)
                    (cl-tpg::learner-id proxy-b)))))
    (check-decoy-priority-intervention
     (= (length records) 2)
     "only the two measured effective-code signatures are modified")
    (check-decoy-priority-intervention
     (= (length (cl-tpg::program-instructions
                 (cl-tpg::learner-program direct)))
        1)
     "an E0 Analyse learner that reads the direct E0 state is untouched")))

(format t "~D decoy-priority intervention checks passed.~%"
        *decoy-priority-intervention-checks*)
