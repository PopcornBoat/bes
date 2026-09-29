(in-package :cl-tpg)

;;; Phase 5F is search memory, not a weaker historical-best mechanism.  Its
;;; archive is detached from *TEAMS*: frozen anchors and heads live in private
;;; serialized checkpoints and only independently loaded offspring enter the
;;; ordinary population.  Existing mutation, grouped lexicase, DAgger, and the
;;; final Phase-5E promotion gate remain the selection authorities.

(defvar *phase5f-incumbent-hash* nil)

(defun phase5f-active-p ()
  (and *phase5f-near-miss-enabled*
       (official-guided-mode-p)
       *semantic-locality-control-enabled*
       *phase4-selection-enabled*))

(defun phase5f-reset-state ()
  "Reset run-local archive bookkeeping without deleting recoverable artifacts."
  (setf *phase5f-lineages* nil
        *phase5f-team-lineages* (make-hash-table :test #'eq)
        *phase5f-run-id* nil
        *phase5f-incumbent-hash* nil
        *phase5f-next-lineage-id* 0
        *phase5f-variation-root* nil
        *phase5f-variation-cursor* 0
        *phase5f-submission-count* 0
        *phase5f-lineage-submission-count* 0
        *phase5f-lineage-official-rollouts* 0
        *phase5f-nonlineage-official-rollouts* 0
        *phase5f-admission-count* 0
        *phase5f-duplicate-count* 0
        *phase5f-expiry-count* 0
        *phase5f-head-update-count* 0
        *online-staged-best-phase5f-lineage-id* nil
        *online-staged-best-phase5f-head-version* nil))

(defun phase5f-hash-string (string &optional (hash #xcbf29ce484222325))
  "Return a deterministic unsigned 64-bit FNV-1a hash for STRING."
  (loop for character across string
        do (setf hash
                 (ldb (byte 64 0)
                      (* (logxor hash (char-code character))
                         #x100000001b3)))
        finally (return hash)))

(defun phase5f-hash-object (object &optional (hash #xcbf29ce484222325))
  "Hash readable graph data deterministically without retaining a print string."
  (labels ((walk (value state)
             (cond
               ((null value) (phase5f-hash-string "N;" state))
               ((consp value)
                (walk (cdr value)
                      (walk (car value)
                            (phase5f-hash-string "C;" state))))
               ((stringp value)
                (phase5f-hash-string (format nil "S:~D:~A;"
                                             (length value) value)
                                     state))
               ((vectorp value)
                (loop with next = (phase5f-hash-string "V;" state)
                      for item across value
                      do (setf next (walk item next))
                      finally (return next)))
               ((symbolp value)
                (phase5f-hash-string
                 (format nil "Y:~A:~A;"
                         (and (symbol-package value)
                              (package-name (symbol-package value)))
                         (symbol-name value))
                 state))
               (t
                (phase5f-hash-string
                 (with-standard-io-syntax
                   (let ((*print-readably* t))
                     (format nil "A:~S;" value)))
                 state)))))
    (walk object hash)))

(defun phase5f-canonicalize-serialized-ids (data)
  "Replace allocation-dependent team/learner IDs with traversal-order IDs."
  (let ((teams (make-hash-table :test #'equal))
        (learners (make-hash-table :test #'equal))
        (next-team 0)
        (next-learner 0))
    (labels
        ((canonical-id (id kind)
           (cond
             ((eq kind :team)
              (or (gethash id teams)
                  (setf (gethash id teams)
                        (format nil "TEAM-~D" (incf next-team)))))
             ((eq kind :learner)
              (or (gethash id learners)
                  (setf (gethash id learners)
                        (format nil "LEARNER-~D" (incf next-learner)))))
             (t id)))
         (walk (value)
           (cond
             ((consp value)
              (if (and (keywordp (first value))
                       (member :id value :test #'eq))
                  (let ((kind
                          (cond
                            ((or (member :learners value :test #'eq)
                                 (member (getf value :type)
                                         '(:root :internal
                                           :already-serialized)
                                         :test #'eq))
                             :team)
                            ((member :program value :test #'eq)
                             :learner)
                            (t nil))))
                    (loop for (key item) on value by #'cddr
                          append
                          (list key
                                (if (eq key :id)
                                    (canonical-id item kind)
                                    (walk item)))))
                  (cons (walk (car value)) (walk (cdr value)))))
             ((vectorp value)
              (map 'vector #'walk value))
             (t value))))
      (walk data))))

(defun phase5f-team-graph-hash (team)
  "Return a stable content identity for TEAM's complete serialized graph."
  (format nil "~16,'0X"
          (phase5f-hash-object
           (phase5f-canonicalize-serialized-ids
            (serialize-team team (make-hash-table :test #'equal))))))

(defun phase5f-load-detached-team (path)
  "Load PATH without changing the process-wide last-loaded checkpoint globals."
  (let ((*loaded-best-team* *loaded-best-team*)
        (*loaded-best-fitness* *loaded-best-fitness*)
        (*loaded-checkpoint-metadata* *loaded-checkpoint-metadata*))
    (load-best-team path)))

(defun phase5f-archive-directory ()
  (checkpoint-path *checkpoint-directory* ".phase5f-near-miss/"))

(defun phase5f-archive-path (lineage-id kind &optional (version 0))
  (checkpoint-path
   (phase5f-archive-directory)
   (format nil "lineage-~D-~(~A~)-v~D.lisp" lineage-id kind version)))

(defun phase5f-write-detached-policy (team lineage-id kind version fitness)
  "Serialize an independent archive policy without inserting it into *TEAMS*."
  (let ((path (phase5f-archive-path lineage-id kind version)))
    ;; Archive payloads never recursively embed archive state.
    (let ((*phase5f-near-miss-enabled* nil))
      (write-official-guided-team-checkpoint
       team fitness *generation* path))
    path))

(defun phase5f-signature-fingerprint (team)
  "Return the versioned Top-1 and ranking behavior used only for archive dedup."
  (let ((signature (behavioral-policy-signature team)))
    (list :archive-revision *behavioral-probe-revision*
          :top1 (behavioral-signature-top1-fingerprint signature)
          :rankings
            (mapcar (lambda (entry)
                      (copy-tree (getf entry :ranking)))
                    signature))))

(defun phase5f-same-basin-p (left right)
  "Recognize exact behavior duplicates on the same versioned probe archive."
  (and (= (getf left :archive-revision -1)
          (getf right :archive-revision -2))
       (equal (getf left :top1) (getf right :top1))
       (equal (getf left :rankings) (getf right :rankings))))

(defun phase5f-lineage-by-id (lineage-id)
  (find lineage-id *phase5f-lineages*
        :key (lambda (record) (getf record :lineage-id))
        :test #'equal))

(defun phase5f-lineage-expiry-reason (record)
  (cond
    ((>= (getf record :age-generations 0)
         +phase5f-max-age-generations+)
     :generation-age)
    ((>= (getf record :reproduction-opportunities 0)
         +phase5f-max-reproduction-opportunities+)
     :reproduction-opportunities)
    ((>= (getf record :evaluated-descendants 0)
         +phase5f-max-evaluated-descendants+)
     :evaluated-descendants)
    (t nil)))

(defun phase5f-prune-expired-lineages ()
  "Expire bounded search memory; artifact files remain for audit/recovery."
  (let ((retained nil))
    (dolist (record *phase5f-lineages*)
      (let ((reason (phase5f-lineage-expiry-reason record)))
        (if reason
            (progn
              (incf *phase5f-expiry-count*)
              (emit-message
               (format nil
                       "Phase 5F lineage expired: id=~A reason=~A opportunities=~D evaluated=~D failures=~D."
                       (getf record :lineage-id) reason
                       (getf record :reproduction-opportunities 0)
                       (getf record :evaluated-descendants 0)
                       (getf record :failed-local-improvements 0))))
            (push record retained))))
    (setf *phase5f-lineages* (nreverse retained)))
  *phase5f-lineages*)

(defun phase5f-advance-generation ()
  "Advance persisted lineage age independently of the displayed generation."
  (dolist (record *phase5f-lineages*)
    (incf (getf record :age-generations 0)))
  (phase5f-prune-expired-lineages))

(defun phase5f-state-copy ()
  "Return small recoverable state; graphs remain separate serialized files."
  (when *phase5f-near-miss-enabled*
    (list :version 1
          :protocol +phase5f-near-miss-protocol+
          :run-id *phase5f-run-id*
          :incumbent-hash *phase5f-incumbent-hash*
          :next-lineage-id *phase5f-next-lineage-id*
          :variation-root *phase5f-variation-root*
          :variation-cursor *phase5f-variation-cursor*
          :submission-count *phase5f-submission-count*
          :lineage-submission-count *phase5f-lineage-submission-count*
          :lineage-official-rollouts *phase5f-lineage-official-rollouts*
          :nonlineage-official-rollouts *phase5f-nonlineage-official-rollouts*
          :admission-count *phase5f-admission-count*
          :duplicate-count *phase5f-duplicate-count*
          :expiry-count *phase5f-expiry-count*
          :head-update-count *phase5f-head-update-count*
          :lineages (copy-tree *phase5f-lineages*))))

(defun phase5f-validate-archive-record (record)
  "Reject missing or modified archive payloads instead of silently rebasing."
  (dolist (key '(:anchor-path :head-path))
    (let ((path (getf record key)))
      (unless (and path (probe-file path))
        (error "Phase 5F archive payload is missing: ~S" path))))
  (let* ((anchor (phase5f-load-detached-team (getf record :anchor-path)))
         (head (phase5f-load-detached-team (getf record :head-path))))
    (unless (string= (phase5f-team-graph-hash anchor)
                     (getf record :anchor-hash))
      (error "Phase 5F anchor hash mismatch for lineage ~A."
             (getf record :lineage-id)))
    (unless (string= (phase5f-team-graph-hash head)
                     (getf record :head-hash))
      (error "Phase 5F head hash mismatch for lineage ~A."
             (getf record :lineage-id))))
  record)

(defun phase5f-restore-state (state expected-incumbent-hash)
  "Restore bounded archive state only when run and incumbent identities match."
  (unless (and state
               (= (getf state :version 0) 1)
               (eq (getf state :protocol) +phase5f-near-miss-protocol+)
               (stringp (getf state :run-id))
               (equal (getf state :incumbent-hash)
                      expected-incumbent-hash))
    (error "Phase 5F state does not match the loaded incumbent: ~S" state))
  (dolist (record (getf state :lineages))
    (phase5f-validate-archive-record record))
  (setf *phase5f-run-id* (getf state :run-id)
        *phase5f-incumbent-hash* expected-incumbent-hash
        *phase5f-next-lineage-id* (getf state :next-lineage-id 0)
        *phase5f-variation-root* (getf state :variation-root)
        *phase5f-variation-cursor* (getf state :variation-cursor 0)
        *phase5f-submission-count* (getf state :submission-count 0)
        *phase5f-lineage-submission-count*
          (getf state :lineage-submission-count 0)
        *phase5f-lineage-official-rollouts*
          (getf state :lineage-official-rollouts 0)
        *phase5f-nonlineage-official-rollouts*
          (getf state :nonlineage-official-rollouts 0)
        *phase5f-admission-count* (getf state :admission-count 0)
        *phase5f-duplicate-count* (getf state :duplicate-count 0)
        *phase5f-expiry-count* (getf state :expiry-count 0)
        *phase5f-head-update-count* (getf state :head-update-count 0)
        *phase5f-lineages* (copy-tree (getf state :lineages))
        *phase5f-team-lineages* (make-hash-table :test #'eq))
  (phase5f-prune-expired-lineages)
  state)

(defun phase5f-initialize-state (search-seed incumbent)
  "Initialize a fresh Phase-5F treatment around INCUMBENT."
  (phase5f-reset-state)
  (when *phase5f-near-miss-enabled*
    (setf *phase5f-run-id*
            (format nil "phase5f-s~D-t~D" search-seed (get-universal-time))
          *phase5f-variation-root*
            (official-guided-derived-root search-seed 2609291)
          *phase5f-incumbent-hash*
            (and incumbent (phase5f-team-graph-hash incumbent))))
  *phase5f-run-id*)

(defun phase5f-near-miss-eligible-p (result)
  "Accept search memory only from a complete safe Stage-4 confidence failure."
  (let* ((record (getf result :evaluation-record))
         (audit (and record (getf record :tail-audit))))
    (and (eq (getf result :status) :complete)
         (not (getf result :accepted))
         (eq (getf record :stage) :promotion-stage-4)
         audit
         (plusp (getf audit :aggregate-paired-mean 0.0d0))
         (plusp (getf audit :long-paired-mean 0.0d0))
         (getf audit :cvar-pass)
         (getf audit :catastrophic-pass)
         (not (and (getf audit :aggregate-pass)
                   (getf audit :long-pass))))))

(defun phase5f-admit-near-miss (candidate-path result)
  "Store one eligible candidate as detached anchor/head search memory."
  (when (and (phase5f-active-p)
             (phase5f-near-miss-eligible-p result))
    (phase5f-prune-expired-lineages)
    (let* ((candidate (phase5f-load-detached-team candidate-path))
           (fingerprint (phase5f-signature-fingerprint candidate))
           (duplicate
             (find fingerprint *phase5f-lineages*
                   :key (lambda (entry) (getf entry :fingerprint))
                   :test #'phase5f-same-basin-p)))
      (cond
        (duplicate
         (incf *phase5f-duplicate-count*)
         (emit-message
          (format nil
                  "Phase 5F near miss not admitted: behavior duplicates lineage ~A."
                  (getf duplicate :lineage-id)))
         nil)
        ((>= (length *phase5f-lineages*) +phase5f-max-lineages+)
         (emit-message
          "Phase 5F near miss not admitted: detached archive is full.")
         nil)
        (t
         (let* ((lineage-id (incf *phase5f-next-lineage-id*))
                (graph-hash (phase5f-team-graph-hash candidate))
                (record (getf result :evaluation-record))
                (anchor-path
                  (phase5f-write-detached-policy
                   candidate lineage-id :anchor 0
                   (getf record :official-mean)))
                (head-copy (deep-copy-team-via-serialization candidate))
                (head-path
                  (phase5f-write-detached-policy
                   head-copy lineage-id :head 0
                   (getf record :official-mean)))
                (lineage
                  (list :lineage-id lineage-id
                        :incumbent-version *official-guided-incumbent-version*
                        :created-generation *generation*
                        :age-generations 0
                        :anchor-path (namestring anchor-path)
                        :anchor-hash graph-hash
                        :head-path (namestring head-path)
                        :head-hash (phase5f-team-graph-hash head-copy)
                        :head-version 0
                        :fingerprint fingerprint
                        :admission-evidence (copy-tree record)
                        :head-evidence nil
                        :reproduction-opportunities 0
                        :evaluated-descendants 0
                        :failed-local-improvements 0)))
           (push lineage *phase5f-lineages*)
           (incf *phase5f-admission-count*)
           (emit-message
            (format nil
                    "Phase 5F near miss admitted: lineage=~D archive=~D/~D aggregate-delta=~,4F long-delta=~,4F."
                    lineage-id (length *phase5f-lineages*)
                    +phase5f-max-lineages+
                    (getf (getf record :tail-audit)
                          :aggregate-paired-mean)
                    (getf (getf record :tail-audit)
                          :long-paired-mean)))
           lineage))))))

(defun phase5f-lineage-for-team (team)
  "Return TEAM's identity only while it targets the active lineage head."
  (let* ((identity
           (and *phase5f-team-lineages*
                (gethash team *phase5f-team-lineages*)))
         (record
           (and identity (phase5f-lineage-by-id (first identity)))))
    (and record
         (= (or (second identity) -1)
            (getf record :head-version -2))
         (copy-list identity))))

(defun phase5f-note-descendant (parent child)
  "Propagate search-memory identity without granting survivor protection."
  (let ((identity (phase5f-lineage-for-team parent)))
    (when identity
      (setf (gethash child *phase5f-team-lineages*) identity)))
  child)

(defun phase5f-prune-live-team-map ()
  (when *phase5f-team-lineages*
    (let ((retained (make-hash-table :test #'eq)))
      (dolist (team (root-teams))
        (let ((identity (phase5f-lineage-for-team team)))
          (when identity
            (setf (gethash team retained) identity))))
      (setf *phase5f-team-lineages* retained))))

(defun phase5f-lineage-submission-slot-p ()
  "Reserve no more than one of each five challenger slots for lineages."
  (= (mod (1+ *phase5f-submission-count*)
          +phase5f-lineage-submission-period+)
     0))

(defun phase5f-candidate-entry (sorted)
  "Choose within a bounded lineage/non-lineage slot without changing scores."
  (if (and *phase5f-lineages* (phase5f-lineage-submission-slot-p))
      (or (find-if (lambda (entry)
                     (phase5f-lineage-for-team (car entry)))
                   sorted)
          (find-if (lambda (entry)
                     (null (phase5f-lineage-for-team (car entry))))
                   sorted)
          (first sorted))
      (or (find-if (lambda (entry)
                     (null (phase5f-lineage-for-team (car entry))))
                   sorted)
          (first sorted))))

(defun phase5f-note-submission (lineage-id)
  (incf *phase5f-submission-count*)
  (when lineage-id
    (incf *phase5f-lineage-submission-count*)))

(defun phase5f-variation-integer ()
  (prog1
      (official-guided-mix64
       (+ *phase5f-variation-root* *phase5f-variation-cursor*))
    (incf *phase5f-variation-cursor*)))

(defun phase5f-lineage-offspring-slot-p ()
  (< (/ (coerce (logand (phase5f-variation-integer)
                         +official-guided-seed-payload-mask+)
                 'double-float)
        (coerce (1+ +official-guided-seed-payload-mask+) 'double-float))
     +phase5f-reproduction-quota+))

(defun phase5f-choose-lineage ()
  (when *phase5f-lineages*
    (nth (mod (phase5f-variation-integer) (length *phase5f-lineages*))
         *phase5f-lineages*)))

(defun phase5f-attempt-lineage-offspring ()
  "Create one isolated ordinary child from a detached head when its slot fires."
  (when (and (phase5f-active-p)
             (progn (phase5f-prune-expired-lineages)
                    *phase5f-lineages*)
             (phase5f-lineage-offspring-slot-p))
    (let* ((record (phase5f-choose-lineage))
           (parent (phase5f-load-detached-team (getf record :head-path)))
           (pristine-parent (deep-copy-team-via-serialization parent))
           (live-teams *teams*)
           (seed (phase5f-variation-integer))
           (raw-child nil)
           (behavioral-record nil)
           (child nil)
           (child-closure nil))
      (incf (getf record :reproduction-opportunities 0))
      ;; The dynamic team registry prevents native reference mutation from
      ;; reaching the live population.  Only the resulting independent closure
      ;; is installed after mutation completes.
      (let ((*teams* (copy-list (closure parent)))
            (*random-state* (sb-ext:seed-random-state seed)))
        (setf raw-child (reproduce-native-child parent)
              behavioral-record (behavioral-lineage-for-team raw-child)
              ;; CLONE-TEAM deliberately shares referenced internal teams.
              ;; Re-serialize here so the temporary detached parent contributes
              ;; no reference counts or graph objects to the live population.
              child (deep-copy-team-via-serialization raw-child)
              child-closure (closure child)))
      (setf *teams* live-teams)
      ;; Locality control records the temporary clone.  Transfer that evidence
      ;; to the independently serialized child and retain a pristine diagnostic
      ;; parent without making either object part of the detached archive.
      (when behavioral-record
        (remhash raw-child *behavioral-team-lineage*)
        (remhash raw-child *behavioral-team-parents*)
        (when *behavioral-signature-cache*
          (remhash raw-child *behavioral-signature-cache*))
        (setf (gethash child *behavioral-team-lineage*) behavioral-record
              (gethash child *behavioral-team-parents*) pristine-parent))
      (dolist (team child-closure)
        (pushnew team *teams* :test #'eq))
      (setf (gethash child *phase5f-team-lineages*)
              (list (getf record :lineage-id)
                    (getf record :head-version)))
      child)))

(defun phase5f-local-comparison-request (lineage-id head-version)
  "Return immutable paths/version for a candidate descended from LINEAGE-ID."
  (let ((record (phase5f-lineage-by-id lineage-id)))
    (when (and record
               (= head-version (getf record :head-version)))
      (list :lineage-id lineage-id
            :head-version head-version
            :head-path (getf record :head-path)
            :anchor-path (getf record :anchor-path)))))

(defun phase5f-tail-nonregression-p (candidate comparator horizon)
  (let ((left (official-guided-tail-statistics candidate horizon))
        (right (official-guided-tail-statistics comparator horizon)))
    (and (>= (getf left :cvar-10) (getf right :cvar-10))
         (<= (getf left :catastrophic-count)
             (getf right :catastrophic-count)))))

(defun phase5f-paired-margin-pass-p (candidate comparator standard-errors)
  (multiple-value-bind (mean se)
      (official-guided-comparison-statistics candidate comparator)
    (values (> mean (* standard-errors se)) mean se)))

(defun phase5f-run-local-comparison
       (candidate head anchor environment-name screen-seeds confirm-seeds
        lineage-id head-version)
  "Screen, then confirm a local head update on disjoint fresh seed blocks."
  (multiple-value-bind (screen-candidate screen-head)
      (official-guided-paired-rollouts
       candidate head environment-name screen-seeds)
    (multiple-value-bind (continue-p screen-delta screen-margin)
        (official-guided-continue-p screen-candidate screen-head)
      (unless continue-p
        (return-from phase5f-run-local-comparison
          (list :protocol +phase5f-near-miss-protocol+
                :stage :lineage-screen
                :accepted nil
                :lineage-id lineage-id
                :head-version head-version
                :screen-seeds (copy-list screen-seeds)
                :confirm-seeds nil
                :screen-delta screen-delta
                :screen-margin screen-margin
                :official-rollout-count (* 2 (length screen-seeds)))))
      (let ((candidate-by-horizon nil)
            (head-by-horizon nil)
            (anchor-by-horizon nil))
        (dolist (horizon +official-guided-final-audit-horizons+)
          (let ((environment
                  (official-guided-environment-for-horizon
                   environment-name horizon)))
            (multiple-value-bind (candidate-scores head-scores)
                (official-guided-paired-rollouts
                 candidate head environment confirm-seeds)
              (push (cons horizon candidate-scores) candidate-by-horizon)
              (push (cons horizon head-scores) head-by-horizon))
            (push
             (cons horizon
                   (loop for seed in confirm-seeds
                         collect (cl-gym:rollout anchor environment seed)))
             anchor-by-horizon)))
        (setf candidate-by-horizon (nreverse candidate-by-horizon)
              head-by-horizon (nreverse head-by-horizon)
              anchor-by-horizon (nreverse anchor-by-horizon))
        (let* ((candidate-aggregate
                 (official-guided-sum-return-lists
                  (mapcar #'cdr candidate-by-horizon)))
               (head-aggregate
                 (official-guided-sum-return-lists
                  (mapcar #'cdr head-by-horizon)))
               (anchor-aggregate
                 (official-guided-sum-return-lists
                  (mapcar #'cdr anchor-by-horizon)))
               (candidate-long (cdr (assoc 100 candidate-by-horizon)))
               (head-long (cdr (assoc 100 head-by-horizon)))
               (anchor-long (cdr (assoc 100 anchor-by-horizon))))
          (multiple-value-bind (aggregate-pass aggregate-delta aggregate-se)
              (phase5f-paired-margin-pass-p
               candidate-aggregate head-aggregate
               +phase5f-local-confirm-standard-errors+)
            (multiple-value-bind (long-pass long-delta long-se)
                (phase5f-paired-margin-pass-p
                 candidate-long head-long
                 +phase5f-local-confirm-standard-errors+)
              (multiple-value-bind
                    (anchor-aggregate-pass anchor-aggregate-delta unused-a-se)
                  (phase5f-paired-margin-pass-p
                   candidate-aggregate anchor-aggregate 0.0d0)
                (declare (ignore unused-a-se))
                (multiple-value-bind
                      (anchor-long-pass anchor-long-delta unused-l-se)
                    (phase5f-paired-margin-pass-p
                     candidate-long anchor-long 0.0d0)
                  (declare (ignore unused-l-se))
                  (let* ((head-tail-pass
                           (phase5f-tail-nonregression-p
                            candidate-long head-long 100))
                         (anchor-tail-pass
                           (phase5f-tail-nonregression-p
                            candidate-long anchor-long 100))
                         (accepted
                           (and aggregate-pass long-pass
                                anchor-aggregate-pass anchor-long-pass
                                head-tail-pass anchor-tail-pass)))
                    (list
                     :protocol +phase5f-near-miss-protocol+
                     :stage :lineage-confirm
                     :accepted accepted
                     :lineage-id lineage-id
                     :head-version head-version
                     :screen-seeds (copy-list screen-seeds)
                     :confirm-seeds (copy-list confirm-seeds)
                     :screen-delta screen-delta
                     :screen-margin screen-margin
                     :aggregate-paired-mean aggregate-delta
                     :aggregate-paired-se aggregate-se
                     :long-paired-mean long-delta
                     :long-paired-se long-se
                     :anchor-aggregate-paired-mean anchor-aggregate-delta
                     :anchor-long-paired-mean anchor-long-delta
                     :aggregate-pass aggregate-pass
                     :long-pass long-pass
                     :anchor-aggregate-pass anchor-aggregate-pass
                     :anchor-long-pass anchor-long-pass
                     :head-tail-pass head-tail-pass
                     :anchor-tail-pass anchor-tail-pass
                     :official-rollout-count
                       (+ (* 2 (length screen-seeds))
                          (* 9 (length confirm-seeds))))))))))))))

(defun phase5f-consume-local-result (candidate-path evaluation)
  "Update only the matching current head; stale or failed evidence cannot retry."
  (when evaluation
    (incf *phase5f-lineage-official-rollouts*
          (getf evaluation :official-rollout-count 0))
    (let* ((lineage-id (getf evaluation :lineage-id))
           (record (phase5f-lineage-by-id lineage-id)))
      (when record
        (incf (getf record :evaluated-descendants 0))
        (cond
          ((/= (getf evaluation :head-version -1)
               (getf record :head-version))
           (emit-message
            (format nil
                    "Phase 5F local result discarded as stale: lineage=~A evaluated-head=~A current-head=~A."
                    lineage-id (getf evaluation :head-version)
                    (getf record :head-version))))
          ((not (getf evaluation :accepted))
           (incf (getf record :failed-local-improvements 0)))
          (t
           (let* ((candidate (phase5f-load-detached-team candidate-path))
                  (new-version (1+ (getf record :head-version)))
                  (head-path
                    (phase5f-write-detached-policy
                     candidate lineage-id :head new-version
                     (getf evaluation :long-paired-mean)))
                  (head-hash (phase5f-team-graph-hash candidate)))
             (setf (getf record :head-version) new-version
                   (getf record :head-path) (namestring head-path)
                   (getf record :head-hash) head-hash
                   (getf record :head-evidence) (copy-tree evaluation))
             (incf *phase5f-head-update-count*)
             (emit-message
              (format nil
                      "Phase 5F lineage head updated: lineage=~A version=~D aggregate-delta=~,4F long-delta=~,4F."
                      lineage-id new-version
                      (getf evaluation :aggregate-paired-mean)
                      (getf evaluation :long-paired-mean))))))
        (phase5f-prune-expired-lineages)))
    evaluation))

(defun phase5f-note-global-evaluation-cost (lineage-id result)
  "Account completed global rollout work separately from local confirmation."
  (let* ((record (getf result :evaluation-record))
         (race (getf result :racing-record))
         (reference (getf result :reference-monitoring))
         (horizons (getf record :horizon-records))
         (episodes
           (+ (* 2 (getf race :episode-count 0))
              (if horizons
                  (loop for horizon-record in horizons
                        sum (* 2 (getf horizon-record :episode-count 0)))
                  (* 2 (getf record :episode-count 0)))
              (* 2 (getf reference :episode-count 0)))))
    (if lineage-id
        (incf *phase5f-lineage-official-rollouts* episodes)
        (incf *phase5f-nonlineage-official-rollouts* episodes))
    episodes))

(defun phase5f-clear-after-promotion (new-incumbent)
  "Rebase by expiring all old-incumbent search memory after true promotion."
  (when *phase5f-lineages*
    (incf *phase5f-expiry-count* (length *phase5f-lineages*))
    (emit-message
     (format nil
             "Phase 5F cleared ~D old-incumbent lineages after global promotion."
             (length *phase5f-lineages*))))
  (setf *phase5f-lineages* nil
        *phase5f-team-lineages* (make-hash-table :test #'eq)
        *phase5f-incumbent-hash* (phase5f-team-graph-hash new-incumbent)))

(defun phase5f-summary ()
  (let ((total (+ *phase5f-lineage-official-rollouts*
                  *phase5f-nonlineage-official-rollouts*)))
    (list :active-lineages (length *phase5f-lineages*)
          :admissions *phase5f-admission-count*
          :duplicates *phase5f-duplicate-count*
          :expired *phase5f-expiry-count*
          :head-updates *phase5f-head-update-count*
          :submissions *phase5f-submission-count*
          :lineage-submissions *phase5f-lineage-submission-count*
          :lineage-official-rollouts *phase5f-lineage-official-rollouts*
          :nonlineage-official-rollouts *phase5f-nonlineage-official-rollouts*
          :lineage-official-share
            (if (plusp total)
                (/ (coerce *phase5f-lineage-official-rollouts* 'double-float)
                   (coerce total 'double-float))
                0.0d0))))
