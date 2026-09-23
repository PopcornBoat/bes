(in-package :cl-tpg)

;;; Phase 2 observes semantic disruption only.  None of these helpers chooses
;;; parents, changes mutation probabilities, or consumes the search RNG.

(defun behavioral-locality-active-p ()
  "Return true when Phase-2 diagnostics should observe this search."
  (and *behavioral-locality-enabled* (official-guided-mode-p)))

(defun make-behavioral-locality-stratum-counts ()
  "Return a fresh serializable zero-count alist for every sampling stratum."
  (mapcar (lambda (stratum) (cons stratum 0))
          +behavioral-locality-sampling-strata+))

(defun note-mutation-event (event)
  "Record one applied mutation EVENT in the dynamically active child trace."
  (when (behavioral-locality-active-p)
    (push event *active-mutation-events*))
  event)

(defun reset-behavioral-locality-state ()
  "Reset run-local Phase-2 archives, caches, and lineage maps."
  (when (and *behavioral-locality-sample-process*
             (ignore-errors
               (uiop:process-alive-p *behavioral-locality-sample-process*)))
    (ignore-errors
      (uiop:terminate-process *behavioral-locality-sample-process*)))
  (setf *behavioral-probe-fixed-reference* nil
        *behavioral-probe-fixed-early* nil
        *behavioral-probe-archive* nil
        *behavioral-probe-revision* 0
        *behavioral-teacher-action-support*
          (make-hash-table :test #'equal)
        *behavioral-signature-cache* (make-hash-table :test #'eq)
        *behavioral-team-lineage* (make-hash-table :test #'eq)
        *behavioral-team-parents* (make-hash-table :test #'eq)
        *behavioral-generation-records* nil
        *behavioral-locality-sampling-candidates* nil
        *behavioral-locality-sample-cursor* 0
        *behavioral-locality-stratum-counts*
          (make-behavioral-locality-stratum-counts)
        *behavioral-locality-sample-process* nil
        *semantic-locality-control-age* 0
        *semantic-locality-control-generation-records* nil
        *behavioral-locality-sample-job* nil
        *online-staged-best-lineage* nil))

(defun behavioral-label-pair (label)
  "Return a canonical target/response pair from a semantic LABEL."
  (let ((target (first label))
        (response (second label)))
    (if (= target +global-target+)
        (list +global-target+ 0)
        (list target response))))

(defun make-behavioral-probe (dataset index source)
  "Copy one DATASET row into an independently owned Phase-2 probe plist."
  (let* ((label (aref (actions dataset) index))
         (ranking (aref (dataset-semantic-rankings dataset) index))
         (steps (dataset-steps dataset)))
    (list :source source
          :generation *generation*
          :step (and steps (aref steps index))
          :observation
            (copy-seq
             (policy-observation
              (aref (observations dataset) index)))
          :teacher-pair (behavioral-label-pair label)
          :teacher-ranking
            (copy-tree
             (or ranking (list (behavioral-label-pair label)))))))

(defun behavioral-even-indices (size count)
  "Return up to COUNT deterministic, evenly spaced indices below SIZE."
  (let ((actual (min size count)))
    (loop for slot fixnum below actual
          collect (floor (* slot size) actual))))

(defun behavioral-add-unique-probes (probes seen result limit)
  "Append unique PROBES to RESULT until LIMIT entries are present."
  (dolist (probe probes result)
    (when (>= (length result) limit)
      (return result))
    (let ((observation (getf probe :observation)))
      (unless (gethash observation seen)
        (setf (gethash observation seen) t)
        (setf result (nconc result (list probe)))))))

(defun behavioral-reference-probes (dataset count)
  "Return deterministic, distribution-spanning reference probes."
  (loop for index in (behavioral-even-indices (dataset-size dataset) count)
        collect (make-behavioral-probe dataset index :reference)))

(defun behavioral-early-probes (dataset count)
  "Return early policy-controlled states from distinct trace positions."
  (let ((steps (dataset-steps dataset))
        (result nil)
        (seen (make-hash-table :test #'equalp)))
    (when steps
      (dotimes (index (dataset-size dataset))
        (let ((step (aref steps index)))
          (when (and (integerp step)
                     (>= step (length +cage2-fixed-opening-rankings+))
                     (< step (+ (length +cage2-fixed-opening-rankings+) 10)))
            (setf result
                  (behavioral-add-unique-probes
                   (list (make-behavioral-probe dataset index :early-critical))
                   seen result count))
            (when (>= (length result) count)
              (return))))))
    result))

(defun behavioral-recent-probes (dataset count)
  "Return deterministic probes spanning the current generation trace."
  (loop for index in (behavioral-even-indices (dataset-size dataset) count)
        collect (make-behavioral-probe dataset index :recent-on-policy)))

(defun behavioral-ranking-pairs (team observation)
  "Return TEAM's ranked semantic pairs for one probe OBSERVATION."
  (mapcar #'semantic-action-category-pair
          (execute-team-semantic-ranked
           team observation +semantic-ranking-limit+)))

(defun behavioral-disagreement-probes (team dataset count)
  "Return current rows where TEAM changes top choice or omits the teacher."
  (let ((result nil)
        (seen (make-hash-table :test #'equalp)))
    (dotimes (index (dataset-size dataset))
      (let* ((probe (make-behavioral-probe dataset index :disagreement))
             (ranking
               (behavioral-ranking-pairs team (getf probe :observation)))
             (teacher (getf probe :teacher-pair)))
        (when (or (not (equal (first ranking) teacher))
                  (null (position teacher ranking :test #'equal)))
          (setf result
                (behavioral-add-unique-probes
                 (list probe) seen result count))))
      (when (>= (length result) count)
        (return)))
    result))

(defun rebuild-behavioral-teacher-support (dataset)
  "Rebuild the task-specific semantic support set from teacher rankings."
  (let ((support (make-hash-table :test #'equal)))
    (dotimes (index (dataset-size dataset))
      (dolist (pair (aref (dataset-semantic-rankings dataset) index))
        (setf (gethash (behavioral-label-pair pair) support) t)))
    (setf *behavioral-teacher-action-support* support)))

(defun update-behavioral-probe-archive (training-dataset)
  "Refresh the rolling half of the versioned Phase-2 probe archive.

The archive retains fixed teacher/reference and early-critical quarters while
refreshing recent on-policy and current disagreement quarters.  Selection is
deterministic and consumes no random state."
  (when (behavioral-locality-active-p)
    (unless *behavioral-teacher-action-support*
      (setf *behavioral-teacher-action-support*
            (make-hash-table :test #'equal)))
    (when (and *teacher-reference-dataset*
               (zerop (hash-table-count
                        *behavioral-teacher-action-support*)))
      (rebuild-behavioral-teacher-support *teacher-reference-dataset*))
    (unless *behavioral-probe-fixed-reference*
      (setf *behavioral-probe-fixed-reference*
            (behavioral-reference-probes
             *teacher-reference-dataset*
             +behavioral-probe-section-size+)))
    (unless *behavioral-probe-fixed-early*
      (setf *behavioral-probe-fixed-early*
            (behavioral-early-probes
             training-dataset +behavioral-probe-section-size+)))
    (let* ((behavior-team (teacher-dagger-behavior-team))
           (recent
             (behavioral-recent-probes
              training-dataset +behavioral-probe-section-size+))
           (disagreement
             (behavioral-disagreement-probes
              behavior-team training-dataset
              +behavioral-probe-section-size+))
           (seen (make-hash-table :test #'equalp))
           (archive nil))
      (dolist (section
                 (list *behavioral-probe-fixed-reference*
                       *behavioral-probe-fixed-early*
                       recent disagreement))
        (setf archive
              (behavioral-add-unique-probes
               section seen archive +behavioral-probe-archive-size+)))
      (setf *behavioral-probe-archive* archive
            *behavioral-signature-cache* (make-hash-table :test #'eq))
      (incf *behavioral-probe-revision*)
      (emit-message
       (format nil
               "Generation ~D behavioral probe archive: protocol=~A revision=~D probes=~D fixed-reference=~D fixed-early=~D recent=~D disagreement=~D."
               *generation* +behavioral-locality-protocol+
               *behavioral-probe-revision* (length archive)
               (length *behavioral-probe-fixed-reference*)
               (length *behavioral-probe-fixed-early*)
               (length recent) (length disagreement))))))

(defun serialize-behavioral-probe (probe)
  "Return a readably serializable, independently owned PROBE."
  (list :source (getf probe :source)
        :generation (getf probe :generation)
        :step (getf probe :step)
        :observation (coerce (getf probe :observation) 'list)
        :teacher-pair (copy-list (getf probe :teacher-pair))
        :teacher-ranking (copy-tree (getf probe :teacher-ranking))))

(defun deserialize-behavioral-probe (probe)
  "Restore one serialized PROBE with a specialized observation vector."
  (list :source (getf probe :source)
        :generation (getf probe :generation)
        :step (getf probe :step)
        :observation
          (make-array (length (getf probe :observation))
                      :element-type 'double-float
                      :initial-contents
                      (mapcar (lambda (value) (coerce value 'double-float))
                              (getf probe :observation)))
        :teacher-pair (copy-list (getf probe :teacher-pair))
        :teacher-ranking (copy-tree (getf probe :teacher-ranking))))

(defun behavioral-locality-state-copy ()
  "Return the serialization-safe Phase-2 probe state."
  (when (behavioral-locality-active-p)
    (list :version 3
          :protocol +behavioral-locality-protocol+
          :revision *behavioral-probe-revision*
          :control-protocol +semantic-locality-control-protocol+
          :control-age *semantic-locality-control-age*
          :sample-cursor *behavioral-locality-sample-cursor*
          :stratum-counts (copy-tree *behavioral-locality-stratum-counts*)
          :fixed-reference
            (mapcar #'serialize-behavioral-probe
                    *behavioral-probe-fixed-reference*)
          :fixed-early
            (mapcar #'serialize-behavioral-probe
                    *behavioral-probe-fixed-early*)
          :archive
            (mapcar #'serialize-behavioral-probe
                    *behavioral-probe-archive*))))

(defun restore-behavioral-locality-state (state)
  "Restore a validated Phase-2 probe STATE without restoring stale lineages."
  (when state
    (unless (and (member (getf state :version 0) '(1 2 3))
                 (eq (getf state :protocol) +behavioral-locality-protocol+))
      (error "Invalid behavioral-locality state: ~S" state))
    (when (and (= (getf state :version) 3)
               (not (member (getf state :control-protocol)
                            +semantic-locality-control-compatible-protocols+
                            :test #'eq)))
      (error "Invalid semantic-locality control state: ~S" state))
    (setf *behavioral-probe-revision* (getf state :revision 0)
          *behavioral-probe-fixed-reference*
            (mapcar #'deserialize-behavioral-probe
                    (getf state :fixed-reference))
          *behavioral-probe-fixed-early*
            (mapcar #'deserialize-behavioral-probe
                    (getf state :fixed-early))
          *behavioral-probe-archive*
            (mapcar #'deserialize-behavioral-probe
                    (getf state :archive))
          *behavioral-signature-cache* (make-hash-table :test #'eq)
          *behavioral-team-lineage* (make-hash-table :test #'eq)
          *behavioral-team-parents* (make-hash-table :test #'eq)
          *behavioral-generation-records* nil
          *behavioral-locality-sampling-candidates* nil
          *semantic-locality-control-age*
            (if (= (getf state :version) 3)
                (getf state :control-age 0)
                0)
          *semantic-locality-control-generation-records* nil
          *behavioral-locality-sample-cursor*
            (if (member (getf state :version) '(2 3))
                (getf state :sample-cursor 0)
                0)
          *behavioral-locality-stratum-counts*
            (if (member (getf state :version) '(2 3))
                (copy-tree (or (getf state :stratum-counts)
                               (make-behavioral-locality-stratum-counts)))
                (make-behavioral-locality-stratum-counts))
          *behavioral-locality-sample-process* nil
          *behavioral-locality-sample-job* nil)
    (when *teacher-reference-dataset*
      (rebuild-behavioral-teacher-support *teacher-reference-dataset*)))
  state)

(defun behavioral-policy-signature (team)
  "Return TEAM's semantic ranking signature on the current probe archive."
  (unless *behavioral-signature-cache*
    (setf *behavioral-signature-cache* (make-hash-table :test #'eq)))
  (multiple-value-bind (cached present-p)
      (gethash team *behavioral-signature-cache*)
    (if present-p
        cached
        (let ((signature
                (mapcar
                 (lambda (probe)
                   (let* ((ranking
                            (behavioral-ranking-pairs
                             team (getf probe :observation)))
                          (top1 (first ranking))
                          (teacher (getf probe :teacher-pair)))
                     (list :ranking ranking
                           :top1 top1
                           :teacher-rank
                             (or (position teacher ranking :test #'equal)
                                 +semantic-ranking-limit+)
                           :off-support
                             (and top1
                                  (not (gethash
                                        top1
                                        *behavioral-teacher-action-support*))))))
                 *behavioral-probe-archive*)))
          (setf (gethash team *behavioral-signature-cache*) signature)
          signature))))

(defun behavioral-ranking-overlap (left right)
  "Return fixed-top-k overlap for duplicate-free semantic rankings."
  (/ (coerce
      (count-if (lambda (pair) (member pair right :test #'equal)) left)
      'double-float)
     (coerce +semantic-ranking-limit+ 'double-float)))

(defun behavioral-pair-ranking-ndcg (predictions reference)
  "Return NDCG of pair PREDICTIONS under pair-ranking REFERENCE."
  (let* ((count (length reference))
         (relevance (make-hash-table :test #'equal))
         (dcg 0.0d0)
         (ideal 0.0d0))
    (loop for pair in reference
          for rank fixnum from 0
          do (setf (gethash pair relevance) (- count rank))
             (incf ideal
                   (/ (coerce (- count rank) 'double-float)
                      (log (+ rank 2.0d0) 2.0d0))))
    (loop for pair in predictions
          for rank fixnum from 0
          for value = (gethash pair relevance 0)
          when (> value 0)
            do (incf dcg
                     (/ (coerce value 'double-float)
                        (log (+ rank 2.0d0) 2.0d0))))
    (if (zerop ideal) 1.0d0 (/ dcg ideal))))

(defun behavioral-ranking-similarity (left right)
  "Return symmetric NDCG similarity between two semantic rankings."
  (* 0.5d0
     (+ (behavioral-pair-ranking-ndcg left right)
        (behavioral-pair-ranking-ndcg right left))))

(defun behavioral-distribution-alist (table)
  "Return deterministic (PAIR COUNT) entries from TABLE."
  (sort
   (loop for pair being the hash-keys of table using (hash-value count)
         collect (list (copy-list pair) count))
   #'string< :key (lambda (entry) (prin1-to-string (first entry)))))

(defun behavioral-event-counts (events)
  "Return deterministic (EVENT COUNT) entries for mutation EVENTS."
  (let ((counts (make-hash-table :test #'eq)))
    (dolist (event events)
      (incf (gethash event counts 0)))
    (sort
     (loop for event being the hash-keys of counts using (hash-value count)
           collect (list event count))
     #'string< :key (lambda (entry) (symbol-name (first entry))))))

(defun compare-behavioral-signatures
       (parent child mutation-events parent-team child-team)
  "Return one Phase-2 semantic disruption record for PARENT and CHILD."
  (let ((count (length parent))
        (top1-changed 0)
        (teacher-rank-changed 0)
        (teacher-rank-delta 0.0d0)
        (overlap 0.0d0)
        (ranking-similarity 0.0d0)
        (parent-off-support 0)
        (child-off-support 0)
        (parent-actions (make-hash-table :test #'equal))
        (child-actions (make-hash-table :test #'equal)))
    (loop for before in parent
          for after in child
          do (unless (equal (getf before :top1) (getf after :top1))
               (incf top1-changed))
             (unless (= (getf before :teacher-rank)
                        (getf after :teacher-rank))
               (incf teacher-rank-changed))
             (incf teacher-rank-delta
                   (abs (- (getf before :teacher-rank)
                           (getf after :teacher-rank))))
             (incf overlap
                   (behavioral-ranking-overlap
                    (getf before :ranking) (getf after :ranking)))
             (incf ranking-similarity
                   (behavioral-ranking-similarity
                    (getf before :ranking) (getf after :ranking)))
             (when (getf before :off-support)
               (incf parent-off-support))
             (when (getf after :off-support)
               (incf child-off-support))
             (incf (gethash (getf before :top1) parent-actions 0))
             (incf (gethash (getf after :top1) child-actions 0)))
    (let ((denominator (coerce (max 1 count) 'double-float)))
      (list :protocol +behavioral-locality-protocol+
            :created-generation *generation*
            :archive-revision *behavioral-probe-revision*
            :probe-count count
            :parent-team-id (team-id parent-team)
            :child-team-id (team-id child-team)
            :mutation-events (behavioral-event-counts mutation-events)
            :parent-complexity (policy-complexity-key parent-team)
            :child-complexity (policy-complexity-key child-team)
            :top1-changed top1-changed
            :top1-hamming (/ top1-changed denominator)
            :teacher-rank-changed teacher-rank-changed
            :teacher-rank-changed-rate
              (/ teacher-rank-changed denominator)
            :teacher-rank-mean-absolute-delta
              (/ teacher-rank-delta denominator)
            :top-k-overlap-mean (/ overlap denominator)
            :ranking-similarity-mean (/ ranking-similarity denominator)
            :ranking-distance-mean
              (- 1.0d0 (/ ranking-similarity denominator))
            :parent-off-support-rate
              (/ parent-off-support denominator)
            :child-off-support-rate
              (/ child-off-support denominator)
            :parent-top1-distribution
              (behavioral-distribution-alist parent-actions)
            :child-top1-distribution
              (behavioral-distribution-alist child-actions)))))

(defun behavioral-locality-sampling-stratum (record)
  "Classify RECORD for balanced, passive official evaluation."
  (let ((top1 (getf record :top1-hamming 0.0d0))
        (ranking (getf record :ranking-distance-mean 0.0d0)))
    (cond
      ((plusp top1)
       (cond ((<= top1 0.05d0) :small-top1)
             ((<= top1 0.20d0) :medium-top1)
             (t :large-top1)))
      ((plusp ranking) :ranking-only)
      (t :probe-neutral))))

(defun behavioral-locality-recorded-mutation-p (record)
  "Return true when RECORD contains at least one applied mutation event."
  (not (null (getf record :mutation-events))))

(defun behavioral-locality-stratum-count (stratum)
  "Return the number of submitted passive samples for STRATUM."
  (or (cdr (assoc stratum *behavioral-locality-stratum-counts*)) 0))

(defun note-behavioral-locality-stratum-sample (stratum)
  "Advance passive sample state after STRATUM is durably requested."
  (unless *behavioral-locality-stratum-counts*
    (setf *behavioral-locality-stratum-counts*
          (make-behavioral-locality-stratum-counts)))
  (let ((entry (assoc stratum *behavioral-locality-stratum-counts*)))
    (if entry
        (incf (cdr entry))
        (push (cons stratum 1) *behavioral-locality-stratum-counts*)))
  (incf *behavioral-locality-sample-cursor*))

(defun select-behavioral-locality-sampling-candidate ()
  "Choose a deterministic candidate from the least-sampled available stratum."
  (let ((available
          (remove-if-not
           (lambda (candidate)
             (behavioral-locality-recorded-mutation-p
              (getf candidate :record)))
           *behavioral-locality-sampling-candidates*)))
    (when available
      (let* ((available-strata
               (remove-duplicates
                (mapcar (lambda (candidate) (getf candidate :stratum))
                        available)
                :test #'eq))
             (stratum
               (first
                (stable-sort
                 (copy-list available-strata)
                 (lambda (left right)
                   (let ((left-count
                           (behavioral-locality-stratum-count left))
                         (right-count
                           (behavioral-locality-stratum-count right)))
                     (if (= left-count right-count)
                         (< (position left +behavioral-locality-sampling-strata+)
                            (position right +behavioral-locality-sampling-strata+))
                         (< left-count right-count)))))))
             (in-stratum
               (remove-if-not
                (lambda (candidate)
                  (eq (getf candidate :stratum) stratum))
                available)))
        (first
         (stable-sort
          (copy-list in-stratum) #'string<
          :key (lambda (candidate)
                 (team-id (getf candidate :child)))))))))

(defun behavioral-locality-sample-seeds
       (sample-cursor &optional (count +behavioral-locality-sample-episodes+))
  "Derive COUNT diagnostic seeds without consuming any Phase-1 stream."
  (unless (and (integerp *current-search-seed*)
               (integerp sample-cursor) (not (minusp sample-cursor)))
    (error "Cannot derive locality seeds from search seed ~S and cursor ~S."
           *current-search-seed* sample-cursor))
  (let ((root
          (official-guided-derived-root *current-search-seed* 181081))
        (start (* sample-cursor count)))
    (loop for offset below count
          collect
          (official-guided-seed-at :locality root (+ start offset)))))

(defun make-behavioral-mutation-record (parent child mutation-events)
  "Measure one PARENT/CHILD relationship without registering the CHILD."
  (when (and (behavioral-locality-active-p)
             *behavioral-probe-archive*)
    (compare-behavioral-signatures
     (behavioral-policy-signature parent)
     (behavioral-policy-signature child)
     mutation-events parent child)))

(defun register-behavioral-mutation-record (parent child record)
  "Retain an already measured RECORD for one accepted CHILD only."
  (when record
    (unless *behavioral-team-lineage*
      (setf *behavioral-team-lineage* (make-hash-table :test #'eq)))
    (unless *behavioral-team-parents*
      (setf *behavioral-team-parents* (make-hash-table :test #'eq)))
    (setf (gethash child *behavioral-team-lineage*) record
          (gethash child *behavioral-team-parents*) parent)
    (push record *behavioral-generation-records*)
    (push (list :parent parent
                :child child
                :record record
                :stratum (behavioral-locality-sampling-stratum record))
          *behavioral-locality-sampling-candidates*))
  record)

(defun record-behavioral-mutation (parent child mutation-events)
  "Measure and retain one reproduced PARENT/CHILD relationship."
  (register-behavioral-mutation-record
   parent child
   (make-behavioral-mutation-record parent child mutation-events)))

(defun semantic-locality-control-active-p ()
  "Return true when Phase-3 control can classify offspring safely."
  (and *semantic-locality-control-enabled*
       (behavioral-locality-active-p)
       *behavioral-probe-archive*))

(defun semantic-locality-control-stage (&optional
                                           (age *semantic-locality-control-age*))
  "Return the frozen Phase-3 schedule entry for control AGE."
  (or (find-if
       (lambda (stage)
         (let ((until (getf stage :until)))
           (or (null until) (< age until))))
       +semantic-locality-control-stages+)
      (error "No semantic-locality control stage covers age ~S." age)))

(defun choose-semantic-locality-control-tier (&optional
                                                 (stage
                                                   (semantic-locality-control-stage)))
  "Choose :LOCAL, :BOUNDED, or :EXPLORE from frozen STAGE weights."
  (let* ((local (getf stage :local-weight))
         (bounded (getf stage :bounded-weight))
         (roll (random 1.0d0)))
    (cond ((< roll local) :local)
          ((< roll (+ local bounded)) :bounded)
          (t :explore))))

(defun semantic-locality-tier-accepts-p (tier record)
  "Return true when TIER accepts an offspring behavior RECORD.

Probe-neutral mutations are not counted as useful local changes. They remain
eligible as the least-disruptive fallback after bounded retries."
  (let ((top1 (getf record :top1-hamming 0.0d0))
        (ranking (getf record :ranking-distance-mean 0.0d0)))
    (ecase tier
      (:local
       (and (or (plusp top1) (plusp ranking))
            (<= top1 0.05d0)
            (<= ranking 0.05d0)))
      (:bounded
       (and (or (plusp top1) (plusp ranking))
            (<= top1 0.20d0)
            (<= ranking 0.20d0)))
      (:explore t))))

(defun semantic-locality-fallback-score (record)
  "Return a scalar used only to choose the least-disruptive retry fallback."
  (+ (getf record :top1-hamming 0.0d0)
     (getf record :ranking-distance-mean 0.0d0)))

(defun semantic-locality-neutral-record-p (record)
  "Return true when RECORD changes neither Top-1 nor ranked behavior."
  (and (zerop (getf record :top1-hamming 0.0d0))
       (zerop (getf record :ranking-distance-mean 0.0d0))))

(defun semantic-locality-fallback-class (requested-tier record)
  "Return the ordered v2 fallback class for RECORD.

A LOCAL slot first escalates to a safe BOUNDED non-neutral mutation.  If none
was observed, a probe-neutral mutation remains safer than an unbounded jump.
Only a retry set containing neither bounded nor neutral behavior can fall back
to an exploratory mutation.  BOUNDED slots use the same neutral-before-large
rule; EXPLORE slots never reach fallback because their first attempt is valid."
  (cond
    ((and (eq requested-tier :local)
          (semantic-locality-tier-accepts-p :bounded record))
     0)
    ((semantic-locality-neutral-record-p record) 1)
    (t 2)))

(defun semantic-locality-fallback-better-p
       (requested-tier candidate incumbent)
  "Return true when CANDIDATE is a safer adaptive fallback than INCUMBENT."
  (or (null incumbent)
      (let ((candidate-class
              (semantic-locality-fallback-class requested-tier candidate))
            (incumbent-class
              (semantic-locality-fallback-class requested-tier incumbent)))
        (or (< candidate-class incumbent-class)
            (and (= candidate-class incumbent-class)
                 (< (semantic-locality-fallback-score candidate)
                    (semantic-locality-fallback-score incumbent)))))))

(defun semantic-locality-effective-tier (requested-tier record)
  "Describe the tier actually represented by accepted RECORD."
  (cond
    ((semantic-locality-tier-accepts-p requested-tier record)
     requested-tier)
    ((and (eq requested-tier :local)
          (semantic-locality-tier-accepts-p :bounded record))
     :bounded)
    ((semantic-locality-neutral-record-p record) :neutral)
    (t :explore)))

(defun discard-semantic-locality-candidate (team)
  "Delete rejected TEAM and remove its archive-signature cache entry."
  (when *behavioral-signature-cache*
    (remhash team *behavioral-signature-cache*))
  (delete-team team))

(defun mutate-team-with-semantic-locality-control (parent)
  "Create one child using adaptive bounded behavioral-locality resampling.

Every attempt uses the unchanged native TPG mutation pipeline. Most slots seek
local semantic consequences, while :EXPLORE slots accept the first mutation.
After the retry bound, a LOCAL slot prefers the least-disruptive BOUNDED
non-neutral attempt. Probe-neutral behavior is retained only when no such safe
escalation exists, and an unbounded exploratory fallback is used only when the
retry set contains neither. This preserves the scheduled explore quota without
turning every saturated local slot into a catastrophic large jump."
  (let* ((stage (semantic-locality-control-stage))
         (tier (choose-semantic-locality-control-tier stage))
         (best-child nil)
         (best-record nil)
         (attempted-strata nil))
    (loop for attempt from 1 to +semantic-locality-control-max-attempts+
          for child = (clone-team parent)
          do (let ((*active-mutation-events* nil))
               (mutate-team child)
               (let* ((events (nreverse *active-mutation-events*))
                      (record
                        (make-behavioral-mutation-record
                         parent child events))
                      (stratum
                        (behavioral-locality-sampling-stratum record)))
                 (push stratum attempted-strata)
                 (when (semantic-locality-tier-accepts-p tier record)
                   (when best-child
                     (discard-semantic-locality-candidate best-child))
                   (setf (getf record :control-protocol)
                           +semantic-locality-control-protocol+
                         (getf record :control-stage) (getf stage :name)
                         (getf record :control-age)
                           *semantic-locality-control-age*
                         (getf record :control-requested-tier) tier
                         (getf record :control-tier) tier
                         (getf record :control-effective-tier) tier
                         (getf record :control-escalated-p) nil
                         (getf record :control-attempts) attempt
                         (getf record :control-fallback-p) nil
                         (getf record :control-attempted-strata)
                           (nreverse attempted-strata))
                   (register-behavioral-mutation-record parent child record)
                   (push (copy-tree record)
                         *semantic-locality-control-generation-records*)
                   (return-from mutate-team-with-semantic-locality-control
                     child))
                 (if (semantic-locality-fallback-better-p
                      tier record best-record)
                     (progn
                       (when best-child
                         (discard-semantic-locality-candidate best-child))
                       (setf best-child child
                             best-record record))
                     (discard-semantic-locality-candidate child)))))
    (unless best-child
      (error "Phase-3 locality control produced no fallback child."))
    (setf (getf best-record :control-protocol)
            +semantic-locality-control-protocol+
          (getf best-record :control-stage) (getf stage :name)
          (getf best-record :control-age) *semantic-locality-control-age*
          (getf best-record :control-requested-tier) tier
          (getf best-record :control-tier) tier
          (getf best-record :control-effective-tier)
            (semantic-locality-effective-tier tier best-record)
          (getf best-record :control-escalated-p)
            (not (eq tier
                     (semantic-locality-effective-tier tier best-record)))
          (getf best-record :control-attempts)
            +semantic-locality-control-max-attempts+
          (getf best-record :control-fallback-p) t
          (getf best-record :control-attempted-strata)
            (nreverse attempted-strata))
    (register-behavioral-mutation-record parent best-child best-record)
    (push (copy-tree best-record)
          *semantic-locality-control-generation-records*)
    best-child))

(defun behavioral-lineage-for-team (team)
  "Return an independent copy of TEAM's direct parent/child record."
  (and *behavioral-team-lineage*
       (copy-tree (gethash team *behavioral-team-lineage*))))

(defun behavioral-parent-for-team (team)
  "Return TEAM's unmodified direct parent when it remains diagnostically owned."
  (and *behavioral-team-parents*
       (gethash team *behavioral-team-parents*)))

(defun prune-behavioral-team-lineage ()
  "Discard diagnostics for teams no longer present in the live population."
  (when *behavioral-team-lineage*
    (let ((retained (make-hash-table :test #'eq))
          (retained-parents (make-hash-table :test #'eq)))
      (dolist (team (root-teams))
        (multiple-value-bind (record present-p)
            (gethash team *behavioral-team-lineage*)
          (when present-p
            (setf (gethash team retained) record)
            (multiple-value-bind (parent parent-p)
                (gethash team *behavioral-team-parents*)
              (when parent-p
                (setf (gethash team retained-parents) parent))))))
      (setf *behavioral-team-lineage* retained
            *behavioral-team-parents* retained-parents))))

(defun behavioral-locality-log-path ()
  "Return the append-only Phase-2 record path for the active run."
  (and *checkpoint-directory*
       (checkpoint-path *checkpoint-directory*
                        "behavioral-locality-records.lisp")))

(defun append-behavioral-locality-form (form)
  "Append one readable FORM to the Phase-2 diagnostics journal."
  (let ((path (behavioral-locality-log-path)))
    (when path
      (ensure-directories-exist path)
      (with-open-file (stream path
                              :direction :output
                              :if-exists :append
                              :if-does-not-exist :create)
        (with-standard-io-syntax
          (let ((*print-circle* t)
                (*print-readably* t)
                (*print-pretty* nil))
            (write form :stream stream)
            (terpri stream)))))))

(defun behavioral-record-mean (records key)
  "Return the arithmetic mean of numeric KEY values in RECORDS."
  (if records
      (/ (reduce #'+ records :key (lambda (record) (getf record key 0.0d0)))
         (coerce (length records) 'double-float))
      0.0d0))

(defun behavioral-unique-count (values)
  "Return the number of EQUAL-distinct VALUES."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (value values)
      (setf (gethash value seen) t))
    (hash-table-count seen)))

(defun behavioral-signature-top1-fingerprint (signature)
  "Return the ordered Top-1 action vector represented by SIGNATURE."
  (mapcar (lambda (entry) (copy-list (getf entry :top1))) signature))

(defun behavioral-population-pairwise-hamming (signatures)
  "Return mean pairwise Top-1 Hamming distance over probe positions."
  (let* ((population-size (length signatures))
         (probe-count (if signatures (length (first signatures)) 0))
         (pair-count (/ (* population-size (1- population-size)) 2)))
    (if (or (< population-size 2) (zerop probe-count))
        0.0d0
        (/
         (loop for probe-index below probe-count
               sum
                 (let ((counts (make-hash-table :test #'equal)))
                   (dolist (signature signatures)
                     (incf (gethash
                            (getf (nth probe-index signature) :top1)
                            counts 0)))
                   (/ (coerce
                       (- pair-count
                          (loop for count being the hash-values of counts
                                sum (/ (* count (1- count)) 2)))
                       'double-float)
                      (coerce pair-count 'double-float))))
         (coerce probe-count 'double-float)))))

(defun behavioral-population-action-entropy (signatures)
  "Return mean normalized Top-1 entropy across probe positions."
  (let* ((population-size (length signatures))
         (probe-count (if signatures (length (first signatures)) 0))
         (maximum (and (> population-size 1)
                       (log (coerce population-size 'double-float) 2.0d0))))
    (if (or (zerop probe-count) (null maximum) (zerop maximum))
        0.0d0
        (/
         (loop for probe-index below probe-count
               sum
                 (let ((counts (make-hash-table :test #'equal)))
                   (dolist (signature signatures)
                     (incf (gethash
                            (getf (nth probe-index signature) :top1)
                            counts 0)))
                   (/
                    (-
                     (loop for count being the hash-values of counts
                           for probability =
                             (/ (coerce count 'double-float)
                                (coerce population-size 'double-float))
                           sum (* probability (log probability 2.0d0))))
                    maximum)))
         (coerce probe-count 'double-float)))))

(defun population-behavioral-diversity-record (&optional (stage :post-selection))
  "Measure population behavior without changing selection or mutation state."
  (let* ((teams (root-teams))
         (signatures (mapcar #'behavioral-policy-signature teams))
         (probe-count (if signatures (length (first signatures)) 0))
         (population-size (length signatures))
         (top1-fingerprints
           (mapcar #'behavioral-signature-top1-fingerprint signatures))
         (expressed (make-hash-table :test #'equal))
         (top1-counts (make-hash-table :test #'equal))
         (teacher-present 0)
         (teacher-covered-probes 0))
    (dolist (signature signatures)
      (dolist (entry signature)
        (dolist (pair (getf entry :ranking))
          (setf (gethash pair expressed) t))
        (incf (gethash (getf entry :top1) top1-counts 0))
        (when (< (getf entry :teacher-rank +semantic-ranking-limit+)
                 +semantic-ranking-limit+)
          (incf teacher-present))))
    (dotimes (probe-index probe-count)
      (when
          (some
           (lambda (signature)
             (< (getf (nth probe-index signature)
                      :teacher-rank +semantic-ranking-limit+)
                +semantic-ranking-limit+))
           signatures)
        (incf teacher-covered-probes)))
    (let ((dominant-pair nil)
          (dominant-count 0)
          (cell-count (* population-size probe-count)))
      (maphash
       (lambda (pair count)
         (when (> count dominant-count)
           (setf dominant-pair (copy-list pair)
                 dominant-count count)))
       top1-counts)
      (list :type :population-diversity-generation
            :protocol +semantic-locality-control-protocol+
            :generation *generation*
            :stage stage
            :population-size population-size
            :probe-count probe-count
            :unique-top1-fingerprints
              (behavioral-unique-count top1-fingerprints)
            :unique-ranking-fingerprints
              (behavioral-unique-count signatures)
            :mean-pairwise-top1-hamming
              (behavioral-population-pairwise-hamming signatures)
            :mean-normalized-top1-entropy
              (behavioral-population-action-entropy signatures)
            :teacher-top8-mean-coverage
              (if (plusp cell-count)
                  (/ (coerce teacher-present 'double-float)
                     (coerce cell-count 'double-float))
                  0.0d0)
            :teacher-top8-population-coverage
              (if (plusp probe-count)
                  (/ (coerce teacher-covered-probes 'double-float)
                     (coerce probe-count 'double-float))
                  0.0d0)
            :expressed-ranking-pairs (hash-table-count expressed)
            :dominant-top1-pair dominant-pair
            :dominant-top1-rate
              (if (plusp cell-count)
                  (/ (coerce dominant-count 'double-float)
                     (coerce cell-count 'double-float))
                  0.0d0)))))

(defun persist-population-behavioral-diversity
       (&optional (stage :post-selection))
  "Journal behavior-level population diversity for one generation."
  (when (and (behavioral-locality-active-p)
             *behavioral-probe-archive*
             (root-teams))
    (let ((record (population-behavioral-diversity-record stage)))
      (append-behavioral-locality-form record)
      (emit-message
       (format nil
               "Generation ~D population behavior: stage=~A unique-top1=~D unique-ranking=~D pairwise-hamming=~,4F entropy=~,4F teacher-top8(mean/union)=~,4F/~,4F expressed-pairs=~D dominant=~S rate=~,4F."
               *generation* stage
               (getf record :unique-top1-fingerprints)
               (getf record :unique-ranking-fingerprints)
               (getf record :mean-pairwise-top1-hamming)
               (getf record :mean-normalized-top1-entropy)
               (getf record :teacher-top8-mean-coverage)
               (getf record :teacher-top8-population-coverage)
               (getf record :expressed-ranking-pairs)
               (getf record :dominant-top1-pair)
               (getf record :dominant-top1-rate)))
      record)))

(defun persist-behavioral-generation-records ()
  "Persist and summarize this generation's parent/child measurements."
  (when (and (behavioral-locality-active-p)
             *behavioral-generation-records*)
    (let ((records (nreverse *behavioral-generation-records*)))
      (append-behavioral-locality-form
       (list :type :mutation-generation
             :protocol +behavioral-locality-protocol+
             :generation *generation*
             :archive-revision *behavioral-probe-revision*
             :records records))
      (emit-message
       (format nil
               "Generation ~D behavioral locality: children=~D top1-hamming=~,4F teacher-rank-change=~,4F ranking-distance=~,4F top8-overlap=~,4F child-off-support=~,4F."
               *generation* (length records)
               (behavioral-record-mean records :top1-hamming)
               (behavioral-record-mean records :teacher-rank-changed-rate)
               (behavioral-record-mean records :ranking-distance-mean)
               (behavioral-record-mean records :top-k-overlap-mean)
               (behavioral-record-mean records :child-off-support-rate)))
      (setf *behavioral-generation-records* nil))))

(defun semantic-locality-count-by (records key value)
  "Count RECORDS whose KEY is EQ to VALUE."
  (count value records :key (lambda (record) (getf record key)) :test #'eq))

(defun finish-semantic-locality-control-generation ()
  "Journal Phase-3 decisions and advance the persisted control schedule."
  (when (and *semantic-locality-control-enabled*
             (official-guided-mode-p))
    (let* ((records
             (nreverse *semantic-locality-control-generation-records*))
           (attempts
             (reduce #'+ records
                     :key (lambda (record)
                            (getf record :control-attempts 0))
                     :initial-value 0))
           (fallbacks
             (count-if (lambda (record)
                         (getf record :control-fallback-p))
                       records))
           (escalations
             (count-if (lambda (record)
                         (getf record :control-escalated-p))
                       records))
           (stage (semantic-locality-control-stage)))
      (when records
        (append-behavioral-locality-form
         (list :type :locality-control-generation
               :protocol +semantic-locality-control-protocol+
               :generation *generation*
               :control-age *semantic-locality-control-age*
               :stage (getf stage :name)
               :records records))
        (emit-message
         (format nil
                 "Generation ~D semantic locality control: stage=~A children=~D attempts=~D retries=~D fallbacks=~D escalations=~D requested(local/bounded/explore)=~D/~D/~D effective(local/bounded/explore/neutral)=~D/~D/~D/~D accepted(neutral/ranking/small/medium/large)=~D/~D/~D/~D/~D."
                 *generation* (getf stage :name) (length records) attempts
                 (- attempts (length records)) fallbacks escalations
                 (semantic-locality-count-by records :control-tier :local)
                 (semantic-locality-count-by records :control-tier :bounded)
                 (semantic-locality-count-by records :control-tier :explore)
                 (semantic-locality-count-by
                  records :control-effective-tier :local)
                 (semantic-locality-count-by
                  records :control-effective-tier :bounded)
                 (semantic-locality-count-by
                  records :control-effective-tier :explore)
                 (semantic-locality-count-by
                  records :control-effective-tier :neutral)
                 (count-if (lambda (record)
                             (eq (behavioral-locality-sampling-stratum record)
                                 :probe-neutral))
                           records)
                 (count-if (lambda (record)
                             (eq (behavioral-locality-sampling-stratum record)
                                 :ranking-only))
                           records)
                 (count-if (lambda (record)
                             (eq (behavioral-locality-sampling-stratum record)
                                 :small-top1))
                           records)
                 (count-if (lambda (record)
                             (eq (behavioral-locality-sampling-stratum record)
                                 :medium-top1))
                           records)
                 (count-if (lambda (record)
                             (eq (behavioral-locality-sampling-stratum record)
                                 :large-top1))
                           records))))
      (setf *semantic-locality-control-generation-records* nil)
      (incf *semantic-locality-control-age*))))

(defun persist-behavioral-official-outcome (generation lineage evaluation)
  "Link one staged challenger LINEAGE to its official EVALUATION record."
  (when (behavioral-locality-active-p)
    (append-behavioral-locality-form
     (list :type :official-outcome
           :protocol +behavioral-locality-protocol+
           :generation generation
           :lineage (copy-tree lineage)
           :evaluation (copy-tree evaluation)))))
