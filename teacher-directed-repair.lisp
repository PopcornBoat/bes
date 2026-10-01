(in-package :cl-tpg)

;;; teacher-directed repair turns a systematic DAgger disagreement into directed genotype
;;; variation.  The teacher identifies the desired Semantic-36 terminal, but
;;; never edits the deployed policy at execution time.  A correction learner
;;; clones the bidder that currently owns the error region, receives the
;;; teacher terminal, and gets a small observation gate synthesized from the
;;; repeated error rows.  Existing locality/collateral gates decide whether the
;;; child may enter selection; official paired evaluation remains authoritative
;;; for historical-best promotion.

(defun teacher-directed-repair-active-p ()
  "Return true when the complete teacher-directed repair contract is active."
  (and *teacher-directed-repair-enabled*
       *targeted-disagreement-audit-enabled*
       *targeted-routing-repair-enabled*
       *grouped-selection-enabled*
       *semantic-locality-control-enabled*
       *behavioral-locality-enabled*
       (official-guided-mode-p)
       (eq *terminal-action-format* :target-response-36)))

(defun teacher-directed-repair-slot-p ()
  "Reserve the frozen ten-percent repair quota using its resumed RNG stream."
  (targeted-routing-repair-slot-p))

(defun teacher-directed-systematic-issues ()
  "Return all systematic disagreements addressable by a direct terminal.

Unlike targeted repair, missing Top-k or genotype support is not deferred: the
teacher pair itself supplies the terminal for the correction learner."
  (remove-if-not
   (lambda (issue)
     (and (getf issue :systematic-p)
          (member (getf issue :case)
                  '(:case-a-routing
                    :case-b1-reachable-support
                    :case-b2-missing-support)
                  :test #'eq)))
   (getf (getf *last-dagger-diagnostics* :targeted-repair-audit)
         :systematic-issues)))

(defun teacher-directed-nontarget-observations (issue)
  "Return probe observations outside ISSUE's teacher/phase group."
  (loop for probe in *behavioral-probe-archive*
        unless (targeted-probe-belongs-to-issue-p probe issue)
          collect (getf probe :observation)))

(defun teacher-directed-invariant-feature-records (contexts issue)
  "Rank observation features invariant on CONTEXTS by probe collisions."
  (let* ((target-observations
           (mapcar (lambda (context) (getf context :observation)) contexts))
         (first (first target-observations))
         (background (teacher-directed-nontarget-observations issue))
         (records nil))
    (when first
      (dotimes (index (length first))
        (let ((value (aref first index)))
          (when (every (lambda (observation)
                         (= (aref observation index) value))
                       (rest target-observations))
            (let ((collisions
                    (count-if
                     (lambda (observation)
                       (= (aref observation index) value))
                     background)))
              (push (list :index index
                          :value value
                          :collisions collisions
                          :collision-rate
                            (/ collisions
                               (coerce (max 1 (length background))
                                       'double-float)))
                    records))))))
    (subseq
     (stable-sort
      records
      (lambda (left right)
        (or (< (getf left :collisions) (getf right :collisions))
            (and (= (getf left :collisions) (getf right :collisions))
                 (< (getf left :index) (getf right :index))))))
     0 (min +teacher-directed-repair-max-features+ (length records)))))

(defun teacher-directed-feature-subsets (features)
  "Return bounded deterministic one-, two-, and three-feature gates."
  (let* ((singles (mapcar #'list features))
         (pair-source (subseq features 0 (min 6 (length features))))
         (triple-source (subseq features 0 (min 4 (length features))))
         (pairs
           (loop for tail on pair-source
                 append
                 (loop for right in (rest tail)
                       collect (list (first tail) right))))
         (triples
           (loop for first-tail on triple-source
                 append
                 (loop for second-tail on (rest first-tail)
                       append
                       (loop for third in (rest second-tail)
                             collect
                               (list (first first-tail)
                                     (first second-tail)
                                     third)))))
         ;; The ungated lift is last and survives only if the existing
         ;; collateral/locality checks prove it genuinely local in behavior.
         (all (append singles pairs triples (list nil))))
    (subseq all 0 (min +teacher-directed-repair-max-candidates+
                       (length all)))))

(defun teacher-directed-push-instruction (program instruction)
  "Append one deterministic instruction to PROGRAM."
  (vector-push-extend instruction (program-instructions program))
  program)

(defun teacher-directed-binary-instruction
       (dest op src1-type src1-val src2-type src2-val)
  "Construct one binary instruction without consuming evolution RNG."
  (%make-instruction
   :dest dest :op op :arity 2
   :src1-type src1-type :src1-val (coerce src1-val 'double-float)
   :src2-type src2-type :src2-val (coerce src2-val 'double-float)))

(defun teacher-directed-gated-bid-program (source-program features)
  "Clone SOURCE-PROGRAM and append an exact-match correction gate.

At a matching target row the cloned bidder gains only the frozen positive
margin.  Each mismatching feature subtracts a large absolute-distance penalty,
so the new terminal is suppressed away from the diagnosed region."
  (when (< +num-registers+ 4)
    (error "teacher-directed repair bidder synthesis requires at least four registers."))
  (let ((program (clone-program source-program))
        (gate-register 1)
        (difference-register 2)
        (opposite-register 3))
    (teacher-directed-push-instruction
     program
     (teacher-directed-binary-instruction
      gate-register :add :const +teacher-directed-repair-bid-margin+
      :const 0.0d0))
    (dolist (feature features)
      (let ((index (getf feature :index))
            (value (getf feature :value)))
        (teacher-directed-push-instruction
         program
         (teacher-directed-binary-instruction
          difference-register :sub :obs index :const value))
        (teacher-directed-push-instruction
         program
         (teacher-directed-binary-instruction
          opposite-register :sub :const value :obs index))
        (teacher-directed-push-instruction
         program
         (teacher-directed-binary-instruction
          difference-register :max :reg difference-register
          :reg opposite-register))
        (teacher-directed-push-instruction
         program
         (teacher-directed-binary-instruction
          difference-register :mul :reg difference-register
          :const +teacher-directed-repair-mismatch-penalty+))
        (teacher-directed-push-instruction
         program
         (teacher-directed-binary-instruction
          gate-register :sub :reg gate-register
          :reg difference-register))))
    (teacher-directed-push-instruction
     program
     (teacher-directed-binary-instruction
      +bid-register+ :add :reg +bid-register+ :reg gate-register))
    program))

(defun teacher-directed-dominant-error-winner (parent contexts)
  "Return the root learner winning the largest number of target CONTEXTS."
  (let ((counts (make-hash-table :test #'eq)))
    (dolist (context contexts)
      (let ((winner
              (targeted-root-winning-learner
               parent (getf context :observation))))
        (when winner
          (incf (gethash winner counts 0)))))
    (loop with best = nil
          with best-count = -1
          for learner in (team-learners parent)
          for count = (gethash learner counts 0)
          when (> count best-count)
            do (setf best learner best-count count)
          finally (return best))))

(defun teacher-directed-add-correction-learner
       (child source teacher-pair features)
  "Add one teacher-terminal learner derived from SOURCE's routing program."
  (when (or (>= (length (team-learners child)) *max-num-learners*)
            (and (realp *max-program-size*)
                 (> (+ (length
                         (program-instructions (learner-program source)))
                       2 (* 5 (length features)))
                    *max-program-size*)))
    (return-from teacher-directed-add-correction-learner nil))
  (let ((learner
          (make-learner
           :program
             (teacher-directed-gated-bid-program
              (learner-program source) features)
           :action
             (make-action
              :type :atomic
              :action
                (make-target-response-36-action
                 :target (first teacher-pair)
                 :response (second teacher-pair))))))
    ;; The new learner precedes the cloned source.  If the source bid is
    ;; already saturated at +1000, the stable tie therefore still selects the
    ;; correction on an exact gate match.
    (push learner (team-learners child))
    (note-mutation-event :teacher-directed-terminal-injection)
    (note-mutation-event :teacher-directed-bidder-gate)
    learner))

(defun teacher-directed-feature-summary (features)
  "Return a serializable compact description of a synthesized gate."
  (mapcar (lambda (feature)
            (list :index (getf feature :index)
                  :value (getf feature :value)
                  :collision-rate (getf feature :collision-rate)))
          features))

(defun teacher-directed-candidate-better-p (left right)
  "Order accepted repairs by target gain, then minimum disruption."
  (let ((left-target (getf left :target))
        (right-target (getf right :target))
        (left-locality (getf left :locality))
        (right-locality (getf right :locality)))
    (or (> (getf left-target :top1-gains)
           (getf right-target :top1-gains))
        (and (= (getf left-target :top1-gains)
                (getf right-target :top1-gains))
             (or (< (getf left-target :child-mean-rank)
                    (getf right-target :child-mean-rank))
                 (and (= (getf left-target :child-mean-rank)
                         (getf right-target :child-mean-rank))
                      (< (getf left-locality :ranking-distance-mean)
                         (getf right-locality
                               :ranking-distance-mean))))))))

(defun teacher-directed-try-parent-issue (parent issue contexts)
  "Synthesize bounded teacher-directed corrections for PARENT and ISSUE."
  (let* ((source (teacher-directed-dominant-error-winner parent contexts))
         (features (teacher-directed-invariant-feature-records contexts issue))
         (feature-subsets (teacher-directed-feature-subsets features))
         (best nil)
         (attempt 0))
    (unless source
      (return-from teacher-directed-try-parent-issue (values nil nil 0 nil)))
    (dolist (subset feature-subsets)
      (incf attempt)
      (let ((child (clone-team parent))
            (*active-mutation-events* nil))
        (if (null
             (teacher-directed-add-correction-learner
              child source (getf issue :teacher-pair) subset))
            (discard-semantic-locality-candidate child)
            (let* ((events (nreverse *active-mutation-events*))
                   (target
                     (targeted-target-group-comparison child contexts))
                   (locality
                     (make-behavioral-mutation-record parent child events))
                   (collateral
                     (targeted-collateral-comparison parent child issue))
                   (candidate
                     (list :child child :locality locality :target target
                           :collateral collateral :features subset
                           :attempt attempt)))
              (if (and locality
                       (targeted-target-comparison-improves-p target)
                       (targeted-collateral-acceptable-p
                        collateral locality))
                  (if (or (null best)
                          (teacher-directed-candidate-better-p candidate best))
                      (progn
                        (when best
                          (discard-semantic-locality-candidate
                           (getf best :child)))
                        (setf best candidate))
                      (discard-semantic-locality-candidate child))
                  (discard-semantic-locality-candidate child))))))
    (if (null best)
        (values nil nil attempt (learner-id source))
        (let ((locality (getf best :locality)))
          (setf
           (getf locality :control-protocol)
             +semantic-locality-control-protocol+
           (getf locality :control-stage) :teacher-directed-repair
           (getf locality :control-age) *semantic-locality-control-age*
           (getf locality :control-requested-tier) :targeted
           (getf locality :control-tier) :bounded
           (getf locality :control-effective-tier) :bounded
           (getf locality :control-escalated-p) nil
           (getf locality :control-attempts) (getf best :attempt)
           (getf locality :control-fallback-p) nil
           (getf locality :teacher-directed-issue) (copy-tree issue)
           (getf locality :teacher-directed-source-learner-id) (learner-id source)
           (getf locality :teacher-directed-gate)
             (teacher-directed-feature-summary (getf best :features))
           (getf locality :teacher-directed-target-comparison)
             (copy-tree (getf best :target))
           (getf locality :teacher-directed-collateral)
             (copy-tree (getf best :collateral)))
          (register-behavioral-mutation-record
           parent (getf best :child) locality)
          (push (copy-tree locality)
                *semantic-locality-control-generation-records*)
          (values (getf best :child) locality attempt
                  (learner-id source))))))

(defun teacher-directed-record-directed-attempt (record)
  "Retain one serializable teacher-directed repair repair decision."
  (push (copy-tree record) *teacher-directed-repair-generation-records*)
  record)

(defun teacher-directed-attempt-repair (parents)
  "Attempt one teacher-directed child and return CHILD/PARENT."
  (let ((issues (teacher-directed-systematic-issues)))
    (unless (and issues *teacher-training-dataset*)
      (teacher-directed-record-directed-attempt
       (list :protocol +teacher-directed-repair-protocol+
             :generation *generation* :accepted nil
             :reason :no-systematic-issues))
      (return-from teacher-directed-attempt-repair (values nil nil)))
    (let* ((issue (targeted-weighted-issue issues))
           (start (targeted-routing-random-below (length parents)))
           (checked 0))
      (loop for offset below
              (min +teacher-directed-repair-max-parents+ (length parents))
            for parent = (nth (mod (+ start offset) (length parents)) parents)
            for contexts =
              (targeted-parent-row-contexts
               parent *teacher-training-dataset* issue)
            do (incf checked)
               (when (>= (length contexts)
                         +targeted-routing-repair-minimum-rows+)
                 (multiple-value-bind (child locality attempts source-id)
                     (teacher-directed-try-parent-issue parent issue contexts)
                   (when child
                     (teacher-directed-record-directed-attempt
                      (list :protocol +teacher-directed-repair-protocol+
                            :generation *generation* :accepted t
                            :issue (copy-tree issue)
                            :parent-team-id (team-id parent)
                            :child-team-id (team-id child)
                            :parents-checked checked
                            :candidate-attempts attempts
                            :source-learner-id source-id
                            :gate (copy-tree (getf locality :teacher-directed-gate))
                            :target-comparison
                              (copy-tree
                               (getf locality
                                     :teacher-directed-target-comparison))
                            :collateral
                              (copy-tree
                               (getf locality :teacher-directed-collateral))
                            :top1-hamming
                              (getf locality :top1-hamming)
                            :ranking-distance
                              (getf locality :ranking-distance-mean)))
                     (return-from teacher-directed-attempt-repair
                       (values child parent))))))
      (teacher-directed-record-directed-attempt
       (list :protocol +teacher-directed-repair-protocol+
             :generation *generation* :accepted nil
             :reason :no-acceptable-directed-repair
             :issue (copy-tree issue)
             :parents-checked checked))
      (values nil nil))))

(defun finish-teacher-directed-repair-generation ()
  "Journal and summarize teacher-directed repair decisions for the generation."
  (when (teacher-directed-repair-active-p)
    (let* ((records (nreverse *teacher-directed-repair-generation-records*))
           (attempted (length records))
           (accepted
             (count-if (lambda (record) (getf record :accepted)) records)))
      (when attempted
        (emit-message
         (format nil
                 "Generation ~D teacher-directed repair directed repair: slots=~D accepted=~D fallback=~D."
                 *generation* attempted accepted (- attempted accepted)))
        (when (behavioral-locality-active-p)
          (append-behavioral-locality-form
           (list :type :teacher-directed-repair-generation
                 :protocol +teacher-directed-repair-protocol+
                 :generation *generation*
                 :attempted attempted
                 :accepted accepted
                 :fallback (- attempted accepted)
                 :records records))))
      (setf *teacher-directed-repair-generation-records* nil))))
