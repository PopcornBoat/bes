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
  (let ((sample
          (list :type :locality-sample-outcome
                :sample-id "sample-1"
                :generation 4
                :stratum :large-top1
                :evaluation
                  (list :paired-mean -40.0d0
                        :behavioral-locality bad))))
    (cl-tpg::process-behavioral-locality-form summary sample)
    (cl-tpg::process-behavioral-locality-form summary sample))
  (check-locality-analysis
   (= (cl-tpg::locality-analysis-summary-mutation-record-count summary) 2)
   "mutation-generation children are counted")
  (check-locality-analysis
   (= (cl-tpg::locality-analysis-summary-official-sample-count summary) 2)
   "official parent/child samples are counted")
  (check-locality-analysis
   (= (cl-tpg::locality-analysis-summary-accepted-count summary) 1)
   "accepted promotions are retained")
  (check-locality-analysis
   (= (cl-tpg::locality-analysis-summary-stratified-outcome-count summary) 1)
   "passive official samples are deduplicated by sample id")
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
     "report exposes evaluation-stage support")
    (check-locality-analysis
     (and (search "Stratified passive official samples" report)
          (search "LARGE-TOP1" report)
          (search "-40.0000" report))
     "report separates passive samples from selection-biased outcomes")))

(let* ((directory
         (merge-pathnames
          (format nil "bes-locality-analysis-~D/" (get-internal-real-time))
          (uiop:temporary-directory)))
       (outcome-directory
         (merge-pathnames ".behavioral-locality-samples/" directory))
       (journal (merge-pathnames "behavioral-locality-records.lisp" directory))
       (outcome (merge-pathnames "sample-1-outcome.lisp" outcome-directory))
       (report (merge-pathnames "report.md" directory))
       (record (analysis-sample-record :instruction-add 0.1d0 0.05d0)))
  (ensure-directories-exist outcome)
  (with-open-file (stream journal :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
    (write '(:type :mutation-generation :generation 1 :records nil)
           :stream stream))
  (with-open-file (stream outcome :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
    (write (list :type :locality-sample-outcome
                 :sample-id "atomic-1"
                 :generation 1
                 :stratum :medium-top1
                 :evaluation
                   (list :paired-mean -7.0d0
                         :behavioral-locality record))
           :stream stream))
  (unwind-protect
       (let ((summary
               (cl-tpg::analyze-behavioral-locality-journal
                journal :output-path report)))
         (check-locality-analysis
          (= (cl-tpg::locality-analysis-summary-stratified-outcome-count
              summary)
             1)
          "analyzer discovers atomic passive outcome files beside the journal"))
    (dolist (path (list journal outcome report))
      (when (probe-file path) (delete-file path)))
    (when (probe-file outcome-directory)
      (ignore-errors (uiop:delete-empty-directory outcome-directory)))
    (when (probe-file directory)
      (ignore-errors (uiop:delete-empty-directory directory)))))

(format t "Behavioral-locality analysis checks passed: ~D.~%"
        *behavioral-locality-analysis-checks*)
