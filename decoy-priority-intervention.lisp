(in-package :cl-tpg)

(defconstant +bline-decoy-priority-intervention-protocol+
  :bline-decoy-priority-intervention-v1
  "Version tag for the causal E0 Analyse proxy-bidder intervention.")

(defparameter +bline-e0-analyse-proxy-signatures+
  '((:effective-count 2 :observation-indices (18 33))
    (:effective-count 1 :observation-indices (27)))
  "Effective-code signatures of the two v13 E0 Analyse proxy bidders.

The signatures are a second guard on the audited checkpoint identities.  The
intervention is a checkpoint-specific causal experiment, not a deployment-time
heuristic or a general mutation operator.")

(defparameter +bline-e0-analyse-proxy-learner-ids+
  '("LEARNER-0-170" "LEARNER-0-449")
  "Serialized v13 learner identities established by the 1000-episode audit.")

(defparameter +bline-e0-analyse-pattern+ '(1 0 0 0)
  "Exact raw Enterprise0 pattern that supports the heuristic Analyse rule.")

(defparameter +bline-e0-raw-observation-indices+ '(4 5 6 7)
  "Zero-based raw observation indices for Enterprise0.")

(defun decoy-priority-instruction
       (destination opcode source-1-type source-1-value
        source-2-type source-2-value)
  "Return one deterministic binary intervention instruction."
  (%make-instruction
   :dest destination :op opcode :arity 2
   :src1-type source-1-type
   :src1-val (coerce source-1-value 'double-float)
   :src2-type source-2-type
   :src2-val (coerce source-2-value 'double-float)))

(defun decoy-priority-append-instruction (program instruction)
  (vector-push-extend instruction (program-instructions program))
  program)

(defun decoy-priority-literal-instruction
       (destination observation-index expected)
  "Compile one binary observation literal into DESTINATION."
  (ecase expected
    (0 (decoy-priority-instruction
        destination :sub :const 1.0d0 :obs observation-index))
    (1 (decoy-priority-instruction
        destination :add :obs observation-index :const 0.0d0))))

(defun append-exact-pattern-demotion-gate
       (program observation-indices pattern &key (penalty 1000.0d0))
  "Keep PROGRAM's bid on PATTERN and demote it by PENALTY otherwise.

The original program executes unchanged.  Appended instructions form the
exact binary conjunction in scratch register 1 and add zero to R0 when it is
true or -PENALTY when it is false.  This changes priority only; it does not
create an action, alter graph traversal, or inspect Controller Decoy state."
  (unless (and (= (length observation-indices) (length pattern))
               (plusp (length pattern))
               (every (lambda (value) (member value '(0 1))) pattern))
    (error "Invalid binary pattern gate: indices=~S pattern=~S."
           observation-indices pattern))
  (let ((match-register 1)
        (scratch-register 2))
    (decoy-priority-append-instruction
     program
     (decoy-priority-literal-instruction
      match-register (first observation-indices) (first pattern)))
    (loop for observation-index in (rest observation-indices)
          for expected in (rest pattern)
          do (decoy-priority-append-instruction
              program
              (decoy-priority-literal-instruction
               scratch-register observation-index expected))
             (decoy-priority-append-instruction
              program
              (decoy-priority-instruction
               match-register :mul :reg match-register
               :reg scratch-register)))
    (decoy-priority-append-instruction
     program
     (decoy-priority-instruction
      scratch-register :sub :reg match-register :const 1.0d0))
    (decoy-priority-append-instruction
     program
     (decoy-priority-instruction
      scratch-register :mul :reg scratch-register :const penalty))
    (decoy-priority-append-instruction
     program
     (decoy-priority-instruction
      +bid-register+ :add :reg +bid-register+ :reg scratch-register)))
  program)

(defun decoy-priority-terminal-pair (learner)
  "Return LEARNER's direct Semantic-36 pair, or NIL."
  (let* ((action (learner-action learner))
         (payload (and (eq (action-type action) :atomic)
                       (action-action action))))
    (when (target-response-36-action-p payload)
      (list (target-response-36-action-target payload)
            (target-response-36-action-response payload)))))

(defun bline-e0-analyse-proxy-signature (learner)
  "Return LEARNER's matching v13 proxy signature, or NIL."
  (when (equal (decoy-priority-terminal-pair learner) '(2 0))
    (let ((analysis (analyze-program-effective-code
                     (learner-program learner))))
      (find-if
       (lambda (signature)
         (and (= (getf analysis :effective-instruction-count)
                 (getf signature :effective-count))
              (equal (getf analysis :observation-indices)
                     (getf signature :observation-indices))))
       +bline-e0-analyse-proxy-signatures+))))

(defun apply-bline-decoy-priority-intervention
       (team &key
               (learner-ids +bline-e0-analyse-proxy-learner-ids+))
  "Demote the two measured v13 E0 Analyse proxy bidders off their true gate.

Return serialization-safe records describing every modified learner.  Exactly
two matches are required so this experiment cannot silently modify a different
checkpoint or a later descendant with coincidentally changed structure."
  (unless (and learner-ids
               (every #'stringp learner-ids)
               (= (length learner-ids)
                  (length (remove-duplicates learner-ids :test #'string=))))
    (error "Priority intervention requires unique learner IDs, got ~S."
           learner-ids))
  (let ((records nil))
    (dolist (reachable (closure team))
      (dolist (learner (team-learners reachable))
        (let ((signature
                (and (member (learner-id learner) learner-ids :test #'string=)
                     (bline-e0-analyse-proxy-signature learner))))
          (when signature
            (let* ((program (learner-program learner))
                   (before (length (program-instructions program))))
              (append-exact-pattern-demotion-gate
               program
               +bline-e0-raw-observation-indices+
               +bline-e0-analyse-pattern+)
              (push (list :team-id (team-id reachable)
                          :learner-id (learner-id learner)
                          :pair '(2 0)
                          :signature (copy-tree signature)
                          :instructions-before before
                          :instructions-after
                            (length (program-instructions program)))
                    records))))))
    (setf records (nreverse records))
    (unless (= (length records) (length learner-ids))
      (error "Expected v13 E0 Analyse proxy IDs ~S, modified ~D: ~S"
             learner-ids (length records) records))
    records))

(defun read-checkpoint-envelope (path)
  "Read one versioned checkpoint envelope without changing global state."
  (with-open-file (stream path :direction :input)
    (with-standard-io-syntax
      (read stream))))

(defun write-checkpoint-envelope (data path)
  "Write checkpoint envelope DATA readably to PATH."
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output
                               :if-exists :supersede
                               :if-does-not-exist :create)
    (with-standard-io-syntax
      (let ((*print-circle* t)
            (*print-readably* t)
            (*print-pretty* nil))
        (write data :stream stream))))
  path)

(defun write-bline-decoy-priority-intervention-checkpoint
       (source-path output-path)
  "Create the narrow v13 priority-intervention checkpoint at OUTPUT-PATH.

All original checkpoint metadata and saved search-state fields are retained,
but the evaluation protocol is tagged and the exact intervention provenance is
added.  SOURCE-PATH is never overwritten."
  (let ((data (read-checkpoint-envelope source-path)))
    (unless (versioned-best-team-checkpoint-p data)
      (error "Priority intervention requires a versioned checkpoint: ~A"
             source-path))
    (when (equal (pathname source-path) (pathname output-path))
      (error "Priority intervention refuses to overwrite its source checkpoint."))
    (let* ((team (deserialize-team
                  (getf data :team)
                  (make-hash-table :test #'equal)))
           (records (apply-bline-decoy-priority-intervention team)))
      (setf (getf data :team)
              (serialize-team team (make-hash-table :test #'equal))
            (getf data :fitness-evaluation-protocol)
              +bline-decoy-priority-intervention-protocol+
            (getf data :decoy-priority-intervention)
              (list :protocol +bline-decoy-priority-intervention-protocol+
                    :source (namestring (pathname source-path))
                    :raw-observation-indices
                      (copy-list +bline-e0-raw-observation-indices+)
                    :required-pattern
                      (copy-list +bline-e0-analyse-pattern+)
                    :modified-learners records))
      (write-checkpoint-envelope data output-path)
      (values output-path records))))

(defun write-bline-decoy-priority-intervention-from-environment ()
  "Build an intervention checkpoint from SOURCE_CHECKPOINT/OUTPUT_CHECKPOINT."
  (let ((source (uiop:getenv "SOURCE_CHECKPOINT"))
        (output (uiop:getenv "OUTPUT_CHECKPOINT")))
    (unless (and source output)
      (error "SOURCE_CHECKPOINT and OUTPUT_CHECKPOINT are required."))
    (multiple-value-bind (path records)
        (write-bline-decoy-priority-intervention-checkpoint source output)
      (format t "Wrote ~A~%Modified: ~S~%" path records)
      path)))
