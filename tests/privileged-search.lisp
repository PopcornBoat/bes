(load (merge-pathnames "official-counterfactual-pilot.lisp"
                       (asdf:system-source-directory :cl-tpg)))
(load (merge-pathnames "privileged-search.lisp"
                       (asdf:system-source-directory :cl-tpg)))
(load (merge-pathnames "controller-aligned-credit.lisp"
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

(defun credit-test-learner (value target response)
  (make-learner
   :program (make-program
             :instructions (make-array 1 :fill-pointer 1 :adjustable t
                                       :initial-contents
                                       (list (incubation-instruction
                                              +bid-register+ :add :const value :const 0))))
   :action (make-action :type :atomic
                        :action (make-target-response-36-action
                                 :target target :response response))))

(let* ((*num-observations* 62) (*num-actions* 36)
       (*factored-actions-enabled* t) (*terminal-action-format* :target-response-36)
       (*instruction-set-profile* :reduced-eq) (*read-only-register-profile* :cage2-categorical-v1)
       (*recurrent-policy-enabled* nil)
       (controller (make-cage2-controller :decoy-order-profile :meander-heuristic))
       (observation (make-array 62 :element-type 'double-float :initial-element 0.0d0))
       (parent (%make-team :learners (list (credit-test-learner 10 3 0)
                                           (credit-test-learner 0 8 3))))
       (child (deep-copy-team-via-serialization parent))
       (event (list :step 3 :state-digest "state" :policy-observation observation
                    :incumbent-concrete 4
                    :controller-before (list :scan (make-list 10 :initial-element 0.0d0)
                                             :decoy-mask 0 :step 3)))
       (context (list :identity '("parent" "continuation" "env") :seed 153
                      :prefix '(51 116 55) :event event))
       (cache (make-hash-table :test #'equalp)))
  (push (credit-test-learner 100 1 3) (team-learners child))
  ;; Defender Decoy is the nominal new terminal. The actual action is User2
  ;; Femitter from the global schedule, so its evidence must be used.
  (setf (gethash (brute-credit-key context 28) cache) 100.0d0
        (gethash (brute-credit-key context 51) cache) 2.0d0)
  (let* ((result (brute-candidate-effect-evidence parent child controller (list context) cache))
         (row (first (getf result :effects))))
    (assert (= (getf row :after-concrete) 51))
    (assert (= (getf result :mean) 2.0d0)))
  (remhash (brute-credit-key context 51) cache)
  (let ((result (brute-candidate-effect-evidence parent child controller (list context) cache)))
    (assert (= (getf result :unknown) 1))
    (assert (null (getf result :mean))))
  (let ((different (copy-list context)))
    (setf (getf different :identity) '("other-parent" "continuation" "env"))
    (assert (not (equalp (brute-credit-key context 28) (brute-credit-key different 28)))))
  (let ((different (copy-list context)))
    (setf (getf different :prefix) '(51 116 29))
    (assert (not (equalp (brute-credit-key context 28) (brute-credit-key different 28)))))
  (let ((result (brute-candidate-effect-evidence parent parent controller (list context) cache)))
    (assert (= (getf result :unknown) 0))
    (assert (= (getf result :mean) 0.0d0))))
(format t "~&Controller-aligned action credit and context-isolation checks passed.~%")

(let* ((*num-observations* 62) (*num-actions* 36)
       (*factored-actions-enabled* t) (*terminal-action-format* :target-response-36)
       (*instruction-set-profile* :reduced-eq) (*read-only-register-profile* :cage2-categorical-v1)
       (positive (make-array 62 :element-type 'double-float :initial-element 0.0d0))
       (negative (copy-seq positive)))
 (setf (aref positive 61) 2.0d0)
 (let* ((cases (loop for seed in '(1 2)
                     append (list
                              (list :keep-advantage 1.0d0 :context
                                    (list :seed seed :event (list :policy-observation positive)))
                              (list :keep-advantage -2.0d0 :context
                                    (list :seed seed :event (list :policy-observation negative))))))
        (gates (aligned-rank-gates cases 4)))
   (assert gates)
   (assert (brute-gate-matches-p (getf (first gates) :predicates) positive))
   (assert (not (brute-gate-matches-p (getf (first gates) :predicates) negative))))
 (let* ((spec '(:insertion :root :target 8 :response 2 :predicates ((61 2)) :margin 250.0d0))
        (learner (credit-test-learner 0 8 2))
        (parent (%make-team :learners (list learner))))
  (setf (learner-program learner) (incubation-gate-program '((61 2)) 250.0d0))
  (brute-canonicalize-ids parent)
  (let ((child (aligned-refine-child parent spec '((61 1)) 250.0d0)))
   (assert (= (length (team-learners child)) 1))
   (assert (= (aref (execute-program (learner-program learner) positive) +bid-register+) 250.0d0))
   (assert (= (aref (execute-program (learner-program (first (team-learners child))) positive)
                    +bid-register+) -250.0d0)))))
(assert (fboundp 'aligned-full-ranking-query))
(format t "~&Signed refinement gate and single-learner isolation checks passed.~%")

(let* ((observation (make-array 62 :initial-element 0.0d0))
       (cases (loop for seed in '(1 2) for keep in '(1.0d0 -2.0d0)
                    collect (list :keep-advantage keep :context
                                  (list :seed seed :event
                                        (list :step 10 :policy-observation observation))))))
  (assert (= 1 (length (aligned-observation-conflicts cases))))
  (assert (null (aligned-observation-conflicts (list (first cases))))))
(format t "~&Identical-input conflicting-effect accounting checks passed.~%")
