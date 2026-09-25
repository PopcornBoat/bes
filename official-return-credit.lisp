(in-package :cl-tpg)

;;; Phase 5A changes only how a measured official parent/child improvement is
;;; retained.  It does not alter native mutation, Phase-3 locality, grouped
;;; epsilon-lexicase, or the historical-incumbent promotion protocol.

(defun official-return-credit-active-p ()
  "Return true when the isolated Phase-5A treatment is active."
  (and *official-return-credit-enabled*
       (official-guided-mode-p)
       *semantic-locality-control-enabled*
       *phase4-selection-enabled*
       (not *phase4b-routing-repair-enabled*)
       (not *phase4b-specialist-composition-enabled*)
       (not *phase4b-combined-repair-enabled*)))

(defun official-return-credit-state-copy ()
  "Return serializable Phase-5A counters for checkpoint/runtime recovery."
  (when *official-return-credit-enabled*
    (list :version 1
          :protocol +official-return-credit-protocol+
          :approved-count *official-return-credit-approved-count*
          :rejected-count *official-return-credit-rejected-count*)))

(defun restore-official-return-credit-state (state)
  "Restore validated Phase-5A counters from STATE."
  (when state
    (unless (and (= (getf state :version 0) 1)
                 (eq (getf state :protocol)
                     +official-return-credit-protocol+))
      (error "Invalid official return-credit state: ~S" state))
    (setf *official-return-credit-approved-count*
            (getf state :approved-count 0)
          *official-return-credit-rejected-count*
            (getf state :rejected-count 0))))

(defun reset-official-return-credit-state ()
  "Reset run-local Phase-5A counters."
  (setf *official-return-credit-approved-count* 0
        *official-return-credit-rejected-count* 0))

(defun official-return-credit-continue-p (child-returns parent-returns)
  "Return true unless the Stage-1 paired evidence establishes futility."
  (multiple-value-bind (mean se)
      (official-guided-comparison-statistics child-returns parent-returns)
    (let ((margin (* +official-return-credit-standard-errors+ se)))
      (values (> (+ mean margin) 0.0d0) mean margin))))

(defun official-return-credit-approve-p (child-returns parent-returns)
  "Approve only a positive child/direct-parent paired uncertainty margin."
  (multiple-value-bind (mean se)
      (official-guided-comparison-statistics child-returns parent-returns)
    (let ((margin (* +official-return-credit-standard-errors+ se)))
      (values (> mean margin) mean margin))))

(defun make-official-return-credit-record
       (&key stage seeds child-returns parent-returns accepted
             behavioral-locality margin)
  "Build one structured Phase-5A direct-parent credit record."
  (append
   (make-official-guided-evaluation-record
    :stage stage
    :imitation-score nil
    :seeds seeds
    :candidate-returns child-returns
    :incumbent-returns parent-returns
    :accepted accepted)
   (list :credit-protocol +official-return-credit-protocol+
         :comparison :child-versus-direct-parent
         :margin margin
         :behavioral-locality (copy-tree behavioral-locality))))

(defun install-official-return-credit-anchor (candidate-path)
  "Load CANDIDATE-PATH as an independent live root for one selection cycle.

The anchor is not *BEST-TEAM* and receives no direct promotion privilege.  It
enters after the current generation was evaluated, survives that deletion
boundary, and must compete normally under grouped epsilon-lexicase from the
next generation onward."
  (let ((anchor (load-best-team candidate-path)))
    (ensure-team-observation-compatible anchor *num-observations*)
    (setf (team-type anchor) :root
          (team-references anchor) 0)
    (dolist (team (closure anchor))
      (pushnew team *teams* :test #'eq))
    (incf *official-return-credit-approved-count*)
    anchor))

(defun persist-official-return-credit-outcome
       (generation evaluation anchor-id)
  "Append a compact causal Phase-5A decision to the research journal."
  (when (behavioral-locality-active-p)
    (append-behavioral-locality-form
     (list :type :official-return-credit-outcome
           :protocol +official-return-credit-protocol+
           :generation generation
           :accepted (getf evaluation :accepted)
           :anchor-id anchor-id
           :evaluation (copy-tree evaluation)))))
