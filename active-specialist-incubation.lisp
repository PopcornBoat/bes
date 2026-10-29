(in-package :cl-tpg)

(defun incubation-file-sha256 (path)
  "Hash an immutable admission artifact before using it in a live search."
  (let ((output
          (uiop:run-program (list "sha256sum" (namestring (pathname path)))
                            :output :string)))
    (subseq output 0 64)))

(defun incubation-observation (source)
  "Materialize a policy observation with the program executor's array type."
  (unless (= (length source) *num-observations*)
    (error "Incubation observation has ~D values, expected ~D."
           (length source) *num-observations*))
  (make-array *num-observations* :element-type 'double-float
              :initial-contents (map 'list
                                     (lambda (value)
                                       (coerce value 'double-float))
                                     source)))

(defun incubation-instruction (destination op type1 value1 type2 value2)
  (%make-instruction
   :dest destination :op op :arity 2
   :src1-type type1 :src1-val (coerce value1 'double-float)
   :src2-type type2 :src2-val (coerce value2 'double-float)))

(defun incubation-gate-program (predicates margin)
  "Bid positive only on an exact one- or two-feature categorical gate."
  (unless (and (<= 1 (length predicates) 2)
               (member (coerce margin 'double-float)
                       '(250.0d0 1000.0d0)))
    (error "Invalid incubation gate or margin."))
  (let ((program
          (make-program
           :instructions (make-array 0 :fill-pointer 0 :adjustable t))))
    (loop for predicate in predicates
          for destination from 1
          for index = (first predicate)
          for ror = (second predicate)
          do (unless (and (integerp index)
                          (<= 0 index) (< index *num-observations*)
                          (integerp ror)
                          (<= 0 ror)
                          (< ror (active-read-only-register-count)))
               (error "Invalid incubation predicate ~S." predicate))
             (vector-push-extend
              (incubation-instruction destination :eq
                                      :obs index :ror ror)
              (program-instructions program)))
    (when (= (length predicates) 2)
      (vector-push-extend
       (incubation-instruction 1 :mul :reg 1 :reg 2)
       (program-instructions program)))
    (dolist (instruction
              (list
               (incubation-instruction 1 :mul :reg 1 :const 2.0d0)
               (incubation-instruction 1 :add :reg 1 :const -1.0d0)
               (incubation-instruction +bid-register+ :mul
                                       :reg 1 :const margin)))
      (vector-push-extend instruction (program-instructions program)))
    program))

(defun incubation-policy-pair (team observation)
  (semantic-action-category-pair
   (execute-team-semantic team observation)))

(defun incubation-child (incumbent candidate)
  "Copy the complete graph, then inject one standalone TPG learner."
  (let* ((observation
           (incubation-observation (getf candidate :probe)))
         (source-terminal
           (nth-value 2
                      (execute-team-semantic-ranked
                       incumbent observation)))
         (child (deep-copy-team-via-serialization incumbent))
         (destination
           (if (eq (getf candidate :insertion) :root)
               child
               (nth-value 2
                          (execute-team-semantic-ranked
                           child observation))))
         (learner
           (make-learner
            :program (incubation-gate-program
                      (getf candidate :predicates)
                      (getf candidate :margin))
            :action
              (make-action
               :type :atomic
               :action (make-target-response-36-action
                        :target (getf candidate :target)
                        :response (getf candidate :response))))))
    (unless (and source-terminal
                 (string= (team-id source-terminal)
                          (getf candidate :terminal))
                 destination)
      (error "Incubation source terminal changed for ~A."
             (getf candidate :id)))
    ;; The normal learner limit is set by the training menu.  This standalone
    ;; experiment uses a fixed bound so a missing menu binding cannot bypass it.
    (when (>= (length (team-learners destination)) 32)
      (return-from incubation-child nil))
    (push learner (team-learners destination))
    child))

(defun incubation-probe-child (incumbent child candidate)
  "Reject inactive or broadly collateral variants before official rollout."
  (let* ((probe (incubation-observation (getf candidate :probe)))
         (desired (list (getf candidate :target)
                        (getf candidate :response)))
         (before (incubation-policy-pair incumbent probe))
         (after (incubation-policy-pair child probe))
         (background
           (getf candidate :background))
         (changed
           (loop for raw across (coerce background 'vector)
                 for observation = (incubation-observation raw)
                 count (not (equal
                             (incubation-policy-pair incumbent observation)
                             (incubation-policy-pair child observation))))))
    (list :probe-before before :probe-after after
          :background-changes changed
          :background-count (length background)
          :accepted (and (not (equal before after))
                         (equal after desired)
                         (<= changed
                             (floor (length background) 2))))))

(defun build-incubation-candidates
       (checkpoint manifest-path output-directory environment-name)
  "Save only behaviorally active, bounded-collateral candidate checkpoints."
  (let* ((*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*instruction-set-profile* :reduced-eq)
         (*read-only-register-profile* :cage2-categorical-v1)
         (*decoy-order-mode* :fixed)
         (*cage2-opening-mode* :fixed)
         (*recurrent-policy-enabled* nil)
         (manifest (rare-failure-read-form manifest-path))
         (source (multiple-value-list (load-best-team checkpoint)))
         (incumbent (first source))
         (metadata (third source))
         (records nil))
    (unless (eq (getf manifest :protocol)
                :active-specialist-incubation-v1)
      (error "Unknown incubation candidate manifest."))
    (setf *instruction-set-profile*
          (getf metadata :instruction-set-profile :reduced-eq)
          *read-only-register-profile*
          (getf metadata :read-only-register-profile
                :cage2-categorical-v1))
    (ensure-directories-exist
     (merge-pathnames "placeholder" output-directory))
    (dolist (candidate (getf manifest :candidates))
      (let* ((child (incubation-child incumbent candidate))
             (probe (and child
                         (incubation-probe-child
                          incumbent child candidate)))
             (path
               (merge-pathnames
                (format nil "~A.lisp" (getf candidate :id))
                output-directory))
             (accepted (and probe (getf probe :accepted))))
        (when accepted
          (write-best-team-checkpoint
           child 0.0d0 path
           :gym-environment-name environment-name
           :generation (getf metadata :generation)
           :online-fitness-episodes
             (getf metadata :online-fitness-episodes)
           :search-seed (getf metadata :search-seed)
           :fitness-evaluation-protocol
             :active-specialist-incubation-v1
           :action-agreement-signature
             (getf metadata :action-agreement-signature)
           :num-observations 62
           :decoy-order-mode :fixed
           :cage2-opening-mode :fixed
           :recurrent-policy-enabled nil
           :teacher-backend (getf metadata :teacher-backend :heuristic)
           :instruction-set-profile *instruction-set-profile*
           :read-only-register-profile *read-only-register-profile*
           :terminal-action-format :target-response-36))
        (push
         (list :id (getf candidate :id)
               :lane (getf candidate :lane)
               :group (getf candidate :group)
               :target (getf candidate :target)
               :response (getf candidate :response)
               :accepted accepted
               :checkpoint-path (and accepted (namestring path))
               :probe probe)
         records)))
    (let ((summary
            (list :protocol :active-specialist-incubation-v1
                  :incumbent-checkpoint checkpoint
                  :candidate-manifest manifest-path
                  :candidates (nreverse records))))
      (rare-failure-write-form
       summary (merge-pathnames "candidate-summary.sexp" output-directory))
      (with-open-file
          (out (merge-pathnames "accepted-count.txt" output-directory)
               :direction :output :if-exists :supersede
               :if-does-not-exist :create)
        (format out "~D~%"
                (count-if (lambda (row) (getf row :accepted))
                          (getf summary :candidates))))
      summary)))

(defun write-incubation-admission-request
       (summary-path request-path result-path environment-name seed-root
        &key candidate-limit candidate-ids (tournament-count 100))
  "Prepare a fresh-seed official tournament for the accepted specialists."
  (let* ((summary (rare-failure-read-form summary-path))
         (candidates
           (let ((accepted
                   (remove-if-not
                    (lambda (row)
                      (and (getf row :accepted)
                           (or (null candidate-ids)
                               (member (getf row :id) candidate-ids
                                       :test #'string=))))
                    (getf summary :candidates))))
             (if candidate-limit
                 (subseq accepted 0 (min candidate-limit (length accepted)))
                 accepted)))
         (cheap-seeds
           (loop for index below 2
                 collect (+ seed-root (* index 197))))
         (tournament-seeds
           (loop for index below tournament-count
                 collect (+ seed-root 100000 (* index 197)))))
    (unless candidates
      (error "No behaviorally active incubation candidates to admit."))
    (write-readable-object-atomically
     (list :version 2
           :protocol +official-admission-protocol+
           :incumbent-path (getf summary :incumbent-checkpoint)
           :incumbent-sha256
             (incubation-file-sha256
              (getf summary :incumbent-checkpoint))
           :incumbent-version 0
           :result-path result-path
           :gym-environment-name environment-name
           :num-observations 62
           :num-actions 36
           :decoy-order-mode :fixed
           :cage2-opening-mode :fixed
           :teacher-backend :heuristic
           :seeds cheap-seeds
           :tournament-seeds tournament-seeds
           :tournament-stages
             (copy-list +official-admission-tournament-stages+)
           :max-policy-workers +official-admission-max-policy-workers+
           :candidates
             (mapcar
              (lambda (row)
                (list :candidate-id (getf row :id)
                      :candidate-path (getf row :checkpoint-path)
                      :candidate-sha256
                        (incubation-file-sha256
                         (getf row :checkpoint-path))
                      :candidate-generation 0
                      :candidate-imitation-score 0.0d0
                      :lanes (list :active-specialist-incubation)))
              candidates))
     request-path)
    (list :accepted-candidates (length candidates)
          :request-path request-path
          :result-path result-path
          :cheap-seeds cheap-seeds
          :tournament-seed-count (length tournament-seeds))))

(defun summarize-incubation-admission
       (result-path summary-path output-path)
  "Report official evidence by hypothesis and lane without promoting a graph."
  (let* ((result (rare-failure-read-form result-path))
         (summary (rare-failure-read-form summary-path))
         (records
           (loop for candidate in (getf summary :candidates)
                 when (getf candidate :accepted)
                   collect
                   (let* ((official
                            (find (getf candidate :id)
                                  (getf result :candidate-results)
                                  :key (lambda (row)
                                         (getf row :candidate-id))
                                  :test #'string=))
                          (last-stage
                            (car (last (getf official :tournament-stages)))))
                     (list :id (getf candidate :id)
                           :group (getf candidate :group)
                           :lane (getf candidate :lane)
                           :target (getf candidate :target)
                           :response (getf candidate :response)
                           :cheap-keep (getf official :keep)
                           :cheap-paired-mean
                             (getf official :paired-mean)
                           :tournament-episodes
                             (getf last-stage :episode-count 0)
                           :tournament-paired-mean
                             (getf last-stage :paired-mean)
                           :tournament-selected
                             (getf official :tournament-selected)))))
         (report
           (list :protocol :active-specialist-incubation-v1
                 :official-status (getf result :status)
                 :official-error (getf result :message)
                 :official-winner (getf result :winner-id)
                 :records records
                 :meander-user2-restore-soft-metric
                   (list :generated
                         (count-if
                          (lambda (row)
                            (and (= (getf row :target) 8)
                                 (= (getf row :response) 2)))
                          records)
                         :cheap-kept
                         (count-if
                          (lambda (row)
                            (and (= (getf row :target) 8)
                                 (= (getf row :response) 2)
                                 (getf row :cheap-keep)))
                          records)
                         :tournament-selected
                         (count-if
                          (lambda (row)
                            (and (= (getf row :target) 8)
                                 (= (getf row :response) 2)
                                 (getf row :tournament-selected)))
                          records)))))
    (unless (eq (getf result :status) :complete)
      (error "Incubation official admission failed: ~A"
             (getf result :message)))
    (rare-failure-write-form report output-path)
    report))

(defun incubation-write-winner-path (result-path output-path)
  "Write the selected candidate's path for a separate rollout audit."
  (let* ((result (rare-failure-read-form result-path))
         (winner
           (find (getf result :winner-id)
                 (getf result :candidate-results)
                 :key (lambda (row) (getf row :candidate-id))
                 :test #'equal)))
    (with-open-file (out output-path :direction :output
                        :if-exists :supersede
                        :if-does-not-exist :create)
      (when winner
        (write-line (getf winner :candidate-path) out)))
    (and winner (getf winner :candidate-path))))

(defun incubation-write-winner-id (result-path output-path)
  "Write the tournament winner ID for a frozen independent confirmation."
  (let ((winner-id
          (getf (rare-failure-read-form result-path) :winner-id)))
    (with-open-file (out output-path :direction :output
                        :if-exists :supersede
                        :if-does-not-exist :create)
      (when winner-id
        (write-line winner-id out)))
    winner-id))

(defun summarize-incubation-confirmation (result-path output-path)
  "Record the fresh fixed-candidate official comparison before population import."
  (let* ((result (rare-failure-read-form result-path))
         (record (first (getf result :candidate-results)))
         (last-stage
           (and record
                (car (last (getf record :tournament-stages)))))
         (report
           (list :status (getf result :status)
                 :candidate-id (getf record :candidate-id)
                 :winner-id (getf result :winner-id)
                 :episode-count (getf last-stage :episode-count 0)
                 :paired-mean (getf last-stage :paired-mean)
                 :paired-se (getf last-stage :paired-se)
                 :same-seed-correlation
                   (getf last-stage :same-seed-correlation)
                 :eligible-for-import
                   (and record
                        (getf record :tournament-selected)
                        (official-admission-evidence-eligible-p record)
                        (>= (getf last-stage :episode-count 0) 100)))))
    (unless (eq (getf result :status) :complete)
      (error "Specialist confirmation failed: ~A" (getf result :message)))
    (rare-failure-write-form report output-path)
    report))

(defun incubation-confirmed-winner
       (request confirmation-request confirmation-result winner)
  "Return the separately confirmed record, or NIL when evidence is weak."
  (let* ((spec
           (find (getf winner :candidate-id)
                 (getf confirmation-request :candidates)
                 :key (lambda (row) (getf row :candidate-id))
                 :test #'equal))
         (record
           (find (getf winner :candidate-id)
                 (getf confirmation-result :candidate-results)
                 :key (lambda (row) (getf row :candidate-id))
                 :test #'equal))
         (initial-seeds
           (append (getf request :seeds)
                   (getf request :tournament-seeds)))
         (confirmation-seeds
           (append (getf confirmation-request :seeds)
                   (getf confirmation-request :tournament-seeds)))
         (last-stage
           (and record
                (car (last (getf record :tournament-stages))))))
    (when (and spec record
               (= (length (getf confirmation-request :candidates)) 1)
               (= (length (getf confirmation-result :candidate-results)) 1)
               (eq (getf confirmation-result :status) :complete)
               (eq (getf confirmation-result :protocol)
                   +official-admission-protocol+)
               (equal (getf request :incumbent-sha256)
                      (getf confirmation-request :incumbent-sha256))
               (equal (getf request :incumbent-path)
                      (getf confirmation-request :incumbent-path))
               (equal (getf request :gym-environment-name)
                      (getf confirmation-request :gym-environment-name))
               (= (getf request :num-observations)
                  (getf confirmation-request :num-observations))
               (= (getf request :num-actions)
                  (getf confirmation-request :num-actions))
               (= (getf confirmation-request :incumbent-version)
                  (getf confirmation-result :incumbent-version))
               (equal (getf confirmation-result :winner-id)
                      (getf winner :candidate-id))
               (equal (getf spec :candidate-path)
                      (getf winner :candidate-path))
               (equal (getf spec :candidate-sha256)
                      (incubation-file-sha256
                       (getf spec :candidate-path)))
               (equal (getf record :candidate-path)
                      (getf spec :candidate-path))
               (equal (getf confirmation-request :seeds)
                      (getf confirmation-result :seeds))
               (equal (getf confirmation-request :tournament-seeds)
                      (getf confirmation-result :tournament-seeds))
               (null (intersection initial-seeds confirmation-seeds
                                   :test #'=))
               (getf record :tournament-selected)
               (official-admission-evidence-eligible-p record)
               last-stage
               (>= (getf last-stage :episode-count 0) 100))
      record)))

(defun maybe-import-incubation-admission (warm-start-path)
  "Admit verified specialist evidence into a matching official warm start.

This only creates bounded evidence anchors and queues the tournament winner
for the existing fresh-seed full promotion protocol.  It never changes the
historical best directly.  The request is consumed at most once per process."
  (when *incubation-admission-import-request*
    (unless (and (official-admission-active-p)
                 (null *official-admission-job*)
                 (null *online-candidate-job*)
                 (null *official-admission-full-queue*))
      (error "Specialist admission import requires an idle official-guided warm start."))
    (unless *incubation-confirmation-request*
      (error "Specialist import requires a fresh independent confirmation request."))
    (let* ((request
             (rare-failure-read-form
              *incubation-admission-import-request*))
           (result
             (rare-failure-read-form (getf request :result-path)))
           (confirmation-request
             (rare-failure-read-form *incubation-confirmation-request*))
           (confirmation-result
             (rare-failure-read-form
              (getf confirmation-request :result-path)))
           (winner
             (find (getf result :winner-id)
                   (getf result :candidate-results)
                   :key (lambda (record)
                          (getf record :candidate-id))
                   :test #'equal))
           (confirmed
             (and winner
                  (incubation-confirmed-winner
                   request confirmation-request
                   confirmation-result winner))))
      (unless (and (eq (getf request :protocol)
                       +official-admission-protocol+)
                   (eq (getf result :status) :complete)
                   (eq (getf result :protocol)
                       +official-admission-protocol+)
                   (equal (truename (getf request :incumbent-path))
                          (truename warm-start-path))
                   (equal (getf request :incumbent-sha256)
                          (incubation-file-sha256 warm-start-path))
                   (equal (getf request :seeds) (getf result :seeds))
                   (equal (getf request :tournament-seeds)
                          (getf result :tournament-seeds))
                   (= (length (getf request :candidates))
                      (length (getf result :candidate-results)))
                   (= (getf request :incumbent-version)
                      (getf result :incumbent-version))
                   (= (getf request :num-observations)
                      *num-observations*)
                   (= (getf request :num-actions) *num-actions*)
                   (equal (getf request :gym-environment-name)
                          *current-gym-environment-name*)
                   (every
                    (lambda (candidate)
                      (let ((record
                              (find (getf candidate :candidate-id)
                                    (getf result :candidate-results)
                                    :key (lambda (row)
                                           (getf row :candidate-id))
                                    :test #'equal)))
                        (and record
                             (equal (getf candidate :candidate-path)
                                    (getf record :candidate-path))
                             (equal (getf candidate :candidate-sha256)
                                    (incubation-file-sha256
                                     (getf candidate :candidate-path))))))
                    (getf request :candidates)))
        (error "Specialist admission does not match the current warm start or its frozen artifacts."))
      (unless confirmed
        (error "Specialist winner lacks positive independent 100-episode official confirmation."))
      (let ((anchors
              (official-admission-install-batch-evidence
               (getf confirmation-result :candidate-results))))
        (setf *official-admission-full-queue*
              (list
               (list :candidate-path
                       (getf confirmed :candidate-path)
                     :candidate-generation *generation*
                     :candidate-imitation-score
                       (getf confirmed :candidate-imitation-score)
                     :lanes (copy-list (getf confirmed :lanes))
                     :admission-evidence (copy-tree confirmed))))
        (setf *incubation-admission-import-request* nil
              *incubation-confirmation-request* nil)
        (persist-official-guided-runtime-state)
        (emit-message
         (format nil
                 "Specialist admission imported: evidence-anchors=~D winner=~A fresh-promotion-queued=~D."
                 (length anchors)
                 (or (and winner (getf winner :candidate-id)) :none)
                 (length *official-admission-full-queue*)))))))
