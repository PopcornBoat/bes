(in-package :cl-tpg)

;;; near-miss lineage is search memory, not a weaker historical-best mechanism.  Its
;;; archive is detached from *TEAMS*: frozen anchors and heads live in private
;;; serialized checkpoints and only independently loaded offspring enter the
;;; ordinary population.  Existing mutation, grouped lexicase, DAgger, and the
;;; final tail-aware promotion promotion gate remain the selection authorities.

(defvar *near-miss-incumbent-hash* nil)

(defun near-miss-active-p ()
  (and *near-miss-lineages-enabled*
       (official-guided-mode-p)
       *semantic-locality-control-enabled*
       *grouped-selection-enabled*))

(defun near-miss-reset-state ()
  "Reset run-local archive bookkeeping without deleting recoverable artifacts."
  (setf *near-miss-lineages* nil
        *near-miss-team-lineages* (make-hash-table :test #'eq)
        *near-miss-run-id* nil
        *near-miss-incumbent-hash* nil
        *near-miss-next-lineage-id* 0
        *near-miss-variation-root* nil
        *near-miss-variation-cursor* 0
        *near-miss-submission-count* 0
        *near-miss-lineage-submission-count* 0
        *near-miss-lineage-official-rollouts* 0
        *near-miss-nonlineage-official-rollouts* 0
        *near-miss-admission-count* 0
        *near-miss-duplicate-count* 0
        *near-miss-expiry-count* 0
        *near-miss-head-update-count* 0
        *online-staged-best-near-miss-lineage-id* nil
        *online-staged-best-near-miss-head-version* nil))

(defun near-miss-hash-string (string &optional (hash #xcbf29ce484222325))
  "Return a deterministic unsigned 64-bit FNV-1a hash for STRING."
  (loop for character across string
        do (setf hash
                 (ldb (byte 64 0)
                      (* (logxor hash (char-code character))
                         #x100000001b3)))
        finally (return hash)))

(defun near-miss-hash-object (object &optional (hash #xcbf29ce484222325))
  "Hash readable graph data deterministically without retaining a print string."
  (labels ((walk (value state)
             (cond
               ((null value) (near-miss-hash-string "N;" state))
               ((consp value)
                (walk (cdr value)
                      (walk (car value)
                            (near-miss-hash-string "C;" state))))
               ((stringp value)
                (near-miss-hash-string (format nil "S:~D:~A;"
                                             (length value) value)
                                     state))
               ((vectorp value)
                (loop with next = (near-miss-hash-string "V;" state)
                      for item across value
                      do (setf next (walk item next))
                      finally (return next)))
               ((symbolp value)
                (near-miss-hash-string
                 (format nil "Y:~A:~A;"
                         (and (symbol-package value)
                              (package-name (symbol-package value)))
                         (symbol-name value))
                 state))
               (t
                (near-miss-hash-string
                 (with-standard-io-syntax
                   (let ((*print-readably* t))
                     (format nil "A:~S;" value)))
                 state)))))
    (walk object hash)))

(defun near-miss-canonicalize-serialized-ids (data)
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

(defun near-miss-team-graph-hash (team)
  "Return a stable content identity for TEAM's complete serialized graph."
  (format nil "~16,'0X"
          (near-miss-hash-object
           (near-miss-canonicalize-serialized-ids
            (serialize-team team (make-hash-table :test #'equal))))))

(defun near-miss-load-detached-team (path)
  "Load PATH without changing the process-wide last-loaded checkpoint globals."
  (let ((*loaded-best-team* *loaded-best-team*)
        (*loaded-best-fitness* *loaded-best-fitness*)
        (*loaded-checkpoint-metadata* *loaded-checkpoint-metadata*))
    (load-best-team path)))

(defun near-miss-archive-directory ()
  (checkpoint-path *checkpoint-directory* ".near-miss-lineages/"))

(defun near-miss-archive-path (lineage-id kind &optional (version 0))
  (checkpoint-path
   (near-miss-archive-directory)
   (format nil "lineage-~D-~(~A~)-v~D.lisp" lineage-id kind version)))

(defun near-miss-write-detached-policy (team lineage-id kind version fitness)
  "Serialize an independent archive policy without inserting it into *TEAMS*."
  (let ((path (near-miss-archive-path lineage-id kind version)))
    ;; Archive payloads never recursively embed archive state.
    (let ((*near-miss-lineages-enabled* nil))
      (write-official-guided-team-checkpoint
       team fitness *generation* path))
    path))

(defun near-miss-signature-fingerprint (team)
  "Return the versioned Top-1 and ranking behavior used only for archive dedup."
  (let ((signature (behavioral-policy-signature team)))
    (list :archive-revision *behavioral-probe-revision*
          :top1 (behavioral-signature-top1-fingerprint signature)
          :rankings
            (mapcar (lambda (entry)
                      (copy-tree (getf entry :ranking)))
                    signature))))

(defun near-miss-same-basin-p (left right)
  "Recognize exact behavior duplicates on the same versioned probe archive."
  (and (= (getf left :archive-revision -1)
          (getf right :archive-revision -2))
       (equal (getf left :top1) (getf right :top1))
       (equal (getf left :rankings) (getf right :rankings))))

(defun near-miss-lineage-by-id (lineage-id)
  (find lineage-id *near-miss-lineages*
        :key (lambda (record) (getf record :lineage-id))
        :test #'equal))

(defun near-miss-lineage-expiry-reason (record)
  (cond
    ((>= (getf record :age-generations 0)
         +near-miss-max-age-generations+)
     :generation-age)
    ((>= (getf record :reproduction-opportunities 0)
         +near-miss-max-reproduction-opportunities+)
     :reproduction-opportunities)
    ((>= (getf record :evaluated-descendants 0)
         +near-miss-max-evaluated-descendants+)
     :evaluated-descendants)
    (t nil)))

(defun near-miss-prune-expired-lineages ()
  "Expire bounded search memory; artifact files remain for audit/recovery."
  (let ((retained nil))
    (dolist (record *near-miss-lineages*)
      (let ((reason (near-miss-lineage-expiry-reason record)))
        (if reason
            (progn
              (incf *near-miss-expiry-count*)
              (emit-message
               (format nil
                       "near-miss lineage lineage expired: id=~A reason=~A opportunities=~D evaluated=~D failures=~D."
                       (getf record :lineage-id) reason
                       (getf record :reproduction-opportunities 0)
                       (getf record :evaluated-descendants 0)
                       (getf record :failed-local-improvements 0))))
            (push record retained))))
    (setf *near-miss-lineages* (nreverse retained)))
  *near-miss-lineages*)

(defun near-miss-advance-generation ()
  "Advance persisted lineage age independently of the displayed generation."
  (dolist (record *near-miss-lineages*)
    (incf (getf record :age-generations 0)))
  (near-miss-prune-expired-lineages))

(defun near-miss-state-copy ()
  "Return small recoverable state; graphs remain separate serialized files."
  (when *near-miss-lineages-enabled*
    (list :version 1
          :protocol +near-miss-lineages-protocol+
          :run-id *near-miss-run-id*
          :incumbent-hash *near-miss-incumbent-hash*
          :next-lineage-id *near-miss-next-lineage-id*
          :variation-root *near-miss-variation-root*
          :variation-cursor *near-miss-variation-cursor*
          :submission-count *near-miss-submission-count*
          :lineage-submission-count *near-miss-lineage-submission-count*
          :lineage-official-rollouts *near-miss-lineage-official-rollouts*
          :nonlineage-official-rollouts *near-miss-nonlineage-official-rollouts*
          :admission-count *near-miss-admission-count*
          :duplicate-count *near-miss-duplicate-count*
          :expiry-count *near-miss-expiry-count*
          :head-update-count *near-miss-head-update-count*
          :lineages (copy-tree *near-miss-lineages*))))

(defun near-miss-validate-archive-record (record)
  "Reject missing or modified archive payloads instead of silently rebasing."
  (dolist (key '(:anchor-path :head-path))
    (let ((path (getf record key)))
      (unless (and path (probe-file path))
        (error "near-miss lineage archive payload is missing: ~S" path))))
  (let* ((anchor (near-miss-load-detached-team (getf record :anchor-path)))
         (head (near-miss-load-detached-team (getf record :head-path))))
    (unless (string= (near-miss-team-graph-hash anchor)
                     (getf record :anchor-hash))
      (error "near-miss lineage anchor hash mismatch for lineage ~A."
             (getf record :lineage-id)))
    (unless (string= (near-miss-team-graph-hash head)
                     (getf record :head-hash))
      (error "near-miss lineage head hash mismatch for lineage ~A."
             (getf record :lineage-id))))
  record)

(defun near-miss-restore-state (state expected-incumbent-hash)
  "Restore bounded archive state only when run and incumbent identities match."
  (unless (and state
               (= (getf state :version 0) 1)
               (eq (getf state :protocol) +near-miss-lineages-protocol+)
               (stringp (getf state :run-id))
               (equal (getf state :incumbent-hash)
                      expected-incumbent-hash))
    (error "near-miss lineage state does not match the loaded incumbent: ~S" state))
  (dolist (record (getf state :lineages))
    (near-miss-validate-archive-record record))
  (setf *near-miss-run-id* (getf state :run-id)
        *near-miss-incumbent-hash* expected-incumbent-hash
        *near-miss-next-lineage-id* (getf state :next-lineage-id 0)
        *near-miss-variation-root* (getf state :variation-root)
        *near-miss-variation-cursor* (getf state :variation-cursor 0)
        *near-miss-submission-count* (getf state :submission-count 0)
        *near-miss-lineage-submission-count*
          (getf state :lineage-submission-count 0)
        *near-miss-lineage-official-rollouts*
          (getf state :lineage-official-rollouts 0)
        *near-miss-nonlineage-official-rollouts*
          (getf state :nonlineage-official-rollouts 0)
        *near-miss-admission-count* (getf state :admission-count 0)
        *near-miss-duplicate-count* (getf state :duplicate-count 0)
        *near-miss-expiry-count* (getf state :expiry-count 0)
        *near-miss-head-update-count* (getf state :head-update-count 0)
        *near-miss-lineages* (copy-tree (getf state :lineages))
        *near-miss-team-lineages* (make-hash-table :test #'eq))
  (near-miss-prune-expired-lineages)
  state)

(defun near-miss-initialize-state (search-seed incumbent)
  "Initialize a fresh near-miss lineage treatment around INCUMBENT."
  (near-miss-reset-state)
  (when *near-miss-lineages-enabled*
    (setf *near-miss-run-id*
            (format nil "near-miss-s~D-t~D" search-seed (get-universal-time))
          *near-miss-variation-root*
            (official-guided-derived-root search-seed 2609291)
          *near-miss-incumbent-hash*
            (and incumbent (near-miss-team-graph-hash incumbent))))
  *near-miss-run-id*)

(defun near-miss-lineages-eligible-p (result)
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

(defun near-miss-admit-near-miss (candidate-path result)
  "Store one eligible candidate as detached anchor/head search memory."
  (when (and (near-miss-active-p)
             (near-miss-lineages-eligible-p result))
    (near-miss-prune-expired-lineages)
    (let* ((candidate (near-miss-load-detached-team candidate-path))
           (fingerprint (near-miss-signature-fingerprint candidate))
           (duplicate
             (find fingerprint *near-miss-lineages*
                   :key (lambda (entry) (getf entry :fingerprint))
                   :test #'near-miss-same-basin-p)))
      (cond
        (duplicate
         (incf *near-miss-duplicate-count*)
         (emit-message
          (format nil
                  "near-miss lineage near miss not admitted: behavior duplicates lineage ~A."
                  (getf duplicate :lineage-id)))
         nil)
        ((>= (length *near-miss-lineages*) +near-miss-max-lineages+)
         (emit-message
          "near-miss lineage near miss not admitted: detached archive is full.")
         nil)
        (t
         (let* ((lineage-id (incf *near-miss-next-lineage-id*))
                (graph-hash (near-miss-team-graph-hash candidate))
                (record (getf result :evaluation-record))
                (anchor-path
                  (near-miss-write-detached-policy
                   candidate lineage-id :anchor 0
                   (getf record :official-mean)))
                (head-copy (deep-copy-team-via-serialization candidate))
                (head-path
                  (near-miss-write-detached-policy
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
                        :head-hash (near-miss-team-graph-hash head-copy)
                        :head-version 0
                        :fingerprint fingerprint
                        :admission-evidence (copy-tree record)
                        :head-evidence nil
                        :reproduction-opportunities 0
                        :evaluated-descendants 0
                        :failed-local-improvements 0)))
           (push lineage *near-miss-lineages*)
           (incf *near-miss-admission-count*)
           (emit-message
            (format nil
                    "near-miss lineage near miss admitted: lineage=~D archive=~D/~D aggregate-delta=~,4F long-delta=~,4F."
                    lineage-id (length *near-miss-lineages*)
                    +near-miss-max-lineages+
                    (getf (getf record :tail-audit)
                          :aggregate-paired-mean)
                    (getf (getf record :tail-audit)
                          :long-paired-mean)))
           lineage))))))

(defun near-miss-lineage-for-team (team)
  "Return TEAM's identity only while it targets the active lineage head."
  (let* ((identity
           (and *near-miss-team-lineages*
                (gethash team *near-miss-team-lineages*)))
         (record
           (and identity (near-miss-lineage-by-id (first identity)))))
    (and record
         (= (or (second identity) -1)
            (getf record :head-version -2))
         (copy-list identity))))

(defun near-miss-note-descendant (parent child)
  "Propagate search-memory identity without granting survivor protection."
  (let ((identity (near-miss-lineage-for-team parent)))
    (when identity
      (setf (gethash child *near-miss-team-lineages*) identity)))
  child)

(defun near-miss-prune-live-team-map ()
  (when *near-miss-team-lineages*
    (let ((retained (make-hash-table :test #'eq)))
      (dolist (team (root-teams))
        (let ((identity (near-miss-lineage-for-team team)))
          (when identity
            (setf (gethash team retained) identity))))
      (setf *near-miss-team-lineages* retained))))

(defun near-miss-lineage-submission-slot-p ()
  "Reserve no more than one of each five challenger slots for lineages."
  (= (mod (1+ *near-miss-submission-count*)
          +near-miss-lineage-submission-period+)
     0))

(defun near-miss-candidate-entry (sorted)
  "Choose within a bounded lineage/non-lineage slot without changing scores."
  (if (and *near-miss-lineages* (near-miss-lineage-submission-slot-p))
      (or (find-if (lambda (entry)
                     (near-miss-lineage-for-team (car entry)))
                   sorted)
          (find-if (lambda (entry)
                     (null (near-miss-lineage-for-team (car entry))))
                   sorted)
          (first sorted))
      (or (find-if (lambda (entry)
                     (null (near-miss-lineage-for-team (car entry))))
                   sorted)
          (first sorted))))

(defun near-miss-note-submission (lineage-id)
  (incf *near-miss-submission-count*)
  (when lineage-id
    (incf *near-miss-lineage-submission-count*)))

(defun near-miss-variation-integer ()
  (prog1
      (official-guided-mix64
       (+ *near-miss-variation-root* *near-miss-variation-cursor*))
    (incf *near-miss-variation-cursor*)))

(defun near-miss-lineage-offspring-slot-p ()
  (< (/ (coerce (logand (near-miss-variation-integer)
                         +official-guided-seed-payload-mask+)
                 'double-float)
        (coerce (1+ +official-guided-seed-payload-mask+) 'double-float))
     +near-miss-reproduction-quota+))

(defun near-miss-choose-lineage ()
  (when *near-miss-lineages*
    (nth (mod (near-miss-variation-integer) (length *near-miss-lineages*))
         *near-miss-lineages*)))

(defun near-miss-attempt-lineage-offspring ()
  "Create one isolated ordinary child from a detached head when its slot fires."
  (when (and (near-miss-active-p)
             (progn (near-miss-prune-expired-lineages)
                    *near-miss-lineages*)
             (near-miss-lineage-offspring-slot-p))
    (let* ((record (near-miss-choose-lineage))
           (parent (near-miss-load-detached-team (getf record :head-path)))
           (pristine-parent (deep-copy-team-via-serialization parent))
           (live-teams *teams*)
           (seed (near-miss-variation-integer))
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
      (setf (gethash child *near-miss-team-lineages*)
              (list (getf record :lineage-id)
                    (getf record :head-version)))
      child)))

(defun near-miss-local-comparison-request (lineage-id head-version)
  "Return immutable paths/version for a candidate descended from LINEAGE-ID."
  (let ((record (near-miss-lineage-by-id lineage-id)))
    (when (and record
               (= head-version (getf record :head-version)))
      (list :lineage-id lineage-id
            :head-version head-version
            :head-path (getf record :head-path)
            :anchor-path (getf record :anchor-path)))))

(defun near-miss-tail-nonregression-p (candidate comparator horizon)
  (let ((left (official-guided-tail-statistics candidate horizon))
        (right (official-guided-tail-statistics comparator horizon)))
    (and (>= (getf left :cvar-10) (getf right :cvar-10))
         (<= (getf left :catastrophic-count)
             (getf right :catastrophic-count)))))

(defun near-miss-paired-margin-pass-p (candidate comparator standard-errors)
  (multiple-value-bind (mean se)
      (official-guided-comparison-statistics candidate comparator)
    (values (> mean (* standard-errors se)) mean se)))

(defun near-miss-run-local-comparison
       (candidate head anchor environment-name screen-seeds confirm-seeds
        lineage-id head-version)
  "Screen, then confirm a local head update on disjoint fresh seed blocks."
  (multiple-value-bind (screen-candidate screen-head)
      (official-guided-paired-rollouts
       candidate head environment-name screen-seeds)
    (multiple-value-bind (continue-p screen-delta screen-margin)
        (official-guided-continue-p screen-candidate screen-head)
      (unless continue-p
        (return-from near-miss-run-local-comparison
          (list :protocol +near-miss-lineages-protocol+
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
              (near-miss-paired-margin-pass-p
               candidate-aggregate head-aggregate
               +near-miss-local-confirm-standard-errors+)
            (multiple-value-bind (long-pass long-delta long-se)
                (near-miss-paired-margin-pass-p
                 candidate-long head-long
                 +near-miss-local-confirm-standard-errors+)
              (multiple-value-bind
                    (anchor-aggregate-pass anchor-aggregate-delta unused-a-se)
                  (near-miss-paired-margin-pass-p
                   candidate-aggregate anchor-aggregate 0.0d0)
                (declare (ignore unused-a-se))
                (multiple-value-bind
                      (anchor-long-pass anchor-long-delta unused-l-se)
                    (near-miss-paired-margin-pass-p
                     candidate-long anchor-long 0.0d0)
                  (declare (ignore unused-l-se))
                  (let* ((head-tail-pass
                           (near-miss-tail-nonregression-p
                            candidate-long head-long 100))
                         (anchor-tail-pass
                           (near-miss-tail-nonregression-p
                            candidate-long anchor-long 100))
                         (accepted
                           (and aggregate-pass long-pass
                                anchor-aggregate-pass anchor-long-pass
                                head-tail-pass anchor-tail-pass)))
                    (list
                     :protocol +near-miss-lineages-protocol+
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

(defun near-miss-consume-local-result (candidate-path evaluation)
  "Update only the matching current head; stale or failed evidence cannot retry."
  (when evaluation
    (incf *near-miss-lineage-official-rollouts*
          (getf evaluation :official-rollout-count 0))
    (let* ((lineage-id (getf evaluation :lineage-id))
           (record (near-miss-lineage-by-id lineage-id)))
      (when record
        (incf (getf record :evaluated-descendants 0))
        (cond
          ((/= (getf evaluation :head-version -1)
               (getf record :head-version))
           (emit-message
            (format nil
                    "near-miss lineage local result discarded as stale: lineage=~A evaluated-head=~A current-head=~A."
                    lineage-id (getf evaluation :head-version)
                    (getf record :head-version))))
          ((not (getf evaluation :accepted))
           (incf (getf record :failed-local-improvements 0)))
          (t
           (let* ((candidate (near-miss-load-detached-team candidate-path))
                  (new-version (1+ (getf record :head-version)))
                  (head-path
                    (near-miss-write-detached-policy
                     candidate lineage-id :head new-version
                     (getf evaluation :long-paired-mean)))
                  (head-hash (near-miss-team-graph-hash candidate)))
             (setf (getf record :head-version) new-version
                   (getf record :head-path) (namestring head-path)
                   (getf record :head-hash) head-hash
                   (getf record :head-evidence) (copy-tree evaluation))
             (incf *near-miss-head-update-count*)
             (emit-message
              (format nil
                      "near-miss lineage lineage head updated: lineage=~A version=~D aggregate-delta=~,4F long-delta=~,4F."
                      lineage-id new-version
                      (getf evaluation :aggregate-paired-mean)
                      (getf evaluation :long-paired-mean))))))
        (near-miss-prune-expired-lineages)))
    evaluation))

(defun near-miss-note-global-evaluation-cost (lineage-id result)
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
        (incf *near-miss-lineage-official-rollouts* episodes)
        (incf *near-miss-nonlineage-official-rollouts* episodes))
    episodes))

(defun near-miss-clear-after-promotion (new-incumbent)
  "Rebase by expiring all old-incumbent search memory after true promotion."
  (when *near-miss-lineages*
    (incf *near-miss-expiry-count* (length *near-miss-lineages*))
    (emit-message
     (format nil
             "near-miss lineage cleared ~D old-incumbent lineages after global promotion."
             (length *near-miss-lineages*))))
  (setf *near-miss-lineages* nil
        *near-miss-team-lineages* (make-hash-table :test #'eq)
        *near-miss-incumbent-hash* (near-miss-team-graph-hash new-incumbent)))

(defun near-miss-summary ()
  (let ((total (+ *near-miss-lineage-official-rollouts*
                  *near-miss-nonlineage-official-rollouts*)))
    (list :active-lineages (length *near-miss-lineages*)
          :admissions *near-miss-admission-count*
          :duplicates *near-miss-duplicate-count*
          :expired *near-miss-expiry-count*
          :head-updates *near-miss-head-update-count*
          :submissions *near-miss-submission-count*
          :lineage-submissions *near-miss-lineage-submission-count*
          :lineage-official-rollouts *near-miss-lineage-official-rollouts*
          :nonlineage-official-rollouts *near-miss-nonlineage-official-rollouts*
          :lineage-official-share
            (if (plusp total)
                (/ (coerce *near-miss-lineage-official-rollouts* 'double-float)
                   (coerce total 'double-float))
                0.0d0))))
