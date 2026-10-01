(in-package :cl-tpg)

;;; A deterministic, serializable TPG compilation of the B-line heuristic.
;;; The TPG contains only ordinary programs, bids, learners, and atomic
;;; Semantic-36 terminals. The canonical Controller owns scan state and the
;;; versioned cross-target concrete Decoy schedule, exactly as it does for
;;; evolved policies.

(defun compiled-oracle-double (value)
  (coerce value 'double-float))

(defun compiled-oracle-instruction
       (dest op src1-type src1-value src2-type src2-value)
  (%make-instruction
   :dest dest
   :op op
   :src1-type src1-type
   :src1-val (compiled-oracle-double src1-value)
   :src2-type src2-type
   :src2-val (compiled-oracle-double src2-value)
   :arity 2))

(defun compiled-oracle-constant-instruction (dest value)
  (compiled-oracle-instruction dest :add :const value :const 0.0d0))

(defun compiled-oracle-literal-instruction
       (dest observation-index expected)
  (if (= expected 1)
      (compiled-oracle-instruction
       dest :add :obs observation-index :const 0.0d0)
      (compiled-oracle-instruction
       dest :sub :const 1.0d0 :obs observation-index)))

(defun compiled-oracle-pattern-instructions (observation-indices pattern)
  "Compile one exact four-bit match into register 1."
  (let ((instructions
          (list
           (compiled-oracle-literal-instruction
            1 (first observation-indices) (first pattern)))))
    (loop for observation-index in (rest observation-indices)
          for expected in (rest pattern)
          do (setf instructions
                   (nconc
                    instructions
                    (list
                     (compiled-oracle-literal-instruction
                      2 observation-index expected)
                     (compiled-oracle-instruction
                      1 :mul :reg 1 :reg 2)))))
    instructions))

(defun compiled-oracle-program (instructions)
  (make-program
   :instructions
   (make-array (length instructions)
               :fill-pointer t
               :adjustable t
               :initial-contents instructions)))

(defun compiled-oracle-constant-bid-program (bid)
  (compiled-oracle-program
   (list (compiled-oracle-constant-instruction +bid-register+ bid))))

(defun compiled-oracle-analyse-program (raw-start base active-score)
  (let ((indices
          (loop for index from raw-start below (+ raw-start 4)
                collect index))
        (boost (- active-score base)))
    (compiled-oracle-program
     (append
      (compiled-oracle-pattern-instructions indices '(1 0 0 0))
      (list
       (compiled-oracle-instruction
        +bid-register+ :mul :reg 1 :const boost)
       (compiled-oracle-instruction
        +bid-register+ :add :reg +bid-register+ :const base))))))

(defun compiled-oracle-restore-program
       (raw-start scan-index patterns base active-score)
  (let ((indices
          (loop for index from raw-start below (+ raw-start 4)
                collect index))
        (boost (- active-score base))
        (instructions
          (list (compiled-oracle-constant-instruction 3 0.0d0))))
    (dolist (pattern patterns)
      (setf instructions
            (nconc
             instructions
             (compiled-oracle-pattern-instructions indices pattern)
             (list
              (compiled-oracle-instruction 3 :add :reg 3 :reg 1)))))
    ;; Exact scan-seen gate for the canonical scan values 0, 1, and 2.
    (setf instructions
          (nconc
           instructions
           (list
            (compiled-oracle-instruction
             1 :sub :const 3.0d0 :obs scan-index)
            (compiled-oracle-instruction
             1 :mul :obs scan-index :reg 1)
            (compiled-oracle-instruction
             1 :div :reg 1 :const 2.0d0)
            (compiled-oracle-instruction 3 :mul :reg 3 :reg 1)
            (compiled-oracle-instruction
             +bid-register+ :mul :reg 3 :const boost)
            (compiled-oracle-instruction
             +bid-register+ :add :reg +bid-register+ :const base))))
    (compiled-oracle-program instructions)))

(defun compiled-oracle-terminal-learner (target response program)
  (make-learner
   :program program
   :action
   (make-action
    :type :atomic
    :action
    (make-target-response-36-action
     :target target :response response))))

(defun compiled-oracle-fallback-score (pair)
  (let ((position
          (position pair +bline-heuristic-fallback-ranking+
                    :test #'equal)))
    (and position (- 180.0d0 (* position 5.0d0)))))

(defun compiled-oracle-rule-active-score (target)
  (ecase target
    (5 900.0d0)
    (3 880.0d0)
    (4 860.0d0)
    (2 840.0d0)))

(defun compiled-oracle-rule-for-target (target)
  (find target +bline-heuristic-host-rules+ :key #'second :test #'=))

(defun make-compiled-bline-heuristic-team ()
  "Return a single-root Semantic-36 TPG compiled from the B-line heuristic."
  (let ((learners nil))
    ;; Reactive Analyse learners retain their deterministic fallback bids.
    (dolist (target '(5 3 4 2))
      (destructuring-bind
            (raw-host-offset rule-target scan-state-index restore-patterns)
          (compiled-oracle-rule-for-target target)
        (declare (ignore scan-state-index restore-patterns))
        (let* ((pair (list rule-target 0))
               (base (compiled-oracle-fallback-score pair)))
          (push
           (compiled-oracle-terminal-learner
            rule-target 0
            (compiled-oracle-analyse-program
             (* raw-host-offset 4)
             base
             (compiled-oracle-rule-active-score rule-target)))
           learners))))
    ;; Restore is inactive below every default bid and receives its exact
    ;; deterministic priority only when observation and scan gates both hold.
    (dolist (target '(5 3 4 2))
      (destructuring-bind
            (raw-host-offset rule-target scan-state-index restore-patterns)
          (compiled-oracle-rule-for-target target)
        (let ((active-score
                (compiled-oracle-rule-active-score rule-target)))
          (push
           (compiled-oracle-terminal-learner
            rule-target 2
            (compiled-oracle-restore-program
             (* raw-host-offset 4)
             (+ +cage2-raw-observation-size+ scan-state-index)
             restore-patterns
             (- active-score 1000.0d0)
             active-score))
           learners))))
    ;; One learner per Decoy target is sufficient: the canonical heuristic
    ;; Controller profile resolves these categories through the global list.
    (loop for target in '(8 2 3 4 5 9 10)
          for bid from 320.0d0 downto 260.0d0 by 10.0d0
          do (push
              (compiled-oracle-terminal-learner
               target 3 (compiled-oracle-constant-bid-program bid))
              learners))
    ;; Analyse 2..5 already exist as reactive learners.
    (dolist (pair +bline-heuristic-fallback-ranking+)
      (unless (and (= (second pair) 0)
                   (member (first pair) '(2 3 4 5) :test #'=))
        (push
         (compiled-oracle-terminal-learner
          (first pair)
          (second pair)
          (compiled-oracle-constant-bid-program
           (compiled-oracle-fallback-score pair)))
         learners)))
    (%make-team
     :id "TEAM-COMPILED-BLINE-HEURISTIC"
     :references 0
     :type :root
     :option-orders
       (copy-action-option-orders
        (action-agreement-decoy-orders-for-profile :heuristic))
     :learners (nreverse learners))))

(defun write-compiled-bline-heuristic-checkpoint (path)
  "Build and write the standalone compiled B-line TPG checkpoint to PATH."
  (let* ((*num-observations* +cage2-scan-observation-size+)
         (*num-actions* +num-semantic-36-actions+)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*decoy-order-mode* :fixed)
         (*cage2-opening-mode* :fixed)
         (*teacher-backend* :heuristic)
         (*recurrent-policy-enabled* nil)
         (team (make-compiled-bline-heuristic-team)))
    (write-best-team-checkpoint
     team 0.0d0 path
     :generation 0
     :gym-environment-name "Cage2-b_line-100-v0"
     :online-fitness-episodes 0
     :search-seed 153
     :fitness-evaluation-protocol :compiled-bline-heuristic-v2
     :dataset-name nil
     :dataset-fingerprint nil
     :action-agreement-signature (action-agreement-signature)
     :online-reference-episodes 0
     :mixed-training-lineage nil
     :hamming-space-enabled nil
     :hamming-dataset-fingerprint nil
     :num-observations +cage2-scan-observation-size+
     :decoy-order-mode :fixed
     :cage2-opening-mode :fixed
     :recurrent-policy-enabled nil
     :teacher-backend :heuristic
     :terminal-action-format :target-response-36)
    team))
