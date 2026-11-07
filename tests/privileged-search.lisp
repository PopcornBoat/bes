(load (merge-pathnames "official-counterfactual-pilot.lisp"
                       (asdf:system-source-directory :cl-tpg)))
(load (merge-pathnames "privileged-search.lisp"
                       (asdf:system-source-directory :cl-tpg)))
(in-package :cl-tpg)

(let* ((*num-observations* 62) (*num-actions* 36)
       (*factored-actions-enabled* t) (*terminal-action-format* :target-response-36)
       (*instruction-set-profile* :reduced-eq)
       (*read-only-register-profile* :cage2-categorical-v1)
       (probe (make-array 62 :element-type 'double-float :initial-element 0.0d0))
       (other (copy-seq probe)))
  (setf (aref probe 61) 2.0d0)
  (let* ((records (loop for seed in '(153 42)
                        append (list (list :seed seed :pair '(8 2) :delta 4.0d0
                                          :event (list :policy-observation probe))
                                     (list :seed seed :pair '(8 2) :delta -5.0d0
                                          :event (list :policy-observation other)))))
         (gates (brute-predicate-variants probe (list probe other) records '(8 2))))
    (assert gates)
    (assert (not (brute-predicate-variants probe (list probe other)
                                          (subseq records 0 2) '(8 2))))
    (dolist (gate gates)
    (assert (brute-gate-matches-p gate probe))
    (assert (every (lambda (p) (<= 0 (first p) 61)) gate))
    (let* ((program (incubation-gate-program gate 250.0d0))
           (registers (execute-program program probe)))
      (assert (plusp (aref registers +bid-register+))))
      (assert (not (brute-gate-matches-p gate other)))))
  (assert (not (brute-safety-regressions
                '((:loss 0 :controlled-steps 0 :maximum-control-streak 0))
                '((:loss 0 :controlled-steps 0 :maximum-control-streak 0)))))
  (assert (brute-safety-regressions
           '((:loss 0 :controlled-steps 0 :maximum-control-streak 0))
           '((:loss 1 :controlled-steps 0 :maximum-control-streak 0))))
  (assert (brute-safety-regressions
           '((:loss 0 :controlled-steps 0 :maximum-control-streak 0))
           '((:loss 0 :controlled-steps 1 :maximum-control-streak 1))))
  (let* ((learner (make-learner :program (incubation-gate-program '((61 2)) 250.0d0)
                               :action (make-action :type :atomic
                                         :action (make-target-response-36-action
                                                  :target 8 :response 2))))
         (team (%make-team :learners (list learner)))
         (before (incubation-policy-pair team probe))
         (copy (deep-copy-team-via-serialization team)))
    (brute-canonicalize-ids team)
    (brute-canonicalize-ids copy)
    (assert (equal (team-id team) (team-id copy)))
    (assert (equal before (incubation-policy-pair copy probe)))
    (setf (instruction-src1-val
           (aref (program-instructions (learner-program (first (team-learners copy)))) 0))
          60.0d0)
    (assert (= (instruction-src1-val
                (aref (program-instructions (learner-program learner)) 0)) 61.0d0))))
(format t "~&Privileged search gate, identity and deep-copy checks passed.~%")
