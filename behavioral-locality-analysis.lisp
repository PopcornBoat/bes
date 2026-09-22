(in-package :cl-tpg)

;;; Phase-2 analysis is deliberately offline and passive.  These functions
;;; consume the append-only journal but never participate in search decisions.

(defparameter +locality-catastrophic-thresholds+ '(10.0d0 25.0d0 50.0d0 100.0d0))

(defstruct locality-analysis-aggregate
  (count 0 :type integer)
  (delta-count 0 :type integer)
  (top1-sum 0.0d0 :type double-float)
  (teacher-rank-sum 0.0d0 :type double-float)
  (ranking-distance-sum 0.0d0 :type double-float)
  (overlap-sum 0.0d0 :type double-float)
  (off-support-sum 0.0d0 :type double-float)
  (delta-sum 0.0d0 :type double-float)
  (positive-count 0 :type integer)
  (catastrophic-counts (make-hash-table :test #'eql)))

(defstruct locality-analysis-summary
  (generation-form-count 0 :type integer)
  (mutation-record-count 0 :type integer)
  (official-outcome-count 0 :type integer)
  (official-sample-count 0 :type integer)
  (accepted-count 0 :type integer)
  (mutation-overall (make-locality-analysis-aggregate))
  (official-overall (make-locality-analysis-aggregate))
  (mutation-events (make-hash-table :test #'eq))
  (official-events (make-hash-table :test #'eq))
  (top1-bins (make-hash-table :test #'eq))
  (ranking-bins (make-hash-table :test #'eq))
  (stages (make-hash-table :test #'eq))
  (official-samples nil))

(defun locality-double (value)
  (coerce (or value 0.0d0) 'double-float))

(defun locality-record-events (record)
  "Return unique mutation-layer names attached to one child RECORD."
  (or (remove-duplicates
       (loop for entry in (getf record :mutation-events)
             when (and (consp entry) (symbolp (first entry)))
               collect (first entry))
       :test #'eq)
      '(:no-recorded-event)))

(defun update-locality-analysis-aggregate (aggregate record &optional delta)
  (incf (locality-analysis-aggregate-count aggregate))
  (incf (locality-analysis-aggregate-top1-sum aggregate)
        (locality-double (getf record :top1-hamming)))
  (incf (locality-analysis-aggregate-teacher-rank-sum aggregate)
        (locality-double (getf record :teacher-rank-changed-rate)))
  (incf (locality-analysis-aggregate-ranking-distance-sum aggregate)
        (locality-double (getf record :ranking-distance-mean)))
  (incf (locality-analysis-aggregate-overlap-sum aggregate)
        (locality-double (getf record :top-k-overlap-mean)))
  (incf (locality-analysis-aggregate-off-support-sum aggregate)
        (locality-double (getf record :child-off-support-rate)))
  (when (numberp delta)
    (let ((numeric (coerce delta 'double-float)))
      (incf (locality-analysis-aggregate-delta-count aggregate))
      (incf (locality-analysis-aggregate-delta-sum aggregate) numeric)
      (when (plusp numeric)
        (incf (locality-analysis-aggregate-positive-count aggregate)))
      (dolist (threshold +locality-catastrophic-thresholds+)
        (when (< numeric (- threshold))
          (incf (gethash threshold
                         (locality-analysis-aggregate-catastrophic-counts
                          aggregate)
                         0))))))
  aggregate)

(defun locality-table-aggregate (table key)
  (or (gethash key table)
      (setf (gethash key table) (make-locality-analysis-aggregate))))

(defun locality-distance-bin (value)
  (cond
    ((zerop value) :zero)
    ((<= value 0.05d0) :up-to-05)
    ((<= value 0.20d0) :05-to-20)
    ((<= value 0.50d0) :20-to-50)
    (t :over-50)))

(defun process-locality-mutation-record (summary record)
  (incf (locality-analysis-summary-mutation-record-count summary))
  (update-locality-analysis-aggregate
   (locality-analysis-summary-mutation-overall summary) record)
  (dolist (event (locality-record-events record))
    (update-locality-analysis-aggregate
     (locality-table-aggregate
      (locality-analysis-summary-mutation-events summary) event)
     record)))

(defun process-locality-official-outcome (summary form)
  (incf (locality-analysis-summary-official-outcome-count summary))
  (let* ((evaluation (getf form :evaluation))
         (parent-child (getf evaluation :parent-child-evaluation))
         (record (or (getf parent-child :behavioral-locality)
                     (getf form :lineage)))
         (delta (and parent-child (getf parent-child :paired-mean))))
    (incf (gethash (getf evaluation :stage :unknown)
                   (locality-analysis-summary-stages summary)
                   0))
    (when (getf evaluation :accepted)
      (incf (locality-analysis-summary-accepted-count summary)))
    (when (and record (numberp delta))
      (incf (locality-analysis-summary-official-sample-count summary))
      (update-locality-analysis-aggregate
       (locality-analysis-summary-official-overall summary) record delta)
      (dolist (event (locality-record-events record))
        (update-locality-analysis-aggregate
         (locality-table-aggregate
          (locality-analysis-summary-official-events summary) event)
         record delta))
      (update-locality-analysis-aggregate
       (locality-table-aggregate
        (locality-analysis-summary-top1-bins summary)
        (locality-distance-bin
         (locality-double (getf record :top1-hamming))))
       record delta)
      (update-locality-analysis-aggregate
       (locality-table-aggregate
        (locality-analysis-summary-ranking-bins summary)
        (locality-distance-bin
         (locality-double (getf record :ranking-distance-mean))))
       record delta)
      (push (list :generation (getf form :generation)
                  :top1-hamming
                    (locality-double (getf record :top1-hamming))
                  :teacher-rank-change
                    (locality-double
                     (getf record :teacher-rank-changed-rate))
                  :ranking-distance
                    (locality-double (getf record :ranking-distance-mean))
                  :delta (coerce delta 'double-float))
            (locality-analysis-summary-official-samples summary)))))

(defun process-behavioral-locality-form (summary form)
  "Accumulate one journal FORM into SUMMARY."
  (case (getf form :type)
    (:mutation-generation
     (incf (locality-analysis-summary-generation-form-count summary))
     (dolist (record (getf form :records))
       (process-locality-mutation-record summary record)))
    (:official-outcome
     (process-locality-official-outcome summary form)))
  summary)

(defun locality-analysis-correlation (left right)
  (let ((count (length left)))
    (when (and (> count 1) (= count (length right)))
      (let* ((left-mean (/ (reduce #'+ left) count))
             (right-mean (/ (reduce #'+ right) count))
             (numerator 0.0d0)
             (left-square 0.0d0)
             (right-square 0.0d0))
        (loop for x in left
              for y in right
              for left-delta = (- x left-mean)
              for right-delta = (- y right-mean)
              do (incf numerator (* left-delta right-delta))
                 (incf left-square (* left-delta left-delta))
                 (incf right-square (* right-delta right-delta)))
        (let ((denominator (sqrt (* left-square right-square))))
          (unless (zerop denominator)
            (/ numerator denominator)))))))

(defun locality-aggregate-mean (aggregate reader &key delta-p)
  (let ((count (if delta-p
                   (locality-analysis-aggregate-delta-count aggregate)
                   (locality-analysis-aggregate-count aggregate))))
    (if (plusp count)
        (/ (funcall reader aggregate) (coerce count 'double-float))
        0.0d0)))

(defun locality-aggregate-rate (numerator denominator)
  (if (plusp denominator)
      (/ (coerce numerator 'double-float)
         (coerce denominator 'double-float))
      0.0d0))

(defun locality-catastrophic-rate (aggregate threshold)
  (locality-aggregate-rate
   (gethash threshold
            (locality-analysis-aggregate-catastrophic-counts aggregate)
            0)
   (locality-analysis-aggregate-delta-count aggregate)))

(defun locality-sorted-aggregate-keys (table)
  (sort (loop for key being the hash-keys of table collect key)
        #'>
        :key (lambda (key)
               (locality-analysis-aggregate-count (gethash key table)))))

(defun locality-bin-label (key)
  (ecase key
    (:zero "0")
    (:up-to-05 "(0, 0.05]")
    (:05-to-20 "(0.05, 0.20]")
    (:20-to-50 "(0.20, 0.50]")
    (:over-50 "> 0.50")))

(defun locality-report-event-table (stream title table official-p)
  (format stream "~%## ~A~%~%" title)
  (if official-p
      (format stream
              "| Mutation event | N | Mean top-1 | Mean ranking distance | Mean paired delta | P(delta>0) | P(drop>10) | P(drop>25) | P(drop>50) | P(drop>100) |~%|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|~%")
      (format stream
              "| Mutation event | N | Mean top-1 | Mean teacher-rank change | Mean ranking distance | Mean top-8 overlap | Child off-support |~%|---|---:|---:|---:|---:|---:|---:|~%"))
  (dolist (event (locality-sorted-aggregate-keys table))
    (let* ((aggregate (gethash event table))
           (count (locality-analysis-aggregate-count aggregate)))
      (if official-p
          (format stream "| ~A | ~D | ~,4F | ~,4F | ~,4F | ~,3F | ~,3F | ~,3F | ~,3F | ~,3F |~%"
                  event count
                  (locality-aggregate-mean
                   aggregate #'locality-analysis-aggregate-top1-sum)
                  (locality-aggregate-mean
                   aggregate #'locality-analysis-aggregate-ranking-distance-sum)
                  (locality-aggregate-mean
                   aggregate #'locality-analysis-aggregate-delta-sum
                   :delta-p t)
                  (locality-aggregate-rate
                   (locality-analysis-aggregate-positive-count aggregate)
                   (locality-analysis-aggregate-delta-count aggregate))
                  (locality-catastrophic-rate aggregate 10.0d0)
                  (locality-catastrophic-rate aggregate 25.0d0)
                  (locality-catastrophic-rate aggregate 50.0d0)
                  (locality-catastrophic-rate aggregate 100.0d0))
          (format stream "| ~A | ~D | ~,4F | ~,4F | ~,4F | ~,4F | ~,4F |~%"
                  event count
                  (locality-aggregate-mean
                   aggregate #'locality-analysis-aggregate-top1-sum)
                  (locality-aggregate-mean
                   aggregate #'locality-analysis-aggregate-teacher-rank-sum)
                  (locality-aggregate-mean
                   aggregate #'locality-analysis-aggregate-ranking-distance-sum)
                  (locality-aggregate-mean
                   aggregate #'locality-analysis-aggregate-overlap-sum)
                  (locality-aggregate-mean
                   aggregate #'locality-analysis-aggregate-off-support-sum))))))

(defun locality-report-bin-table (stream title table)
  (format stream "~%## ~A~%~%" title)
  (format stream
          "| Distance bin | N | Mean paired delta | P(delta>0) | P(drop>10) | P(drop>25) | P(drop>50) | P(drop>100) |~%|---|---:|---:|---:|---:|---:|---:|---:|~%")
  (dolist (key '(:zero :up-to-05 :05-to-20 :20-to-50 :over-50))
    (let ((aggregate (gethash key table)))
      (when aggregate
        (format stream "| ~A | ~D | ~,4F | ~,3F | ~,3F | ~,3F | ~,3F | ~,3F |~%"
                (locality-bin-label key)
                (locality-analysis-aggregate-delta-count aggregate)
                (locality-aggregate-mean
                 aggregate #'locality-analysis-aggregate-delta-sum
                 :delta-p t)
                (locality-aggregate-rate
                 (locality-analysis-aggregate-positive-count aggregate)
                 (locality-analysis-aggregate-delta-count aggregate))
                (locality-catastrophic-rate aggregate 10.0d0)
                (locality-catastrophic-rate aggregate 25.0d0)
                (locality-catastrophic-rate aggregate 50.0d0)
                (locality-catastrophic-rate aggregate 100.0d0))))))

(defun locality-format-correlation (value)
  (if (numberp value) (format nil "~,4F" value) "undefined"))

(defun locality-samples-matching (samples predicate)
  "Return official SAMPLES whose records satisfy PREDICATE."
  (remove-if-not predicate samples))

(defun locality-sample-delta-mean (samples)
  "Return mean paired delta for SAMPLES, or zero for an empty group."
  (if samples
      (/ (reduce #'+ samples
                 :key (lambda (sample) (getf sample :delta)))
         (coerce (length samples) 'double-float))
      0.0d0))

(defun locality-report-stage-counts (stream stages)
  "Write deterministic official evaluation-stage counts."
  (format stream "~%## Official evaluation stages~%~%")
  (format stream "| Stage | N |~%|---|---:|~%")
  (dolist (stage
             (sort (loop for key being the hash-keys of stages collect key)
                   #'string< :key #'symbol-name))
    (format stream "| ~A | ~D |~%" stage (gethash stage stages))))

(defun write-behavioral-locality-report (summary stream source)
  (let* ((samples (locality-analysis-summary-official-samples summary))
         (deltas (mapcar (lambda (sample) (getf sample :delta)) samples))
         (top1 (mapcar (lambda (sample) (getf sample :top1-hamming)) samples))
         (rank-change
           (mapcar (lambda (sample) (getf sample :teacher-rank-change)) samples))
         (ranking
           (mapcar (lambda (sample) (getf sample :ranking-distance)) samples))
         (official (locality-analysis-summary-official-overall summary))
         (top1-changed
           (locality-samples-matching
            samples
            (lambda (sample) (plusp (getf sample :top1-hamming)))))
         (ranking-changed
           (locality-samples-matching
            samples
            (lambda (sample) (plusp (getf sample :ranking-distance)))))
         (top1-unchanged (set-difference samples top1-changed :test #'eq)))
    (format stream "# Behavioral Locality Analysis~%~%")
    (format stream "Source: `~A`~%~%" source)
    (format stream "- Mutation generations: ~D~%- Child mutation records: ~D~%- Official outcomes: ~D~%- Official parent/child samples: ~D~%- Accepted promotions represented: ~D~%"
            (locality-analysis-summary-generation-form-count summary)
            (locality-analysis-summary-mutation-record-count summary)
            (locality-analysis-summary-official-outcome-count summary)
            (locality-analysis-summary-official-sample-count summary)
            (locality-analysis-summary-accepted-count summary))
    (format stream "~%## Official parent-to-child summary~%~%")
    (format stream "- Mean paired return delta: ~,4F~%- Positive paired-delta rate: ~,3F~%- Top-1 changed samples: ~D / ~D (mean delta ~,4F)~%- Top-1 unchanged samples: ~D / ~D (mean delta ~,4F)~%- Ranking changed samples: ~D / ~D~%- P(drop > 10): ~,3F~%- P(drop > 25): ~,3F~%- P(drop > 50): ~,3F~%- P(drop > 100): ~,3F~%- Corr(top-1 Hamming, paired delta): ~A~%- Corr(teacher-rank change, paired delta): ~A~%- Corr(ranking distance, paired delta): ~A~%"
            (locality-aggregate-mean
             official #'locality-analysis-aggregate-delta-sum :delta-p t)
            (locality-aggregate-rate
             (locality-analysis-aggregate-positive-count official)
             (locality-analysis-aggregate-delta-count official))
            (length top1-changed) (length samples)
            (locality-sample-delta-mean top1-changed)
            (length top1-unchanged) (length samples)
            (locality-sample-delta-mean top1-unchanged)
            (length ranking-changed) (length samples)
            (locality-catastrophic-rate official 10.0d0)
            (locality-catastrophic-rate official 25.0d0)
            (locality-catastrophic-rate official 50.0d0)
            (locality-catastrophic-rate official 100.0d0)
            (locality-format-correlation
             (locality-analysis-correlation top1 deltas))
            (locality-format-correlation
             (locality-analysis-correlation rank-change deltas))
            (locality-format-correlation
             (locality-analysis-correlation ranking deltas)))
    (locality-report-stage-counts
     stream (locality-analysis-summary-stages summary))
    (locality-report-event-table
     stream "All reproduced children by mutation event"
     (locality-analysis-summary-mutation-events summary) nil)
    (locality-report-event-table
     stream "Official parent/child outcomes by mutation event"
     (locality-analysis-summary-official-events summary) t)
    (locality-report-bin-table
     stream "Official outcomes by top-1 Hamming distance"
     (locality-analysis-summary-top1-bins summary))
    (locality-report-bin-table
     stream "Official outcomes by ranking distance"
     (locality-analysis-summary-ranking-bins summary))
    (format stream "~%## Interpretation constraint~%~%Mutation-event rows overlap when one child received multiple events. They are conditional associations, not isolated operator effects. Correlations are descriptive and should not drive Phase 3 when the number of behavior-changing official samples is small. Phase 2 does not alter mutation or selection.~%")))

(defun analyze-behavioral-locality-journal (input &key output-path)
  "Incrementally analyze an append-only Phase-2 journal and write Markdown."
  (let ((summary (make-locality-analysis-summary))
        (eof (gensym "EOF")))
    (with-open-file (stream input :direction :input)
      (with-standard-io-syntax
        (loop for form = (read stream nil eof)
              until (eq form eof)
              do (process-behavioral-locality-form summary form))))
    (setf (locality-analysis-summary-official-samples summary)
          (nreverse (locality-analysis-summary-official-samples summary)))
    (if output-path
        (with-open-file (stream output-path
                                :direction :output
                                :if-exists :supersede
                                :if-does-not-exist :create)
          (write-behavioral-locality-report summary stream input))
        (write-behavioral-locality-report summary *standard-output* input))
    summary))
