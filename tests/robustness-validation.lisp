(in-package :cl-user)

(defvar *robustness-validation-checks* 0)

(defun check-robustness-validation (condition description)
  (incf *robustness-validation-checks*)
  (unless condition
    (error "Robustness validation check failed: ~A" description)))

(let* ((a (cl-tpg::robustness-validation-seed 314159 100 0))
       (b (cl-tpg::robustness-validation-seed 314159 100 1))
       (c (cl-tpg::robustness-validation-seed 271828 100 0)))
  (check-robustness-validation
   (= a (cl-tpg::robustness-validation-seed 314159 100 0))
   "seed derivation is reproducible")
  (check-robustness-validation
   (= (cl-tpg::robustness-validation-seed-namespace a) 9)
   "robustness seeds use the reserved namespace")
  (check-robustness-validation
   (= (length (remove-duplicates (list a b c))) 3)
   "root and episode coordinates produce distinct seeds"))

(let ((summary
        (cl-tpg::robustness-return-summary
         '(-10.0d0 -20.0d0 -30.0d0))))
  (check-robustness-validation
   (= (getf summary :mean) -20.0d0)
   "return mean is correct")
  (check-robustness-validation
   (= (getf summary :minimum) -30.0d0)
   "minimum is reported")
  (check-robustness-validation
   (= (getf summary :cvar10) -30.0d0)
   "small-sample CVaR includes the worst episode"))

(let ((paired
        (cl-tpg::robustness-paired-summary
         '(-10.0d0 -20.0d0 -30.0d0)
         '(-12.0d0 -20.0d0 -25.0d0))))
  (check-robustness-validation
   (and (= (getf paired :wins) 1)
        (= (getf paired :ties) 1)
        (= (getf paired :losses) 1))
   "paired wins, ties, and losses are classified consistently"))

(check-robustness-validation
 (= (cl-tpg::robustness-validate-seed-plan
     '(314159 271828) '(30 50 100) 10)
    60)
 "the complete seed plan is collision free")

(let* ((records
         (list
          (list :protocol cl-tpg::+robustness-validation-protocol+
                :horizon 100 :root 314159 :episode 0
                :seed (cl-tpg::robustness-validation-seed 314159 100 0)
                :policy :v14 :return -10.0d0)
          (list :protocol cl-tpg::+robustness-validation-protocol+
                :horizon 100 :root 314159 :episode 0
                :seed (cl-tpg::robustness-validation-seed 314159 100 0)
                :policy :v13 :return -12.0d0)))
       (summary
         (cl-tpg::robustness-aggregate-pair-summaries
          records '(100) :v14 '(:v13))))
  (check-robustness-validation
   (= (getf (getf (first summary) :statistics) :mean) 2.0d0)
   "aggregate paired summaries preserve same-seed deltas"))

(format t "~&robustness validation checks passed: ~D~%"
        *robustness-validation-checks*)
