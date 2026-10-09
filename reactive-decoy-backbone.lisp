(in-package :cl-tpg)

;;; Checkpoint-level causal experiment for the persistent v13 disagreement
;;; classes.  Exact reactive rules may win only on their real observation
;;; predicates.  Seven direct Decoy categories form a stable Top-8 backbone;
;;; the canonical Controller still owns availability and concrete option order.
;;; Existing root bids are scaled monotonically into a fallback band, preserving
;;; their relative order and leaving every internal team unchanged.

(defconstant +reactive-decoy-backbone-protocol+
  :reactive-decoy-backbone-v1)

(defparameter +reactive-decoy-backbone-targets+ '(8 2 3 4 5 9 10)
  "Semantic Decoy targets needed by the heuristic Controller schedule.")

(defparameter +reactive-decoy-backbone-bids+
  '(320.0d0 310.0d0 300.0d0 290.0d0 280.0d0 270.0d0 260.0d0)
  "Stable descending bids for the seven Decoy categories.")

(defparameter +reactive-decoy-backbone-root-scale+ 0.01d0
  "Positive scale mapping existing root bids from [-1000,1000] to [-10,10].")

(defun reactive-backbone-instruction
       (destination opcode source-1-type source-1-value
        source-2-type source-2-value)
  (%make-instruction
   :dest destination :op opcode :arity 2
   :src1-type source-1-type
   :src1-val (coerce source-1-value 'double-float)
   :src2-type source-2-type
   :src2-val (coerce source-2-value 'double-float)))

(defun reactive-backbone-program (instructions)
  (make-program
   :instructions
   (make-array (length instructions)
               :fill-pointer t
               :adjustable t
               :initial-contents instructions)))

(defun reactive-backbone-append-instruction (program instruction)
  (vector-push-extend instruction (program-instructions program))
  program)

(defun reactive-backbone-literal-instruction
       (destination observation-index expected)
  (ecase expected
    (0 (reactive-backbone-instruction
        destination :sub :const 1.0d0 :obs observation-index))
    (1 (reactive-backbone-instruction
        destination :add :obs observation-index :const 0.0d0))))

(defun reactive-backbone-pattern-instructions
       (observation-indices pattern &key (destination 1) (scratch 2))
  "Compile one exact binary PATTERN into DESTINATION."
  (let ((instructions
          (list
           (reactive-backbone-literal-instruction
            destination (first observation-indices) (first pattern)))))
    (loop for observation-index in (rest observation-indices)
          for expected in (rest pattern)
          do (setf instructions
                   (nconc
                    instructions
                    (list
                     (reactive-backbone-literal-instruction
                      scratch observation-index expected)
                     (reactive-backbone-instruction
                      destination :mul :reg destination :reg scratch)))))
    instructions))

(defun reactive-backbone-gated-score-instructions (gate-register active-score)
  "Map binary GATE-REGISTER to -1000 when false and ACTIVE-SCORE when true."
  (list
   (reactive-backbone-instruction
    +bid-register+ :add :reg gate-register :const -1.0d0)
   (reactive-backbone-instruction
    +bid-register+ :mul :reg +bid-register+ :const 1000.0d0)
   (reactive-backbone-instruction
    2 :mul :reg gate-register :const active-score)
   (reactive-backbone-instruction
    +bid-register+ :add :reg +bid-register+ :reg 2)))

(defun reactive-backbone-analyse-program (raw-start active-score)
  (let ((indices (loop for index from raw-start below (+ raw-start 4)
                       collect index)))
    (reactive-backbone-program
     (append
      (reactive-backbone-pattern-instructions indices '(1 0 0 0))
      (reactive-backbone-gated-score-instructions 1 active-score)))))

(defun reactive-backbone-restore-program
       (raw-start scan-index patterns active-score)
  (let ((indices (loop for index from raw-start below (+ raw-start 4)
                       collect index))
        (instructions
          (list
           (reactive-backbone-instruction
            3 :add :const 0.0d0 :const 0.0d0))))
    ;; The listed four-bit patterns are mutually exclusive, so their sum is a
    ;; binary OR in register 3.
    (dolist (pattern patterns)
      (setf instructions
            (nconc
             instructions
             (reactive-backbone-pattern-instructions indices pattern)
             (list
              (reactive-backbone-instruction
               3 :add :reg 3 :reg 1)))))
    ;; For canonical scan values 0/1/2, (3-s)*s/2 is exactly 0/1/1.
    (setf instructions
          (nconc
           instructions
           (list
            (reactive-backbone-instruction
             1 :sub :const 3.0d0 :obs scan-index)
            (reactive-backbone-instruction
             1 :mul :obs scan-index :reg 1)
            (reactive-backbone-instruction
             1 :div :reg 1 :const 2.0d0)
            (reactive-backbone-instruction
             3 :mul :reg 3 :reg 1))
           (reactive-backbone-gated-score-instructions 3 active-score)))
    (reactive-backbone-program instructions)))

(defun reactive-backbone-terminal-learner (target response program)
  (make-learner
   :program program
   :action
   (make-action
    :type :atomic
    :action
    (make-target-response-36-action :target target :response response))))

(defun reactive-backbone-constant-bid-program (bid)
  (reactive-backbone-program
   (list
    (reactive-backbone-instruction
     +bid-register+ :add :const bid :const 0.0d0))))

(defun reactive-backbone-rule-active-score (target)
  (ecase target
    (5 900.0d0)
    (3 880.0d0)
    (4 860.0d0)
    (2 840.0d0)))

(defun reactive-backbone-rule-for-target (target)
  (find target +bline-heuristic-host-rules+ :key #'second :test #'=))

(defun make-reactive-backbone-learners ()
  "Return exact Analyse/Restore learners followed by seven Decoy learners."
  (let ((learners nil))
    (dolist (target '(5 3 4 2))
      (destructuring-bind
            (raw-host-offset rule-target scan-state-index restore-patterns)
          (reactive-backbone-rule-for-target target)
        (declare (ignore scan-state-index restore-patterns))
        (push
         (reactive-backbone-terminal-learner
          rule-target 0
          (reactive-backbone-analyse-program
           (* raw-host-offset 4)
           (reactive-backbone-rule-active-score rule-target)))
         learners)))
    (dolist (target '(5 3 4 2))
      (destructuring-bind
            (raw-host-offset rule-target scan-state-index restore-patterns)
          (reactive-backbone-rule-for-target target)
        (push
         (reactive-backbone-terminal-learner
          rule-target 2
          (reactive-backbone-restore-program
           (* raw-host-offset 4)
           (+ +cage2-raw-observation-size+ scan-state-index)
           restore-patterns
           (reactive-backbone-rule-active-score rule-target)))
         learners)))
    (loop for target in +reactive-decoy-backbone-targets+
          for bid in +reactive-decoy-backbone-bids+
          do (push
              (reactive-backbone-terminal-learner
               target 3 (reactive-backbone-constant-bid-program bid))
              learners))
    (nreverse learners)))

(defun reactive-backbone-scale-root-learner (learner)
  "Scale one existing root bid monotonically without changing its action."
  (reactive-backbone-append-instruction
   (learner-program learner)
   (reactive-backbone-instruction
    +bid-register+ :mul :reg +bid-register+
    :const +reactive-decoy-backbone-root-scale+))
  learner)

(defun install-reactive-decoy-backbone (team)
  "Install the coordinated backbone into root TEAM and return a summary.

Only root programs are rescaled.  Internal teams, graph edges, actions, and
Controller semantics remain untouched."
  (unless (eq (team-type team) :root)
    (error "Reactive Decoy backbone requires a root team, got ~A."
           (team-type team)))
  (let* ((original-learners (copy-list (team-learners team)))
         (backbone (make-reactive-backbone-learners)))
    (mapc #'reactive-backbone-scale-root-learner original-learners)
    (setf (team-learners team) (append backbone original-learners)
          (team-option-orders team)
            (copy-action-option-orders
             (action-agreement-decoy-orders-for-profile :heuristic)))
    (list :protocol +reactive-decoy-backbone-protocol+
          :reactive-learners 8
          :decoy-learners (length +reactive-decoy-backbone-targets+)
          :original-root-learners (length original-learners)
          :root-bid-scale +reactive-decoy-backbone-root-scale+
          :decoy-targets (copy-list +reactive-decoy-backbone-targets+))))

(defun reactive-backbone-read-checkpoint (path)
  (with-open-file (stream path :direction :input)
    (with-standard-io-syntax
      (read stream))))

(defun reactive-backbone-write-checkpoint (data path)
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

(defun write-reactive-decoy-backbone-checkpoint (source-path output-path)
  "Create a separate backbone checkpoint while preserving source metadata."
  (when (equal (namestring (pathname source-path))
               (namestring (pathname output-path)))
    (error "Reactive Decoy backbone refuses to overwrite its source checkpoint."))
  (let ((data (reactive-backbone-read-checkpoint source-path)))
    (unless (versioned-best-team-checkpoint-p data)
      (error "Reactive Decoy backbone requires a versioned checkpoint: ~A"
             source-path))
    (let* ((team
             (deserialize-team
              (getf data :team) (make-hash-table :test #'equal)))
           (summary (install-reactive-decoy-backbone team)))
      (setf (getf data :team)
              (serialize-team team (make-hash-table :test #'equal))
            (getf data :fitness-evaluation-protocol)
              +reactive-decoy-backbone-protocol+
            (getf data :reactive-decoy-backbone)
              (append
               summary
               (list :source (namestring (pathname source-path)))))
      (reactive-backbone-write-checkpoint data output-path)
      (values output-path summary))))

(defun write-reactive-decoy-backbone-from-environment ()
  "Build an intervention checkpoint from SOURCE_CHECKPOINT/OUTPUT_CHECKPOINT."
  (let ((source (uiop:getenv "SOURCE_CHECKPOINT"))
        (output (uiop:getenv "OUTPUT_CHECKPOINT")))
    (unless (and source output)
      (error "SOURCE_CHECKPOINT and OUTPUT_CHECKPOINT are required."))
    (multiple-value-bind (path summary)
        (write-reactive-decoy-backbone-checkpoint source output)
      (format t "Wrote ~A~%Backbone: ~S~%" path summary)
      path)))
