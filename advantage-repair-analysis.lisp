(in-package :cl-tpg)

(defun advantage-repair-development-analysis (input-path output-path)
  "Inspect official-advantage contexts before any genotype modification."
  (let* ((*num-observations* 62)
         (*read-only-register-profile* :cage2-categorical-v1)
         (data (rare-failure-read-form input-path))
         (eligible
           (remove-if-not
            (lambda (record) (eq (getf record :status) :eligible))
            (getf data :records)))
         (positive
           (remove-if-not
            (lambda (record)
              (> (getf record :paired-delta) 0.5d0))
            eligible))
         (negative
           (remove-if-not
            (lambda (record)
              (< (getf record :paired-delta) -0.5d0))
            eligible))
         (positive-ids (make-hash-table :test #'equal))
         (positive-observations (make-hash-table :test #'equal))
         (protected nil)
         (conflicts nil)
         (observation-groups (make-hash-table :test #'equal))
         (contexts
           (mapcar
            (lambda (record)
              (list :observation
                    (coerce (getf record :policy-observation) 'vector)))
            positive)))
    (dolist (record positive)
      (setf (gethash (list (getf record :seed)
                           (getf record :step))
                     positive-ids)
            t)
      (push record
            (gethash (getf record :policy-observation)
                     positive-observations)))
    (dolist (record eligible)
      (push record
            (gethash (getf record :policy-observation)
                     observation-groups))
      (when (and (not (member record positive :test #'eq))
                 (gethash (getf record :policy-observation)
                          positive-observations))
        (push record conflicts)))
    (dolist (entry (getf data :background))
      (unless (gethash (list (getf entry :seed)
                             (getf entry :step))
                       positive-ids)
        (push (coerce (getf entry :observation) 'vector)
              protected)))
    (setf protected (nreverse protected))
    (let* ((conjunctions
             (incumbent-conservative-conjunctions contexts protected))
           (result
             (list :protocol :advantage-repair-development-analysis-v1
                   :input input-path
                   :eligible (length eligible)
                   :positive (length positive)
                   :negative (length negative)
                   :zero-or-small
                     (- (length eligible)
                        (length positive)
                        (length negative))
                   :positive-by-step
                     (loop for step in '(20 40)
                           collect (cons step
                                         (count step positive
                                                :key (lambda (x)
                                                       (getf x :step)))))
                   :negative-by-step
                     (loop for step in '(20 40)
                           collect (cons step
                                         (count step negative
                                                :key (lambda (x)
                                                       (getf x :step)))))
                   :exact-positive-protected-conflicts
                     (length conflicts)
                   :positive-overlap-negative
                     (count-if (lambda (record)
                                 (gethash (getf record :policy-observation)
                                          positive-observations))
                               negative)
                   :unique-eligible-observations
                     (hash-table-count observation-groups)
                   :positive-observation-groups
                     (loop for observation being the hash-keys of observation-groups
                             using (hash-value rows)
                           when (gethash observation positive-observations)
                             collect
                             (list :observation observation
                                   :background-exact-count
                                     (count (coerce observation 'vector) protected :test #'equalp)
                                   :count (length rows)
                                   :mean-delta
                                     (/ (reduce #'+ rows
                                                :key (lambda (x)
                                                       (getf x :paired-delta)))
                                        (coerce (length rows) 'double-float))
                                   :step-20-count
                                     (count 20 rows :key (lambda (x)
                                                           (getf x :step)))
                                   :alternative-91-count
                                     (count 91 rows :key (lambda (x)
                                                           (getf x :alternative-concrete)))
                                   :positive
                                     (count-if (lambda (x)
                                                 (> (getf x :paired-delta) 0.5d0))
                                               rows)
                                   :negative
                                     (count-if (lambda (x)
                                                 (< (getf x :paired-delta) -0.5d0))
                                               rows)
                                   :episodes
                                     (mapcar
                                      (lambda (x)
                                        (list (getf x :seed)
                                              (getf x :step)
                                              (getf x :paired-delta)
                                              (getf x :alternative-concrete)))
                                      rows)))
                   :protected-observations (length protected)
                   :candidate-conjunctions (length conjunctions)
                   :top-conjunctions
                     (subseq conjunctions
                             0 (min 20 (length conjunctions))))))
      (rare-failure-write-form result output-path)
      result)))





(defun advantage-repair-graph-audit (analysis-path checkpoint output-path)
  "Locate the executable route behind each observed advantage group."
  (let* ((*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*instruction-set-profile* :full)
         (*read-only-register-profile* :disabled)
         (*recurrent-policy-enabled* nil)
         (analysis (rare-failure-read-form analysis-path))
         (policy (rare-failure-load-policy :graph-audit checkpoint))
         (team (getf policy :team))
         (metadata (getf policy :metadata)))
    (setf *instruction-set-profile*
          (or (getf metadata :instruction-set-profile) :full)
          *read-only-register-profile*
          (or (getf metadata :read-only-register-profile) :disabled))
    (let ((groups
            (loop for group in (getf analysis :positive-observation-groups)
                  for observation =
                    (make-array 62 :element-type 'double-float
                                   :initial-contents
                                     (getf group :observation))
                  collect
                    (multiple-value-bind (ranking path terminal-team)
                        (execute-team-semantic-ranked team observation)
                      (multiple-value-bind (terminal registers)
                          (execute-team-to-terminal team observation)
                        (declare (ignore registers))
                        (list :count (getf group :count)
                              :mean-delta (getf group :mean-delta)
                              :positive (getf group :positive)
                              :negative (getf group :negative)
                              :path (mapcar #'team-id path)
                              :terminal-team (and terminal-team
                                                  (team-id terminal-team))
                              :terminal-learner (learner-id terminal)
                              :terminal-bids
                                (mapcar
                                 (lambda (learner)
                                   (let* ((action (learner-action learner))
                                          (payload (action-action action)))
                                     (list (learner-id learner)
                                           (and (eq (action-type action) :atomic)
                                                (target-response-36-action-p payload)
                                                (list (target-response-36-action-target payload)
                                                      (target-response-36-action-response payload)))
                                           (bid learner observation))))
                                 (team-learners terminal-team))
                              :top8 (mapcar #'semantic-action-category-pair
                                            ranking)
                              :root-bids
                                (mapcar
                                 (lambda (learner)
                                   (list (learner-id learner)
                                         (bid learner observation)))
                                 (team-learners team))))))))
      (let ((result
              (list :protocol :advantage-repair-graph-audit-v1
                    :checkpoint checkpoint
                    :analysis analysis-path
                    :groups groups)))
        (rare-failure-write-form result output-path)
        result))))
