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
  (dolist (gate (brute-predicate-variants probe (list probe other)))
    (assert (brute-gate-matches-p gate probe))
    (assert (every (lambda (p) (<= 0 (first p) 61)) gate))
    (let* ((program (incubation-gate-program gate 250.0d0))
           (registers (execute-program program probe)))
      (assert (plusp (aref registers +bid-register+)))))
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
