;;; Focused aggregation checks for dual-policy disagreement analysis.

(in-package :cl-user)

(defun policy-analysis-proposal (label pair concrete path learner)
  (list :label label
        :winning-learner learner
        :winning-bid 1.0d0
        :preferred-path path
        :terminal-team (car (last path))
        :ranking (list pair '(1 0) '(2 0))
        :decision (list :pair pair :concrete-action concrete)))

(let* ((teacher-pair '(2 0))
       (step
         (list :step 4
               :policy-observation (make-array 62 :initial-element 0.0d0)
               :decoy-mask-before 255
               :opening-pairs nil
               :teacher-ranking (list teacher-pair '(1 0))
               :teacher-decision
                 (list :pair teacher-pair :concrete-action 0)
               :policy-proposals
                 (list
                  (policy-analysis-proposal
                   :evolved '(1 0) 0 '("ROOT" "TERMINAL") "E")
                  (policy-analysis-proposal
                   :compiled teacher-pair 0 '("COMPILED") "C"))))
       (episode
         (list :behavior :evolved
               :seed 153
               :return -1.0d0
               :first-teacher-disagreement 4
               :steps (list step)))
       (summary
         (cl-tpg::summarize-policy-disagreement-episodes (list episode))))
  (assert (= (getf summary :policy-steps) 1))
  (assert (= (getf summary :mean-return) -1.0d0))
  (assert (= (getf summary :evolved-compiled-top1-agreement-rate) 0.0d0))
  (assert (= (getf summary :evolved-compiled-concrete-agreement-rate) 1.0d0))
  (assert (= (getf summary :semantic-different-concrete-same-rate) 1.0d0))
  (assert (= (getf summary :teacher-in-evolved-top8-rate) 1.0d0))
  (assert (= (getf (first (getf summary :phase-summary))
                   :concrete-disagreement-rate)
             0.0d0))
  (assert (= (getf summary :evolved-path-max-length) 2))
  (assert (= (getf summary :evolved-unique-path-teams) 2))
  (let ((merged
          (cl-tpg::merge-policy-disagreement-summaries summary summary)))
    (assert (= (getf merged :episodes) 2))
    (assert (= (getf merged :policy-steps) 2))
    (assert (= (getf merged :mean-return) -1.0d0))
    (assert (= (getf merged :evolved-compiled-concrete-agreement-rate)
               1.0d0))
    (assert (= (getf merged :evolved-unique-path-teams) 2))))

(assert (equal (cl-tpg::policy-disagreement-parse-seeds "153, 42,2026")
               '(153 42 2026)))
(assert (= (length
            (cl-tpg::policy-disagreement-parse-seeds
             "validation-bline-100"))
           1000))
(assert (= (cl-tpg::policy-disagreement-copy-value 255) 255))

(format t "Policy disagreement analysis checks passed.~%")
