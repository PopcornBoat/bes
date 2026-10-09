;;; Focused checks for the coordinated reactive/Decoy checkpoint intervention.

(in-package :cl-user)

(defun backbone-test-learner (target response bid)
  (cl-tpg::reactive-backbone-terminal-learner
   target response
   (cl-tpg::reactive-backbone-constant-bid-program bid)))

(defun backbone-test-root ()
  (cl-tpg::%make-team
   :id "BACKBONE-TEST-ROOT"
   :references 0
   :type :root
   :option-orders (cl-tpg::make-default-action-option-orders)
   :learners
   (list
    (backbone-test-learner 1 1 500.0d0)
    (backbone-test-learner 7 1 -500.0d0))))

(defun backbone-ranking-pairs (team observation)
  (mapcar #'cl-tpg::semantic-action-category-pair
          (cl-tpg:execute-team-semantic-ranked team observation)))

(let* ((cl-tpg::*num-observations* cl-tpg::+cage2-scan-observation-size+)
       (cl-tpg::*num-actions* cl-tpg::+num-semantic-36-actions+)
       (cl-tpg::*factored-actions-enabled* t)
       (cl-tpg::*terminal-action-format* :target-response-36)
       (team (backbone-test-root))
       (original (copy-list (cl-tpg::team-learners team)))
       (zero
         (make-array cl-tpg::+cage2-scan-observation-size+
                     :element-type 'double-float
                     :initial-element 0.0d0)))
  (let ((summary (cl-tpg::install-reactive-decoy-backbone team)))
    (assert (= (getf summary :reactive-learners) 8))
    (assert (= (getf summary :decoy-learners) 7))
    (assert (= (length (cl-tpg::team-learners team)) 17)))

  ;; The seven scheduled target categories are stable and the old root winner
  ;; remains the eighth fallback.  Scaling preserves old bid order exactly.
  (let ((pairs (backbone-ranking-pairs team zero)))
    (assert
     (equal (subseq pairs 0 7)
            '((8 3) (2 3) (3 3) (4 3) (5 3) (9 3) (10 3))))
    (assert (equal (eighth pairs) '(1 1))))
  (multiple-value-bind (high-bid high-registers)
      (cl-tpg::bid (first original) zero)
    (declare (ignore high-registers))
    (multiple-value-bind (low-bid low-registers)
        (cl-tpg::bid (second original) zero)
      (declare (ignore low-registers))
      (assert (= high-bid 5.0d0))
      (assert (= low-bid -5.0d0))
      (assert (> high-bid low-bid))))

  ;; The Controller, rather than the policy, still chooses the concrete option.
  (let* ((ranking (cl-tpg:execute-team-semantic-ranked team zero))
         (controller
           (cl-tpg:make-cage2-controller :decoy-order-profile :heuristic))
         (decision
           (cl-tpg:cage2-controller-resolve-ranking controller ranking)))
    (assert
     (equal
      (list
       (cl-tpg:semantic-action-target
        (cl-tpg:cage2-controller-decision-semantic-action decision))
       (cl-tpg:cage2-controller-decision-option decision))
      '(8 1))))

  ;; Exact Enterprise0 Analyse support outranks the backbone.
  (let ((analyse (copy-seq zero)))
    (setf (aref analyse 4) 1.0d0)
    (assert (equal (first (backbone-ranking-pairs team analyse)) '(2 0))))

  ;; Restore requires both a listed raw pattern and nonzero canonical scan state.
  (let ((restore (copy-seq zero)))
    (setf (aref restore 7) 1.0d0
          (aref restore 53) 2.0d0)
    (assert (equal (first (backbone-ranking-pairs team restore)) '(2 2)))))

(format t "Reactive Decoy backbone checks passed.~%")
