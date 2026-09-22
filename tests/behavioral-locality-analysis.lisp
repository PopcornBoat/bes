;;; Focused non-simulator checks for Phase-2 journal analysis.

(in-package :cl-user)

(defvar *behavioral-locality-analysis-checks* 0)

(defun check-locality-analysis (condition description)
  (incf *behavioral-locality-analysis-checks*)
  (unless condition
    (error "Behavioral-locality analysis check failed: ~A" description)))

(defun analysis-sample-record (event top1 ranking)
  (list :mutation-events (list (list event 1))
        :top1-hamming top1
        :teacher-rank-changed-rate top1
        :ranking-distance-mean ranking
        :top-k-overlap-mean (- 1.0d0 ranking)
        :child-off-support-rate 0.0d0))

(let* ((bad (analysis-sample-record :team-edge-mutation 0.75d0 0.60d0))
       (good (analysis-sample-record :instruction-add 0.02d0 0.03d0))
       (summary (cl-tpg::make-locality-analysis-summary)))
  (cl-tpg::process-behavioral-locality-form
   summary
   (list :type :mutation-generation :generation 1
         :records (list bad good)))
  (cl-tpg::process-behavioral-locality-form
   summary
   (list :type :official-outcome :generation 2 :lineage bad
         :evaluation
           (list :stage :racing :accepted nil
                 :parent-child-evaluation
                   (list :paired-mean -30.0d0
                         :behavioral-locality bad))))
  (cl-tpg::process-behavioral-locality-form
   summary
   (list :type :official-outcome :generation 3 :lineage good
         :evaluation
           (list :stage :promotion-stage-3 :accepted t
                 :parent-child-evaluation
                   (list :paired-mean 5.0d0
                         :behavioral-locality good))))
  (check-locality-analysis
   (= (cl-tpg::locality-analysis-summary-mutation-record-count summary) 2)
   "mutation-generation children are counted")
  (check-locality-analysis
   (= (cl-tpg::locality-analysis-summary-official-sample-count summary) 2)
   "official parent/child samples are counted")
  (check-locality-analysis
   (= (cl-tpg::locality-analysis-summary-accepted-count summary) 1)
   "accepted promotions are retained")
  (let ((overall (cl-tpg::locality-analysis-summary-official-overall summary)))
    (check-locality-analysis
     (= (gethash 25.0d0
                 (cl-tpg::locality-analysis-aggregate-catastrophic-counts
                  overall)
                 0)
        1)
     "catastrophic thresholds use paired return delta")
    (check-locality-analysis
     (= (cl-tpg::locality-analysis-aggregate-positive-count overall) 1)
     "positive mutations are counted"))
  (check-locality-analysis
   (= (cl-tpg::locality-analysis-aggregate-count
       (gethash :over-50
                (cl-tpg::locality-analysis-summary-top1-bins summary)))
      1)
   "large behavioral changes enter the correct bin")
  (check-locality-analysis
   (minusp
    (cl-tpg::locality-analysis-correlation
     '(0.75d0 0.02d0) '(-30.0d0 5.0d0)))
   "distance/return correlation is calculated")
  (let ((report (with-output-to-string (stream)
                  (cl-tpg::write-behavioral-locality-report
                   summary stream "synthetic"))))
    (check-locality-analysis
     (search "Positive paired-delta rate" report)
     "report names the paired-delta statistic accurately")
    (check-locality-analysis
     (search "Top-1 changed samples: 2 / 2" report)
     "report exposes behavior-changing official sample support")
    (check-locality-analysis
     (and (search "PROMOTION-STAGE-3" report)
          (search "RACING" report))
     "report exposes evaluation-stage support")))

(format t "Behavioral-locality analysis checks passed: ~D.~%"
        *behavioral-locality-analysis-checks*)
