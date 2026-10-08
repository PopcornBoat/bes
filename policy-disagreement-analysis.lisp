(in-package :cl-tpg)

(defconstant +policy-disagreement-analysis-protocol+
  :policy-disagreement-analysis-v1)

(defparameter +policy-disagreement-sample-limit+ 200)

(defun policy-disagreement-proposal (step label)
  (or (find label (getf step :policy-proposals)
            :key (lambda (proposal) (getf proposal :label))
            :test #'eq)
      (error "Step ~D has no ~S proposal." (getf step :step) label)))

(defun policy-disagreement-phase (step-index)
  (cond ((< step-index 30) :steps-0-29)
        ((< step-index 50) :steps-30-49)
        (t :steps-50-plus)))

(defun policy-disagreement-increment (table key &optional (amount 1))
  (incf (gethash key table 0) amount))

(defun policy-disagreement-table-alist (table &key (sort-by-count-p nil))
  (let ((entries
          (loop for key being the hash-keys of table using (hash-value value)
                collect (cons key value))))
    (if sort-by-count-p
        (stable-sort entries #'> :key #'cdr)
        (stable-sort entries #'string<
                     :key (lambda (entry)
                            (prin1-to-string (car entry)))))))

(defun policy-disagreement-rate (numerator denominator)
  (if (plusp denominator)
      (/ numerator (coerce denominator 'double-float))
      0.0d0))

(defun policy-disagreement-mean (values)
  (if values
      (/ (reduce #'+ values) (coerce (length values) 'double-float))
      0.0d0))

(defun policy-disagreement-effective-summary (policy)
  (let ((analysis (analyze-team-effective-code (getf policy :team))))
    (list :team-count (getf analysis :team-count)
          :learner-count (getf analysis :learner-count)
          :instruction-count (getf analysis :instruction-count)
          :effective-instruction-count
            (getf analysis :effective-instruction-count)
          :intron-count (getf analysis :intron-count)
          :effective-ratio (getf analysis :effective-ratio)
          :programs-without-effective-instructions
            (getf analysis :programs-without-effective-instructions)
          :max-program-size (getf analysis :max-program-size)
          :max-effective-program-size
            (getf analysis :max-effective-program-size)
          :observation-indices
            (copy-list (getf analysis :observation-indices)))))

(defun policy-disagreement-copy-value (value)
  (typecase value
    (vector (copy-seq value))
    (cons (copy-tree value))
    (t value)))

(defun policy-disagreement-compact-step (episode step evolved compiled)
  (list :behavior (getf episode :behavior)
        :seed (getf episode :seed)
        :step (getf step :step)
        :policy-observation (copy-seq (getf step :policy-observation))
        :decoy-mask-before
          (policy-disagreement-copy-value (getf step :decoy-mask-before))
        :reward (getf step :reward)
        :cumulative-return (getf step :cumulative-return)
        :teacher-ranking (copy-tree (getf step :teacher-ranking))
        :teacher-decision (copy-tree (getf step :teacher-decision))
        :evolved-ranking (copy-tree (getf evolved :ranking))
        :evolved-decision (copy-tree (getf evolved :decision))
        :evolved-winning-learner (getf evolved :winning-learner)
        :evolved-winning-bid (getf evolved :winning-bid)
        :evolved-path (copy-list (getf evolved :preferred-path))
        :compiled-ranking (copy-tree (getf compiled :ranking))
        :compiled-decision (copy-tree (getf compiled :decision))
        :compiled-winning-learner (getf compiled :winning-learner)
        :compiled-winning-bid (getf compiled :winning-bid)
        :executed-decision (copy-tree (getf step :executed-decision))))

(defun policy-disagreement-phase-summary
       (phase-counts phase-concrete-disagreements)
  (loop for phase in '(:steps-0-29 :steps-30-49 :steps-50-plus)
        for steps = (gethash phase phase-counts 0)
        for disagreements =
          (gethash phase phase-concrete-disagreements 0)
        collect (list :phase phase
                      :steps steps
                      :concrete-disagreements disagreements
                      :concrete-disagreement-rate
                        (policy-disagreement-rate disagreements steps))))

(defun summarize-policy-disagreement-episodes (episodes)
  "Summarize dual-policy traces without retaining complete observations."
  (let ((policy-steps 0)
        (evolved-compiled-top1-agreements 0)
        (evolved-compiled-ranking-agreements 0)
        (evolved-compiled-resolved-pair-agreements 0)
        (evolved-compiled-concrete-agreements 0)
        (semantic-different-concrete-same 0)
        (evolved-teacher-top1-agreements 0)
        (compiled-teacher-top1-agreements 0)
        (evolved-teacher-concrete-agreements 0)
        (compiled-teacher-concrete-agreements 0)
        (teacher-in-evolved-top8 0)
        (teacher-absent-evolved-top8 0)
        (teacher-in-compiled-top8 0)
        (teacher-absent-compiled-top8 0)
        (path-lengths nil)
        (first-disagreements nil)
        (returns nil)
        (samples nil)
        (evolved-teams (make-hash-table :test #'equal))
        (evolved-winners (make-hash-table :test #'equal))
        (evolved-terminals (make-hash-table :test #'equal))
        (semantic-confusion (make-hash-table :test #'equal))
        (concrete-confusion (make-hash-table :test #'equal))
        (phase-counts (make-hash-table :test #'eq))
        (phase-concrete-disagreements (make-hash-table :test #'eq)))
    (dolist (episode episodes)
      (push (coerce (getf episode :return) 'double-float) returns)
      (push (getf episode :first-teacher-disagreement) first-disagreements)
      (dolist (step (getf episode :steps))
        (unless (getf step :opening-pairs)
          (incf policy-steps)
          (let* ((evolved
                   (policy-disagreement-proposal step :evolved))
                 (compiled
                   (policy-disagreement-proposal step :compiled))
                 (teacher-ranking (getf step :teacher-ranking))
                 (teacher-top1 (first teacher-ranking))
                 (teacher-decision (getf step :teacher-decision))
                 (teacher-pair (getf teacher-decision :pair))
                 (teacher-concrete (getf teacher-decision :concrete-action))
                 (evolved-ranking (getf evolved :ranking))
                 (compiled-ranking (getf compiled :ranking))
                 (evolved-top1 (first evolved-ranking))
                 (compiled-top1 (first compiled-ranking))
                 (evolved-decision (getf evolved :decision))
                 (compiled-decision (getf compiled :decision))
                 (evolved-pair (getf evolved-decision :pair))
                 (compiled-pair (getf compiled-decision :pair))
                 (evolved-concrete
                   (getf evolved-decision :concrete-action))
                 (compiled-concrete
                   (getf compiled-decision :concrete-action))
                 (phase (policy-disagreement-phase (getf step :step)))
                 (concrete-agreement-p (= evolved-concrete compiled-concrete)))
            (policy-disagreement-increment phase-counts phase)
            (unless concrete-agreement-p
              (policy-disagreement-increment
               phase-concrete-disagreements phase))
            (when (equal evolved-top1 compiled-top1)
              (incf evolved-compiled-top1-agreements))
            (when (equal evolved-ranking compiled-ranking)
              (incf evolved-compiled-ranking-agreements))
            (when (equal evolved-pair compiled-pair)
              (incf evolved-compiled-resolved-pair-agreements))
            (if concrete-agreement-p
                (progn
                  (incf evolved-compiled-concrete-agreements)
                  (unless (equal evolved-top1 compiled-top1)
                    (incf semantic-different-concrete-same)))
                (progn
                  (policy-disagreement-increment
                   concrete-confusion
                   (list evolved-concrete compiled-concrete))
                  (policy-disagreement-increment
                   semantic-confusion
                   (list evolved-pair compiled-pair))))
            (when (equal evolved-top1 teacher-top1)
              (incf evolved-teacher-top1-agreements))
            (when (equal compiled-top1 teacher-top1)
              (incf compiled-teacher-top1-agreements))
            (when (= evolved-concrete teacher-concrete)
              (incf evolved-teacher-concrete-agreements))
            (when (= compiled-concrete teacher-concrete)
              (incf compiled-teacher-concrete-agreements))
            (if (position teacher-pair evolved-ranking :test #'equal
                          :end (min 8 (length evolved-ranking)))
                (incf teacher-in-evolved-top8)
                (incf teacher-absent-evolved-top8))
            (if (position teacher-pair compiled-ranking :test #'equal
                          :end (min 8 (length compiled-ranking)))
                (incf teacher-in-compiled-top8)
                (incf teacher-absent-compiled-top8))
            (let ((path (getf evolved :preferred-path)))
              (push (length path) path-lengths)
              (dolist (team path)
                (setf (gethash team evolved-teams) t)))
            (policy-disagreement-increment
             evolved-winners (getf evolved :winning-learner))
            (policy-disagreement-increment
             evolved-terminals (getf evolved :terminal-team))
            (when (and (not concrete-agreement-p)
                       (< (length samples)
                          +policy-disagreement-sample-limit+))
              (push (policy-disagreement-compact-step
                     episode step evolved compiled)
                    samples))))))
    (let ((non-null-firsts (remove nil first-disagreements)))
      (list
       :behavior (and episodes (getf (first episodes) :behavior))
       :episodes (length episodes)
       :policy-steps policy-steps
       :return-sum (reduce #'+ returns :initial-value 0.0d0)
       :mean-return (policy-disagreement-mean returns)
       :returns (nreverse returns)
       :episodes-with-teacher-disagreement (length non-null-firsts)
       :first-teacher-disagreement-step-sum
         (reduce #'+ non-null-firsts :initial-value 0)
       :mean-first-teacher-disagreement-step
         (policy-disagreement-mean non-null-firsts)
       :evolved-compiled-top1-agreements
         evolved-compiled-top1-agreements
       :evolved-compiled-top1-agreement-rate
         (policy-disagreement-rate
          evolved-compiled-top1-agreements policy-steps)
       :evolved-compiled-ranking-agreements
         evolved-compiled-ranking-agreements
       :evolved-compiled-ranking-agreement-rate
         (policy-disagreement-rate
          evolved-compiled-ranking-agreements policy-steps)
       :evolved-compiled-resolved-pair-agreements
         evolved-compiled-resolved-pair-agreements
       :evolved-compiled-resolved-pair-agreement-rate
         (policy-disagreement-rate
          evolved-compiled-resolved-pair-agreements policy-steps)
       :evolved-compiled-concrete-agreements
         evolved-compiled-concrete-agreements
       :evolved-compiled-concrete-agreement-rate
         (policy-disagreement-rate
          evolved-compiled-concrete-agreements policy-steps)
       :semantic-different-concrete-same semantic-different-concrete-same
       :semantic-different-concrete-same-rate
         (policy-disagreement-rate semantic-different-concrete-same policy-steps)
       :evolved-teacher-top1-agreement-rate
         (policy-disagreement-rate evolved-teacher-top1-agreements policy-steps)
       :evolved-teacher-top1-agreements evolved-teacher-top1-agreements
       :compiled-teacher-top1-agreement-rate
         (policy-disagreement-rate compiled-teacher-top1-agreements policy-steps)
       :compiled-teacher-top1-agreements compiled-teacher-top1-agreements
       :evolved-teacher-concrete-agreement-rate
         (policy-disagreement-rate evolved-teacher-concrete-agreements policy-steps)
       :evolved-teacher-concrete-agreements
         evolved-teacher-concrete-agreements
       :compiled-teacher-concrete-agreement-rate
         (policy-disagreement-rate compiled-teacher-concrete-agreements policy-steps)
       :compiled-teacher-concrete-agreements
         compiled-teacher-concrete-agreements
       :teacher-in-evolved-top8-rate
         (policy-disagreement-rate teacher-in-evolved-top8 policy-steps)
       :teacher-in-evolved-top8 teacher-in-evolved-top8
       :teacher-absent-evolved-top8 teacher-absent-evolved-top8
       :teacher-in-compiled-top8-rate
         (policy-disagreement-rate teacher-in-compiled-top8 policy-steps)
       :teacher-in-compiled-top8 teacher-in-compiled-top8
       :teacher-absent-compiled-top8 teacher-absent-compiled-top8
       :evolved-path-mean-length
         (policy-disagreement-mean path-lengths)
       :evolved-path-length-sum
         (reduce #'+ path-lengths :initial-value 0)
       :evolved-path-count (length path-lengths)
       :evolved-path-max-length
         (if path-lengths (reduce #'max path-lengths) 0)
       :evolved-unique-path-teams (hash-table-count evolved-teams)
       :evolved-path-team-ids
         (sort (loop for team being the hash-keys of evolved-teams collect team)
               #'string<)
       :evolved-winning-learners
         (policy-disagreement-table-alist
          evolved-winners :sort-by-count-p t)
       :evolved-terminal-teams
         (policy-disagreement-table-alist
          evolved-terminals :sort-by-count-p t)
       :phase-counts (policy-disagreement-table-alist phase-counts)
       :phase-concrete-disagreements
         (policy-disagreement-table-alist phase-concrete-disagreements)
       :phase-summary
         (policy-disagreement-phase-summary
          phase-counts phase-concrete-disagreements)
       :semantic-confusion
         (policy-disagreement-table-alist
          semantic-confusion :sort-by-count-p t)
       :concrete-confusion
         (policy-disagreement-table-alist
          concrete-confusion :sort-by-count-p t)
       :disagreement-samples (nreverse samples)))))

(defun policy-disagreement-merge-count-alists (&rest alists)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (alist alists)
      (dolist (entry alist)
        (policy-disagreement-increment table (car entry) (cdr entry))))
    (policy-disagreement-table-alist table :sort-by-count-p t)))

(defun policy-disagreement-count-from-alist (key alist)
  (or (cdr (assoc key alist :test #'equal)) 0))

(defun merge-policy-disagreement-summaries (left right)
  "Merge two summaries produced for the same behavior without trace retention."
  (cond
    ((null left) right)
    ((null right) left)
    ((not (eq (getf left :behavior) (getf right :behavior)))
     (error "Cannot merge policy summaries for ~S and ~S."
            (getf left :behavior) (getf right :behavior)))
    (t
     (let* ((episodes (+ (getf left :episodes) (getf right :episodes)))
            (policy-steps
              (+ (getf left :policy-steps) (getf right :policy-steps)))
            (return-sum
              (+ (getf left :return-sum) (getf right :return-sum)))
            (first-count
              (+ (getf left :episodes-with-teacher-disagreement)
                 (getf right :episodes-with-teacher-disagreement)))
            (first-sum
              (+ (getf left :first-teacher-disagreement-step-sum)
                 (getf right :first-teacher-disagreement-step-sum)))
            (top1
              (+ (getf left :evolved-compiled-top1-agreements)
                 (getf right :evolved-compiled-top1-agreements)))
            (ranking
              (+ (getf left :evolved-compiled-ranking-agreements)
                 (getf right :evolved-compiled-ranking-agreements)))
            (resolved
              (+ (getf left :evolved-compiled-resolved-pair-agreements)
                 (getf right :evolved-compiled-resolved-pair-agreements)))
            (concrete
              (+ (getf left :evolved-compiled-concrete-agreements)
                 (getf right :evolved-compiled-concrete-agreements)))
            (semantic-same
              (+ (getf left :semantic-different-concrete-same)
                 (getf right :semantic-different-concrete-same)))
            (evolved-teacher-top1
              (+ (getf left :evolved-teacher-top1-agreements)
                 (getf right :evolved-teacher-top1-agreements)))
            (compiled-teacher-top1
              (+ (getf left :compiled-teacher-top1-agreements)
                 (getf right :compiled-teacher-top1-agreements)))
            (evolved-teacher-concrete
              (+ (getf left :evolved-teacher-concrete-agreements)
                 (getf right :evolved-teacher-concrete-agreements)))
            (compiled-teacher-concrete
              (+ (getf left :compiled-teacher-concrete-agreements)
                 (getf right :compiled-teacher-concrete-agreements)))
            (teacher-in-evolved
              (+ (getf left :teacher-in-evolved-top8)
                 (getf right :teacher-in-evolved-top8)))
            (teacher-absent-evolved
              (+ (getf left :teacher-absent-evolved-top8)
                 (getf right :teacher-absent-evolved-top8)))
            (teacher-in-compiled
              (+ (getf left :teacher-in-compiled-top8)
                 (getf right :teacher-in-compiled-top8)))
            (teacher-absent-compiled
              (+ (getf left :teacher-absent-compiled-top8)
                 (getf right :teacher-absent-compiled-top8)))
            (path-sum
              (+ (getf left :evolved-path-length-sum)
                 (getf right :evolved-path-length-sum)))
            (path-count
              (+ (getf left :evolved-path-count)
                 (getf right :evolved-path-count)))
            (path-teams
              (sort
               (remove-duplicates
                (append (copy-list (getf left :evolved-path-team-ids))
                        (copy-list (getf right :evolved-path-team-ids)))
                :test #'equal)
               #'string<))
            (phase-counts
              (policy-disagreement-merge-count-alists
               (getf left :phase-counts) (getf right :phase-counts)))
            (phase-disagreements
              (policy-disagreement-merge-count-alists
               (getf left :phase-concrete-disagreements)
               (getf right :phase-concrete-disagreements)))
            (phase-table (make-hash-table :test #'eq))
            (phase-disagreement-table (make-hash-table :test #'eq))
            (samples
              (subseq
               (append (copy-list (getf left :disagreement-samples))
                       (copy-list (getf right :disagreement-samples)))
               0
               (min +policy-disagreement-sample-limit+
                    (+ (length (getf left :disagreement-samples))
                       (length (getf right :disagreement-samples)))))))
       (dolist (entry phase-counts)
         (setf (gethash (car entry) phase-table) (cdr entry)))
       (dolist (entry phase-disagreements)
         (setf (gethash (car entry) phase-disagreement-table) (cdr entry)))
       (list
        :behavior (getf left :behavior)
        :episodes episodes
        :policy-steps policy-steps
        :return-sum return-sum
        :mean-return (policy-disagreement-rate return-sum episodes)
        :returns (append (copy-list (getf left :returns))
                         (copy-list (getf right :returns)))
        :episodes-with-teacher-disagreement first-count
        :first-teacher-disagreement-step-sum first-sum
        :mean-first-teacher-disagreement-step
          (policy-disagreement-rate first-sum first-count)
        :evolved-compiled-top1-agreements top1
        :evolved-compiled-top1-agreement-rate
          (policy-disagreement-rate top1 policy-steps)
        :evolved-compiled-ranking-agreements ranking
        :evolved-compiled-ranking-agreement-rate
          (policy-disagreement-rate ranking policy-steps)
        :evolved-compiled-resolved-pair-agreements resolved
        :evolved-compiled-resolved-pair-agreement-rate
          (policy-disagreement-rate resolved policy-steps)
        :evolved-compiled-concrete-agreements concrete
        :evolved-compiled-concrete-agreement-rate
          (policy-disagreement-rate concrete policy-steps)
        :semantic-different-concrete-same semantic-same
        :semantic-different-concrete-same-rate
          (policy-disagreement-rate semantic-same policy-steps)
        :evolved-teacher-top1-agreements evolved-teacher-top1
        :evolved-teacher-top1-agreement-rate
          (policy-disagreement-rate evolved-teacher-top1 policy-steps)
        :compiled-teacher-top1-agreements compiled-teacher-top1
        :compiled-teacher-top1-agreement-rate
          (policy-disagreement-rate compiled-teacher-top1 policy-steps)
        :evolved-teacher-concrete-agreements evolved-teacher-concrete
        :evolved-teacher-concrete-agreement-rate
          (policy-disagreement-rate evolved-teacher-concrete policy-steps)
        :compiled-teacher-concrete-agreements compiled-teacher-concrete
        :compiled-teacher-concrete-agreement-rate
          (policy-disagreement-rate compiled-teacher-concrete policy-steps)
        :teacher-in-evolved-top8 teacher-in-evolved
        :teacher-in-evolved-top8-rate
          (policy-disagreement-rate teacher-in-evolved policy-steps)
        :teacher-absent-evolved-top8 teacher-absent-evolved
        :teacher-in-compiled-top8 teacher-in-compiled
        :teacher-in-compiled-top8-rate
          (policy-disagreement-rate teacher-in-compiled policy-steps)
        :teacher-absent-compiled-top8 teacher-absent-compiled
        :evolved-path-length-sum path-sum
        :evolved-path-count path-count
        :evolved-path-mean-length
          (policy-disagreement-rate path-sum path-count)
        :evolved-path-max-length
          (max (getf left :evolved-path-max-length)
               (getf right :evolved-path-max-length))
        :evolved-unique-path-teams (length path-teams)
        :evolved-path-team-ids path-teams
        :evolved-winning-learners
          (policy-disagreement-merge-count-alists
           (getf left :evolved-winning-learners)
           (getf right :evolved-winning-learners))
        :evolved-terminal-teams
          (policy-disagreement-merge-count-alists
           (getf left :evolved-terminal-teams)
           (getf right :evolved-terminal-teams))
        :phase-counts phase-counts
        :phase-concrete-disagreements phase-disagreements
        :phase-summary
          (policy-disagreement-phase-summary
           phase-table phase-disagreement-table)
        :semantic-confusion
          (policy-disagreement-merge-count-alists
           (getf left :semantic-confusion) (getf right :semantic-confusion))
        :concrete-confusion
          (policy-disagreement-merge-count-alists
           (getf left :concrete-confusion) (getf right :concrete-confusion))
        :disagreement-samples samples)))))

(defun policy-disagreement-paired-return-summary (episodes)
  (let ((by-key (make-hash-table :test #'equal)))
    (dolist (episode episodes)
      (setf (gethash (list (getf episode :seed)
                           (getf episode :behavior))
                     by-key)
            (getf episode :return)))
    (loop for seed in (remove-duplicates
                       (mapcar (lambda (episode) (getf episode :seed)) episodes))
          for evolved = (gethash (list seed :evolved) by-key)
          for compiled = (gethash (list seed :compiled) by-key)
          when (and evolved compiled)
            collect (list :seed seed
                          :evolved-controlled-return evolved
                          :compiled-controlled-return compiled
                          :delta (- evolved compiled)))))

(defun write-policy-disagreement-text-report (summary path)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (format out "Policy disagreement analysis~%")
    (format out "protocol: ~A~%" (getf summary :protocol))
    (format out "environment: ~A~%" (getf summary :environment))
    (format out "seeds: ~S~%~%" (getf summary :seeds))
    (dolist (distribution (getf summary :distributions))
      (format out "Behavior: ~A~%" (getf distribution :behavior))
      (format out "  episodes / policy steps: ~D / ~D~%"
              (getf distribution :episodes)
              (getf distribution :policy-steps))
      (format out "  mean return: ~,6F~%" (getf distribution :mean-return))
      (format out "  evolved/compiled top-1 agreement: ~,4F~%"
              (getf distribution :evolved-compiled-top1-agreement-rate))
      (format out "  evolved/compiled full-ranking agreement: ~,4F~%"
              (getf distribution :evolved-compiled-ranking-agreement-rate))
      (format out "  evolved/compiled resolved-pair agreement: ~,4F~%"
              (getf distribution
                    :evolved-compiled-resolved-pair-agreement-rate))
      (format out "  evolved/compiled concrete agreement: ~,4F~%"
              (getf distribution :evolved-compiled-concrete-agreement-rate))
      (format out "  semantic different, concrete same: ~,4F~%"
              (getf distribution :semantic-different-concrete-same-rate))
      (format out "  evolved/teacher concrete agreement: ~,4F~%"
              (getf distribution :evolved-teacher-concrete-agreement-rate))
      (format out "  compiled/teacher concrete agreement: ~,4F~%"
              (getf distribution :compiled-teacher-concrete-agreement-rate))
      (format out "  teacher in evolved top-8: ~,4F (absent ~D)~%"
              (getf distribution :teacher-in-evolved-top8-rate)
              (getf distribution :teacher-absent-evolved-top8))
      (format out "  evolved path mean/max: ~,3F / ~D; unique teams: ~D~%~%"
              (getf distribution :evolved-path-mean-length)
              (getf distribution :evolved-path-max-length)
              (getf distribution :evolved-unique-path-teams))
      (dolist (phase (getf distribution :phase-summary))
        (format out "  ~A concrete disagreement: ~D/~D (~,4F)~%"
                (getf phase :phase)
                (getf phase :concrete-disagreements)
                (getf phase :steps)
                (getf phase :concrete-disagreement-rate)))
      (terpri out))
    (format out "Paired same-root returns (not event-keyed counterfactuals):~%")
    (dolist (record (getf summary :paired-returns))
      (format out "  seed ~D: evolved=~,4F compiled=~,4F delta=~,4F~%"
              (getf record :seed)
              (getf record :evolved-controlled-return)
              (getf record :compiled-controlled-return)
              (getf record :delta))))
  path)

(defun run-policy-disagreement-analysis
       (evolved-path compiled-path output-directory seeds
        &key (environment-name "Cage2-b_line-100-v0")
             (write-trajectories-p nil))
  "Compare evolved and compiled policies on both policies' official trajectories."
  (unless seeds
    (error "Policy disagreement analysis requires at least one seed."))
  (let* ((output-directory (uiop:ensure-directory-pathname output-directory))
         (*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*instruction-set-profile* :reduced)
         (*read-only-register-profile* :cage2-categorical-v1)
         (*decoy-order-mode* :fixed)
         (*cage2-opening-mode* :fixed)
         (*teacher-backend* :heuristic)
         (*recurrent-policy-enabled* nil)
         (*hamming-space-enabled* nil)
         (policies
           (list (rare-failure-load-policy :evolved evolved-path)
                 (rare-failure-load-policy :compiled compiled-path)))
         (env nil)
         (controller nil)
         (evolved-summary nil)
         (compiled-summary nil)
         (paired-returns nil)
         (saved-trajectories nil))
    (py4cl2:pyexec "import gymnasium as gym; import cage2_bridge")
    (setf env (cl-gym::make environment-name)
          controller (make-cage2-controller :decoy-order-profile :heuristic))
    (cl-gym::configure-cage2-controller-option-orders env controller)
    (unwind-protect
         (loop for seed in seeds
               for episode-index fixnum from 1
               do (let ((evolved-return nil)
                        (compiled-return nil))
                    (dolist (behavior '(:evolved :compiled))
                      (let* ((episode
                               (rare-failure-trace-episode
                                env controller policies behavior
                                environment-name seed))
                             (episode-summary
                               (summarize-policy-disagreement-episodes
                                (list episode))))
                        (if (eq behavior :evolved)
                            (setf evolved-return (getf episode :return)
                                  evolved-summary
                                    (merge-policy-disagreement-summaries
                                     evolved-summary episode-summary))
                            (setf compiled-return (getf episode :return)
                                  compiled-summary
                                    (merge-policy-disagreement-summaries
                                     compiled-summary episode-summary)))
                        (when write-trajectories-p
                          (push episode saved-trajectories))))
                    (push (list :seed seed
                                :evolved-controlled-return evolved-return
                                :compiled-controlled-return compiled-return
                                :delta (- evolved-return compiled-return))
                          paired-returns)
                    (when (or (<= episode-index 3)
                              (zerop (mod episode-index 25))
                              (= episode-index (length seeds)))
                      (format t
                              "policy-disagreement episodes=~D/~D seed=~D evolved=~,4F compiled=~,4F~%"
                              episode-index (length seeds) seed
                              evolved-return compiled-return)
                      (finish-output))))
      (when env
        (ignore-errors (py4cl2:pymethod env "close"))))
    (let ((summary
             (list
              :protocol +policy-disagreement-analysis-protocol+
              :environment environment-name
              :seeds (copy-list seeds)
              :policies
                (mapcar
                 (lambda (policy)
                   (list :label (getf policy :label)
                         :path (getf policy :path)
                         :fitness (getf policy :fitness)
                         :generation (getf policy :generation)
                         :effective-code
                           (policy-disagreement-effective-summary policy)))
                 policies)
              :distributions
                (list evolved-summary compiled-summary)
              :paired-returns (nreverse paired-returns)
              :same-root-warning
                "Same seed couples initial RNG state only; diverged trajectories may consume randomness differently.")))
      (rare-failure-write-form
       summary (merge-pathnames "summary.sexp" output-directory))
      (write-policy-disagreement-text-report
       summary (merge-pathnames "report.txt" output-directory))
      (when write-trajectories-p
        (rare-failure-write-form
         (nreverse saved-trajectories)
         (merge-pathnames "trajectories.sexp" output-directory)))
      summary)))

(defun policy-disagreement-parse-seeds (text)
  (let ((seeds
          (loop for start = 0 then (1+ comma)
                for comma = (position #\, text :start start)
                for token = (string-trim '(#\Space #\Tab)
                                         (subseq text start comma))
                collect (parse-integer token)
                while comma)))
    (unless (every (lambda (seed) (and (integerp seed) (not (minusp seed))))
                   seeds)
      (error "Seeds must be non-negative integers, got ~S." seeds))
    seeds))

(defun run-policy-disagreement-analysis-from-environment ()
  (flet ((required (name)
           (or (uiop:getenv name)
               (error "Required environment variable ~A is missing." name))))
    (run-policy-disagreement-analysis
     (required "POLICY_ANALYSIS_EVOLVED_CHECKPOINT")
     (required "POLICY_ANALYSIS_COMPILED_CHECKPOINT")
     (required "POLICY_ANALYSIS_OUTPUT_DIRECTORY")
     (policy-disagreement-parse-seeds
      (required "POLICY_ANALYSIS_SEEDS"))
     :environment-name
       (or (uiop:getenv "POLICY_ANALYSIS_ENVIRONMENT")
           "Cage2-b_line-100-v0")
     :write-trajectories-p
       (member (string-downcase
                (or (uiop:getenv "POLICY_ANALYSIS_WRITE_TRAJECTORIES") "false"))
               '("1" "true" "yes") :test #'string=))))
