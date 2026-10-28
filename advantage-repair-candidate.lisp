(in-package :cl-tpg)

(defun advantage-repair-observation-array (values)
  (make-array 62 :element-type 'double-float
                 :initial-contents values))

(defun advantage-repair-terminal-pair (learner)
  (let* ((action (learner-action learner))
         (payload (and (eq (action-type action) :atomic)
                       (action-action action))))
    (and (target-response-36-action-p payload)
         (list (target-response-36-action-target payload)
               (target-response-36-action-response payload)))))

(defun advantage-repair-append-gate (learner conjunction)
  "Add a 0.001 bid boost only when two categorical observations match."
  (let* ((left (getf conjunction :left))
         (right (getf conjunction :right))
         (program (learner-program learner)))
    (dolist
        (instruction
          (list
           (teacher-guided-instruction
            1 :eq :obs (getf left :observation-index)
            :ror (getf left :ror-index))
           (teacher-guided-instruction
            2 :eq :obs (getf right :observation-index)
            :ror (getf right :ror-index))
           (teacher-guided-instruction
            1 :mul :reg 1 :reg 2)
           (teacher-guided-instruction
            1 :mul :reg 1 :const 0.001d0)
           (teacher-guided-instruction
            +bid-register+ :add :reg +bid-register+ :reg 1)))
      (teacher-guided-append-instruction program instruction)))
  learner)

(defun advantage-repair-selected-observation (analysis)
  "Choose the largest positive-mean observation group for route inspection."
  (let ((groups
          (remove-if-not
           (lambda (group) (plusp (getf group :mean-delta)))
           (getf analysis :positive-observation-groups))))
    (unless groups
      (error "No positive-mean observation group is available."))
    (getf
     (first
      (stable-sort
       (copy-list groups)
       (lambda (left right)
         (or (> (getf left :count) (getf right :count))
             (and (= (getf left :count) (getf right :count))
                  (> (getf left :mean-delta)
                     (getf right :mean-delta)))))))
     :observation)))

(defun advantage-repair-build-child (parent observation conjunction)
  "Deep-copy PARENT and modify the existing (9,3) terminal on its winning path."
  (let ((child (deep-copy-team-via-serialization parent)))
    (multiple-value-bind (ranking path terminal-team)
        (execute-team-semantic-ranked
         child (advantage-repair-observation-array observation))
      (declare (ignore path))
      (unless (equal '(7 0)
                     (semantic-action-category-pair (first ranking)))
        (error "Expected the incumbent (7,0) at the selected observation."))
      (let ((target-learners
              (remove-if-not
               (lambda (learner)
                 (equal '(9 3)
                        (advantage-repair-terminal-pair learner)))
               (team-learners terminal-team))))
        (unless (= 1 (length target-learners))
          (error "Expected one (9,3) learner in terminal team, got ~D."
                 (length target-learners)))
        (let ((learner (first target-learners)))
          (advantage-repair-append-gate learner conjunction)
          (values child
                  (list :terminal-team (team-id terminal-team)
                        :learner (learner-id learner)
                        :old-program-size
                          (- (length
                              (program-instructions
                               (learner-program learner)))
                             5)
                        :new-program-size
                          (length
                           (program-instructions
                            (learner-program learner))))))))))

(defun advantage-repair-top-pair (team values)
  (first
   (behavioral-ranking-pairs
    team (advantage-repair-observation-array values))))

(defun advantage-repair-probe (parent child data)
  "Count intended and collateral Top-1 changes on development trajectories."
  (let ((positive-ids (make-hash-table :test #'equal))
        (positive-count 0)
        (positive-changed 0)
        (positive-advantage-sum 0.0d0)
        (negative-count 0)
        (negative-changed 0)
        (protected-count 0)
        (protected-changed 0)
        (unexpected-changes 0))
    (dolist (record (getf data :records))
      (when (eq (getf record :status) :eligible)
        (let* ((delta (getf record :paired-delta))
               (before
                 (advantage-repair-top-pair
                  parent (getf record :policy-observation)))
               (after
                 (advantage-repair-top-pair
                  child (getf record :policy-observation)))
               (changed (not (equal before after))))
          (when changed
            (unless (equal '(9 3) after)
              (incf unexpected-changes)))
          (cond
            ((> delta 0.5d0)
             (setf (gethash (list (getf record :seed)
                                  (getf record :step))
                            positive-ids)
                   t)
             (incf positive-count)
             (when changed
               (incf positive-changed)
               (incf positive-advantage-sum delta)))
            ((< delta -0.5d0)
             (incf negative-count)
             (when changed (incf negative-changed)))))))
    (dolist (entry (getf data :background))
      (unless (gethash (list (getf entry :seed)
                             (getf entry :step))
                       positive-ids)
        (incf protected-count)
        (let ((before
                (advantage-repair-top-pair
                 parent (getf entry :observation)))
              (after
                (advantage-repair-top-pair
                 child (getf entry :observation))))
          (unless (equal before after)
            (incf protected-changed)
            (unless (equal '(9 3) after)
              (incf unexpected-changes))))))
    (list :positive-count positive-count
          :positive-changed positive-changed
          :positive-advantage-sum positive-advantage-sum
          :negative-count negative-count
          :negative-changed negative-changed
          :protected-count protected-count
          :protected-changed protected-changed
          :protected-change-rate
            (/ protected-changed
               (coerce (max 1 protected-count) 'double-float))
          :unexpected-changes unexpected-changes)))

(defun run-advantage-repair-candidate
       (development-path analysis-path checkpoint candidate-path report-path)
  "Build one ordinary TPG bid edit from official development evidence."
  (let* ((*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*instruction-set-profile* :full)
         (*read-only-register-profile* :disabled)
         (*recurrent-policy-enabled* nil)
         (*hamming-space-enabled* nil)
         (data (rare-failure-read-form development-path))
         (analysis (rare-failure-read-form analysis-path))
         (policy (rare-failure-load-policy :repair checkpoint))
         (parent (getf policy :team))
         (metadata (getf policy :metadata)))
    (setf *instruction-set-profile*
          (or (getf metadata :instruction-set-profile) :full)
          *read-only-register-profile*
          (or (getf metadata :read-only-register-profile) :disabled))
    (let* ((conjunction
             (first (getf analysis :top-conjunctions)))
           (observation
             (advantage-repair-selected-observation analysis)))
      (unless conjunction
        (error "No candidate two-atom conjunction was found."))
      (multiple-value-bind (child edit)
          (advantage-repair-build-child
           parent observation conjunction)
        (let* ((probe (advantage-repair-probe parent child data))
               (report
                 (list :protocol :advantage-repair-candidate-v1
                       :source-checkpoint checkpoint
                       :candidate-checkpoint candidate-path
                       :conjunction conjunction
                       :bid-boost 0.001d0
                       :edit edit
                       :probe probe)))
          (write-best-team-checkpoint
           child nil candidate-path
           :generation (getf metadata :generation)
           :gym-environment-name "Cage2-meander-100-v0"
           :num-observations 62
           :terminal-action-format :target-response-36
           :instruction-set-profile *instruction-set-profile*
           :read-only-register-profile *read-only-register-profile*
           :decoy-order-mode :fixed
           :cage2-opening-mode :fixed
           :recurrent-policy-enabled nil
           :action-agreement-signature
             (action-agreement-signature))
          (rare-failure-write-form report report-path)
          report)))))
