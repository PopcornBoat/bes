;;; Focused checks for episode-local recurrent learner registers.
;;; Load :CL-TPG before loading this file.

(in-package :cl-tpg)

(defun recurrent-test-increment-program ()
  (make-program
   :instructions
   (make-array
    1
    :fill-pointer t
    :adjustable t
    :initial-contents
    (list
     (%make-instruction
      :dest 0
      :op :add
      :src1-type :reg
      :src1-val 0.0d0
      :src2-type :const
      :src2-val 1.0d0
      :arity 2)))))

(defun assert-recurrent-register-test (condition control &rest arguments)
  (unless condition
    (error (apply #'format nil control arguments))))

(let* ((observations
         (make-array 1
                     :element-type 'double-float
                     :initial-element 0.0d0))
       (first-learner
         (make-learner
          :id "RECURRENT-TEST-FIRST"
          :program (recurrent-test-increment-program)
          :action (make-action :type :atomic :action 0)))
       (second-learner
         (make-learner
          :id "RECURRENT-TEST-SECOND"
          :program (recurrent-test-increment-program)
          :action (make-action :type :atomic :action 0))))
  ;; Legacy/stateless execution still clears before every bid.
  (let ((*recurrent-policy-enabled* nil))
    (assert-recurrent-register-test
     (= (bid first-learner observations) 1.0d0)
     "First stateless bid did not start at zero.")
    (assert-recurrent-register-test
     (= (bid first-learner observations) 1.0d0)
     "Stateless bid unexpectedly retained registers."))

  ;; Within one episode, each learner owns an independent persistent vector.
  (let ((*recurrent-policy-enabled* t))
    (call-with-fresh-policy-episode
     (lambda ()
       (assert-recurrent-register-test
        (= (bid first-learner observations) 1.0d0)
        "First recurrent bid did not start at zero.")
       (assert-recurrent-register-test
        (= (bid first-learner observations) 2.0d0)
        "Recurrent bid did not preserve the learner's register.")
       (assert-recurrent-register-test
        (= (bid second-learner observations) 1.0d0)
        "Register state leaked between learners.")
       (assert-recurrent-register-test
        (= (bid first-learner observations) 3.0d0)
        "A different learner changed the first learner's state.")))

    ;; A new rollout/episode creates a new table and therefore resets memory.
    (call-with-fresh-policy-episode
     (lambda ()
       (assert-recurrent-register-test
        (= (bid first-learner observations) 1.0d0)
        "A fresh episode did not reset recurrent registers.")))

    ;; Merely enabling the feature is not enough outside an episode binding;
    ;; this is what keeps unordered offline row fitness stateless.
    (assert-recurrent-register-test
     (= (bid first-learner observations) 1.0d0)
     "Offline-style execution retained recurrent state without an episode."))

  (let ((*current-search-mode* :online)
        (*current-gym-environment-name* "Cage2-b_line-100-v0")
        (*num-observations* 62)
        (*num-actions* 11)
        (*decoy-order-mode* :fixed)
        (*teacher-backend* :model)
        (*cage2-opening-mode* :fixed)
        (*hamming-space-enabled* nil)
        (*recurrent-policy-enabled* t))
    (assert-recurrent-register-test
     (string=
      (best-team-checkpoint-filename)
      "bline-62-11-online-order-fixed-teacher-model-opening-fixed-hamming-off-memory-recurrent.lisp")
     "Recurrent checkpoint filename does not identify its memory mode."))

  (format t "Recurrent register checks passed.~%"))
