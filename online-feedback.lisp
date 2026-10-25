(in-package :cl-tpg)

;;; Online feedback uses complete official episodes. Stored observations are not
;;; used as a reward model, and the protected reference bank is monitoring only.

(defun online-feedback-active-p ()
  (and *online-feedback-racing-enabled*
       (eq *current-search-mode* :online)
       *current-gym-environment-name*
       (cl-gym:cage2-environment-p *current-gym-environment-name*)))

(defun reset-online-feedback-state ()
  (setf *online-feedback-racing-cursor* 0
        *online-feedback-promotion-cursor* 0
        *online-feedback-seed-root* *current-search-seed*
        *online-feedback-incumbent-version* 0
        *online-feedback-nominations* nil
        *online-feedback-random-seen* 0
        *online-feedback-probes* nil
        *online-feedback-probe-observations* nil
        *online-feedback-probe-contexts* nil))

(defun online-feedback-state-copy ()
  (when (online-feedback-active-p)
    (list :protocol +online-feedback-protocol+
          :seed-root *online-feedback-seed-root*
          :racing-cursor *online-feedback-racing-cursor*
          :promotion-cursor *online-feedback-promotion-cursor*
          :incumbent-version *online-feedback-incumbent-version*)))

(defun restore-online-feedback-state (state)
  (when state
    (unless (and (eq (getf state :protocol) +online-feedback-protocol+)
                 (integerp (getf state :seed-root))
                 (every (lambda (value)
                          (and (integerp value) (not (minusp value))))
                        (list (getf state :racing-cursor)
                              (getf state :promotion-cursor)
                              (getf state :incumbent-version))))
      (error "Invalid online feedback checkpoint state: ~S" state))
    (setf *online-feedback-seed-root* (getf state :seed-root)
          *online-feedback-racing-cursor* (getf state :racing-cursor)
          *online-feedback-promotion-cursor* (getf state :promotion-cursor)
          *online-feedback-incumbent-version*
            (getf state :incumbent-version))))

(defun online-feedback-take-seeds (stream count)
  "Return fresh, disjoint racing or promotion seeds and advance its cursor."
  (unless (and (member stream '(:racing :promotion))
               (integerp count) (plusp count)
               (integerp *online-feedback-seed-root*))
    (error "Invalid online feedback seed request: ~S ~S" stream count))
  (let* ((cursor (ecase stream
                   (:racing *online-feedback-racing-cursor*)
                   (:promotion *online-feedback-promotion-cursor*)))
         (root (official-guided-derived-root
                *online-feedback-seed-root*
                (ecase stream (:racing 909031) (:promotion 909071))))
         (seeds (loop for offset below count
                      collect (official-guided-seed-at
                               stream root (+ cursor offset)))))
    (ecase stream
      (:racing (incf *online-feedback-racing-cursor* count))
      (:promotion (incf *online-feedback-promotion-cursor* count)))
    seeds))

(defun online-feedback-runtime-path ()
  (checkpoint-path *checkpoint-directory* ".online-feedback-state.lisp"))

(defun persist-online-feedback-state ()
  "Durably record cursors even when a racing worker rejects its challenger."
  (when (and (online-feedback-active-p) *checkpoint-directory*
             *best-fitness*)
    (write-readable-object-atomically
     (list :state (online-feedback-state-copy)
           :incumbent-fitness *best-fitness*)
     (online-feedback-runtime-path))))

(defun restore-online-feedback-runtime-state (metadata)
  "Use a newer sidecar only if it belongs to the saved incumbent."
  (let ((saved (getf metadata :online-feedback-state)))
    (restore-online-feedback-state saved)
    (when (and saved *checkpoint-directory*
               (probe-file (online-feedback-runtime-path)))
      (let* ((journal (read-readable-object
                       (online-feedback-runtime-path)))
             (candidate (getf journal :state)))
        (when (and candidate
                   (= (getf candidate :seed-root)
                      (getf saved :seed-root))
                   (= (getf candidate :incumbent-version)
                      (getf saved :incumbent-version))
                   (fitness-values-equivalent-p
                    (getf journal :incumbent-fitness)
                    (getf metadata :fitness))
                   (>= (getf candidate :racing-cursor)
                       (getf saved :racing-cursor))
                   (>= (getf candidate :promotion-cursor)
                       (getf saved :promotion-cursor)))
          (restore-online-feedback-state candidate))))))

(defun online-feedback-constant-sites (team)
  "Find constants in the root learners' effective bid slices."
  (loop for learner in (team-learners team)
        for learner-index from 0
        for program = (learner-program learner)
        for instructions = (program-instructions program)
        append
        (loop for instruction-index in
                (getf (analyze-program-effective-code program)
                      :effective-indices)
              for instruction = (aref instructions instruction-index)
              append
              (loop for slot in (instruction-source-slots instruction)
                    when (eq (instruction-source-type-at instruction slot)
                             :const)
                      collect (list learner-index instruction-index slot)))))

(defun online-feedback-controller-snapshot (controller)
  "Copy mutable episode state for later pure proposal resolution."
  (let ((snapshot (copy-cage2-controller controller)))
    (setf (cage2-controller-scan-state snapshot)
          (copy-seq (cage2-controller-scan-state controller)))
    snapshot))

(defun ensure-online-feedback-probe-observations ()
  "Cache bounded, controller-aligned official states outside reward streams."
  (unless (and *online-feedback-probe-observations*
               *online-feedback-probe-contexts*)
    (unless (and *best-team* (integerp *online-feedback-seed-root*))
      (error "Online feedback probes require a saved incumbent and seed root."))
    (let* ((root (official-guided-derived-root
                  *online-feedback-seed-root* 909091))
           (seeds
             (loop for cursor below 3
                   collect (official-guided-seed-at
                            :locality root cursor)))
           (per-episode-limit
             (ceiling +online-feedback-probe-observation-limit+
                      (length seeds)))
           (contexts nil))
      (dolist (seed seeds)
        (let* ((episode-count 0)
              (*online-feedback-controller-hook*
                (lambda (observation timestep controller decision)
                  (declare (ignore decision))
                  ;; Spread the archive across early and late episode states.
                  (when (and (>= timestep 3)
                             (zerop (mod (- timestep 3) 4))
                             (< episode-count per-episode-limit))
                    (push (list :observation (copy-seq observation)
                                :controller
                                  (online-feedback-controller-snapshot
                                   controller))
                          contexts)
                    (incf episode-count)))))
          (cl-gym:rollout *best-team* *current-gym-environment-name*
                          seed)))
      (unless contexts
        (error "Online feedback probe rollout produced no policy observations."))
      (setf *online-feedback-probe-contexts* (nreverse contexts)
            *online-feedback-probe-observations*
              (mapcar (lambda (context)
                        (getf context :observation))
                      *online-feedback-probe-contexts*))
      (emit-message
       (format nil
               "Online feedback probe archive ready: seeds=~S observations=~D."
               seeds (length *online-feedback-probe-observations*)))))
  *online-feedback-probe-observations*)

(defun online-feedback-path-site-records (parent observations)
  "Find effective bid constants on preferred visited paths, with bid margins."
  (let ((records (make-hash-table :test #'equal))
        (site-cache (make-hash-table :test #'eq)))
    (dolist (observation observations)
      (multiple-value-bind (ranking path)
          (execute-team-semantic-ranked parent observation 1)
        (declare (ignore ranking))
        (let ((prefix nil))
          (loop for tail on path
                for team = (first tail)
                for next = (second tail)
                for depth from 0
                do (let* ((learners (team-learners team))
                          (bids (mapcar (lambda (learner)
                                          (bid learner observation))
                                        learners))
                          (winning-bid (if bids (reduce #'max bids) 0.0d0))
                          (winner-index
                            (and bids
                                 (position winning-bid bids :test #'=)))
                          (sites
                            (or (gethash team site-cache)
                                (setf (gethash team site-cache)
                                      (online-feedback-constant-sites team)))))
                     (when (> (length learners) 1)
                       (dolist (site sites)
                         (destructuring-bind
                               (learner-index instruction-index slot) site
                           (let* ((learner-bid (nth learner-index bids))
                                  (other-best
                                    (when (= learner-index winner-index)
                                      (loop for bid in bids
                                            for index from 0
                                            unless (= index learner-index)
                                              maximize bid)))
                                  (margin
                                    (if other-best
                                        (- learner-bid other-best)
                                        (- winning-bid learner-bid)))
                                  (key
                                    (list prefix learner-index
                                          instruction-index slot))
                                  (existing (gethash key records)))
                             (when (<= margin
                                       +online-feedback-maximum-constant-step+)
                               (if existing
                                   (setf (getf existing :margin)
                                         (min margin
                                              (getf existing :margin)))
                                   (setf (gethash key records)
                                         (list :path (copy-list prefix)
                                               :learner learner-index
                                               :instruction instruction-index
                                               :slot slot
                                               :margin margin
                                               :depth depth))))))))
                     (when next
                       (let ((reference-index
                               (position-if
                                (lambda (learner)
                                  (let ((action (learner-action learner)))
                                    (and (eq (action-type action) :reference)
                                         (eq (action-action action) next))))
                                learners)))
                         (unless reference-index
                           (error "Cannot recover visited team-reference path."))
                         (setf prefix
                               (append prefix (list reference-index))))))))))
    (let ((result
            (loop for record being the hash-values of records
                  collect record)))
      ;; Internal decisions carry most of this checkpoint's action routing.
      ;; Keep root sites as a fallback when no internal boundary is available.
      (if (some (lambda (record) (plusp (getf record :depth))) result)
          (remove-if-not (lambda (record)
                           (plusp (getf record :depth)))
                         result)
          result))))

(defun online-feedback-perturb-path-child (parent site change)
  "Copy only the root-to-site path before changing an internal bid constant.

Untouched branches remain shared but read-only. Return the child and the newly
registered path nodes so a rejected candidate can be removed cleanly."
  (let* ((root (clone-team parent))
         (original parent)
         (copy root)
         (created (list root)))
    (dolist (reference-index (getf site :path))
      (let* ((original-action
               (learner-action
                (nth reference-index (team-learners original))))
             (copied-action
               (learner-action
                (nth reference-index (team-learners copy)))))
        (unless (and (eq (action-type original-action) :reference)
                     (eq (action-type copied-action) :reference))
          (error "Probe path does not follow team references: ~S" site))
        (let* ((next-original (action-action original-action))
               (next-copy (clone-team next-original)))
          (delete-reference (action-action copied-action))
          (setf (action-action copied-action) next-copy)
          (add-reference next-copy)
          (push next-copy created)
          (setf original next-original
                copy next-copy))))
    (let* ((learner (nth (getf site :learner)
                         (team-learners copy)))
           (instruction
             (aref (program-instructions (learner-program learner))
                   (getf site :instruction)))
           (slot (getf site :slot))
           (old (instruction-source-value-at instruction slot)))
      (unless (eq (instruction-source-type-at instruction slot) :const)
        (error "Probe site is no longer a constant: ~S" site))
      (set-instruction-source instruction slot :const (+ old change)))
    (values root (nreverse created))))

(defun online-feedback-perturb-child (parent site change)
  "Compatibility helper for a root-learner constant site."
  (destructuring-bind (learner-index instruction-index slot) site
    (online-feedback-perturb-path-child
     parent
     (list :path nil :learner learner-index
           :instruction instruction-index :slot slot)
     change)))

(defun online-feedback-discard-path-child (created)
  "Undo registration and reference increments for a screened-out path copy."
  (dolist (team created)
    (delete-team team)))

(defun online-feedback-ranking-pairs (team observation)
  (mapcar #'semantic-action-category-pair
          (execute-team-semantic-ranked team observation 8)))

(defun online-feedback-resolved-concrete (controller pairs)
  (cage2-controller-decision-concrete-action
   (cage2-controller-resolve-pair-ranking controller pairs)))

(defun online-feedback-behavior-change-from-rankings
       (child-rankings parent-rankings &optional contexts parent-concretes)
  "Count ranking and Controller-resolved changes between cached proposals."
  (loop for child-ranking in child-rankings
        for parent-ranking in parent-rankings
        for index from 0
        for context = (and contexts (elt contexts index))
        count (not (equal (first parent-ranking)
                          (first child-ranking))) into top1
        count (not (equal parent-ranking child-ranking)) into ranking
        count (and context
                   (/= (elt parent-concretes index)
                       (online-feedback-resolved-concrete
                        (getf context :controller) child-ranking)))
          into concrete
        finally (return
                  (append (list :top1 top1 :ranking ranking)
                          (when contexts
                            (list :concrete concrete))))))

(defun online-feedback-behavior-change
       (child observations parent-rankings
        &optional contexts parent-concretes)
  "Count raw ranking and Controller-resolved changes on fixed states."
  (online-feedback-behavior-change-from-rankings
   (mapcar (lambda (observation)
             (online-feedback-ranking-pairs child observation))
           observations)
   parent-rankings contexts parent-concretes))

(defun online-feedback-local-behavior-p (change count)
  (and (plusp (getf change :ranking))
       (<= (getf change :top1)
           (ceiling (* count
                       +online-feedback-probe-max-top1-change+)))
       (<= (getf change :ranking)
           (ceiling (* count
                       +online-feedback-probe-max-ranking-change+)))
       (or (null (getf change :concrete))
           (and (plusp (getf change :concrete))
                (<= (getf change :concrete)
                    (ceiling
                     (* count
                        +online-feedback-probe-max-concrete-change+)))))))

(defun online-feedback-directional-local-p
       (parent-change incumbent-change count)
  "Keep a directional probe local to both its parent and the saved incumbent."
  (and (online-feedback-local-behavior-p parent-change count)
       (online-feedback-local-behavior-p incumbent-change count)))

(defun maybe-create-online-feedback-probes ()
  "Create near-boundary path-local probes only when their behavior changes."
  (when (and (online-feedback-active-p)
             (<= (+ (length (root-teams)) 2) *population-size*))
    (let* ((observations
             (ensure-online-feedback-probe-observations))
           (contexts *online-feedback-probe-contexts*)
           (incumbent-rankings
             (mapcar (lambda (observation)
                       (online-feedback-ranking-pairs
                        *best-team* observation))
                     observations))
           (incumbent-concretes
             (mapcar (lambda (context ranking)
                       (online-feedback-resolved-concrete
                        (getf context :controller) ranking))
                     contexts incumbent-rankings))
           (parents (root-teams)))
      (loop repeat (min 3 (length parents))
            for parent = (random-choice parents)
            for sites =
              (online-feedback-path-site-records parent observations)
            when sites
              do (let* ((rankings
                          (mapcar (lambda (observation)
                                    (online-feedback-ranking-pairs
                                     parent observation))
                                  observations))
                        (remaining sites))
                   (let ((parent-concretes
                           (mapcar (lambda (context ranking)
                                     (online-feedback-resolved-concrete
                                      (getf context :controller) ranking))
                                   contexts rankings)))
                   (loop repeat (min +online-feedback-probe-site-attempts+
                                     (length remaining))
                         for site =
                           (let ((chosen (random-choice remaining)))
                             (setf remaining
                                   (remove chosen remaining :test #'eq))
                             chosen)
                         for step =
                           (min +online-feedback-maximum-constant-step+
                                (max +online-feedback-constant-step+
                                     (+ (getf site :margin) 0.02d0)))
                         do (multiple-value-bind (plus plus-created)
                                (online-feedback-perturb-path-child
                                 parent site step)
                              (multiple-value-bind (minus minus-created)
                                  (online-feedback-perturb-path-child
                                   parent site (- step))
                                (let* ((plus-rankings
                                         (mapcar (lambda (observation)
                                                   (online-feedback-ranking-pairs
                                                    plus observation))
                                                 observations))
                                       (minus-rankings
                                         (mapcar (lambda (observation)
                                                   (online-feedback-ranking-pairs
                                                    minus observation))
                                                 observations))
                                       (plus-change
                                         (online-feedback-behavior-change-from-rankings
                                          plus-rankings rankings
                                          contexts parent-concretes))
                                       (minus-change
                                         (online-feedback-behavior-change-from-rankings
                                          minus-rankings rankings
                                          contexts parent-concretes))
                                       ;; A local mutation of a weak parent can
                                       ;; still be far from the saved incumbent.
                                       (plus-incumbent-change
                                         (online-feedback-behavior-change-from-rankings
                                          plus-rankings incumbent-rankings
                                          contexts incumbent-concretes))
                                       (minus-incumbent-change
                                         (online-feedback-behavior-change-from-rankings
                                          minus-rankings incumbent-rankings
                                          contexts incumbent-concretes))
                                       (plus-keep
                                         (online-feedback-directional-local-p
                                          plus-change plus-incumbent-change
                                          (length observations)))
                                       (minus-keep
                                         (online-feedback-directional-local-p
                                          minus-change minus-incumbent-change
                                          (length observations))))
                                  (unless plus-keep
                                    (online-feedback-discard-path-child
                                     plus-created)
                                    (setf plus nil))
                                  (unless minus-keep
                                    (online-feedback-discard-path-child
                                     minus-created)
                                    (setf minus nil))
                                  (when (or plus minus)
                                    (setf *online-feedback-probes*
                                          (list :parent parent :plus plus
                                                :minus minus :site site
                                                :step step
                                                :plus-change plus-change
                                                :minus-change minus-change
                                                :plus-incumbent-change
                                                  plus-incumbent-change
                                                :minus-incumbent-change
                                                  minus-incumbent-change))
                                    (emit-message
                                     (format nil
                                             "Online directional probe prepared: generation=~D path=~S learner=~D instruction=~D slot=~S margin=~,4F step=~,4F top1(+/-)=~D/~D ranking(+/-)=~D/~D concrete-parent(+/-)=~D/~D concrete-incumbent(+/-)=~D/~D of ~D."
                                             *generation*
                                             (getf site :path)
                                             (getf site :learner)
                                             (getf site :instruction)
                                             (getf site :slot)
                                             (getf site :margin) step
                                             (getf plus-change :top1)
                                             (getf minus-change :top1)
                                             (getf plus-change :ranking)
                                             (getf minus-change :ranking)
                                             (getf plus-change :concrete)
                                             (getf minus-change :concrete)
                                             (getf plus-incumbent-change :concrete)
                                             (getf minus-incumbent-change :concrete)
                                             (length observations)))
                                    (return-from
                                     maybe-create-online-feedback-probes
                                      t))))))))))))

(defun online-feedback-directional-result (scores)
  "Select a behavior-changing probe for fresh racing, not one-seed promotion."
  (when *online-feedback-probes*
    (let* ((probe *online-feedback-probes*)
           (parent (assoc (getf probe :parent) scores :test #'eq))
           (plus (and (getf probe :plus)
                      (assoc (getf probe :plus) scores :test #'eq)))
           (minus (and (getf probe :minus)
                       (assoc (getf probe :minus) scores :test #'eq)))
           (winner
             (when parent
               (first (sort (remove nil (list plus minus)) #'>
                            :key #'cdr)))))
      (setf *online-feedback-probes* nil)
      (when winner
        (emit-message
         (format nil
                 "Online paired path probe: generation=~D path=~S parent=~,4F plus-delta=~S minus-delta=~S (one shared seed; fresh racing decides)."
                 *generation* (getf (getf probe :site) :path)
                 (cdr parent)
                 (and plus (- (cdr plus) (cdr parent)))
                 (and minus (- (cdr minus) (cdr parent)))))
        winner))))

(defun online-feedback-priority-records ()
  (remove-if (lambda (record)
               (member (getf record :lane)
                       '(:random :directional)))
             *online-feedback-nominations*))

(defun online-feedback-trim-priority-records (limit)
  (loop while (> (length (online-feedback-priority-records)) limit)
        for worst =
          (first
           (sort (copy-list (online-feedback-priority-records)) #'<
                 :key (lambda (record) (getf record :delta))))
        do (setf *online-feedback-nominations*
                 (remove worst *online-feedback-nominations* :test #'eq))))

(defun online-feedback-offer-nomination (entry delta lane)
  "Reserve a directional inspection lane without treating one seed as proof."
  (when entry
    (let* ((team (car entry))
           (id (team-id team))
           (existing (find id *online-feedback-nominations*
                           :key (lambda (record) (getf record :team-id))
                           :test #'string=)))
      (when (and *best-team*
                 (string= id (team-id *best-team*)))
        (return-from online-feedback-offer-nomination nil))
      (flet ((snapshot ()
               (list :team (deep-copy-team-via-serialization team)
                     :team-id id :generation *generation*
                     :training-fitness (cdr entry) :delta delta
                     :lane lane)))
        (cond
          ((eq lane :directional)
           (setf *online-feedback-nominations*
                 (remove :directional *online-feedback-nominations*
                         :key (lambda (record) (getf record :lane))))
           (if existing
               (progn
                 (setf (getf existing :lane) :directional)
                 (pushnew existing *online-feedback-nominations*
                          :test #'eq))
               (push (snapshot) *online-feedback-nominations*))
           (online-feedback-trim-priority-records
            (- +online-feedback-nomination-limit+ 2)))
          (existing nil)
          ((eq lane :random)
           (incf *online-feedback-random-seen*)
           (when (zerop (random *online-feedback-random-seen*))
             (setf *online-feedback-nominations*
                   (remove :random *online-feedback-nominations*
                           :key (lambda (record) (getf record :lane))))
             (push (snapshot) *online-feedback-nominations*)))
          (t
           (let* ((priority (online-feedback-priority-records))
                  (limit
                    (- +online-feedback-nomination-limit+
                       (if (find :directional *online-feedback-nominations*
                                 :key (lambda (record) (getf record :lane)))
                           2 1)))
                  (worst
                    (first
                     (sort (copy-list priority) #'<
                           :key (lambda (record)
                                  (getf record :delta))))))
             (when (or (< (length priority) limit)
                       (and worst (> delta (getf worst :delta))))
               (when (>= (length priority) limit)
                 (setf *online-feedback-nominations*
                       (remove worst *online-feedback-nominations*
                               :test #'eq)))
               (push (snapshot) *online-feedback-nominations*)))))))))

(defun online-feedback-nominate-generation (scores sorted)
  "Nominate from one common-seed generation without comparing raw returns
across generations. The one-seed delta only nominates; fresh racing decides."
  (when (and (online-feedback-active-p) *best-team* sorted)
    (let* ((seeds *online-fitness-episode-seeds*)
           (incumbent
             (cage2-fitness-on-seeds
              *best-team* *current-gym-environment-name* seeds))
           (directional (online-feedback-directional-result scores))
           (random-entry (random-choice scores)))
      (online-feedback-offer-nomination
       (first sorted) (- (cdar sorted) incumbent) :generation-best)
      (when directional
        (online-feedback-offer-nomination
         directional (- (cdr directional) incumbent) :directional))
      (online-feedback-offer-nomination
       random-entry (- (cdr random-entry) incumbent) :random))))

(defun online-feedback-continue-p (candidate-returns incumbent-returns)
  "Early stages reject only an unmistakable regression."
  (let* ((differences (mapcar #'- candidate-returns incumbent-returns))
         (mean (arithmetic-mean differences))
         (se (sample-standard-error differences)))
    (values (>= (+ mean (* 2.0d0 se)) -5.0d0) mean se)))

(defun online-feedback-racing-record (contender incumbent-returns stage)
  "Record paired evidence for one lane without changing its racing decision."
  (multiple-value-bind (continued delta se)
      (online-feedback-continue-p
       (getf contender :returns) incumbent-returns)
    (list :candidate-path (getf contender :path)
          :candidate-generation (getf contender :generation)
          :lane (getf contender :lane)
          :stage stage :paired-delta delta :standard-error se
          :continued continued)))

(defun online-feedback-promotion-p (candidate-returns incumbent-returns)
  "Only a positive paired one-SE margin on fresh seeds can promote."
  (online-reference-promotion-p candidate-returns incumbent-returns))

(defun launch-online-feedback-batch ()
  "Snapshot a bounded nomination batch and start its independent evaluator."
  (let* ((generation *generation*)
         (records (reverse *online-feedback-nominations*))
         (incumbent-path
           (online-candidate-path generation "feedback-incumbent" "lisp"))
         (request-path
           (online-candidate-path generation "feedback-request" "lisp"))
         (result-path
           (online-candidate-path generation "feedback-result" "lisp"))
         (log-path
           (online-candidate-path generation "feedback-worker" "log"))
         (worker-script
           (merge-pathnames
            "scripts/run-online-candidate-evaluation.lisp"
            (asdf:system-source-directory :cl-tpg)))
         (candidates
           (loop for record in records
                 for index from 0
                 for path =
                   (online-candidate-path
                    generation (format nil "feedback-~D" index) "lisp")
                 do (write-online-candidate-checkpoint
                     (getf record :team)
                     (getf record :training-fitness)
                     (getf record :generation) path)
                 collect (list :path (namestring path)
                               :generation (getf record :generation)
                               :training-fitness
                                 (getf record :training-fitness)
                               :lane (getf record :lane)))))
    (write-online-candidate-checkpoint
     *best-team* *best-fitness* generation incumbent-path)
    (write-readable-object-atomically
     (list :protocol +online-feedback-protocol+
           :result-path (namestring result-path)
           :incumbent-path (namestring incumbent-path)
           :incumbent-version *online-feedback-incumbent-version*
           :incumbent-fitness *best-fitness*
           :candidates candidates
           :racing-stages (copy-list +online-feedback-racing-stages+)
           :racing-seeds
             (online-feedback-take-seeds
              :racing (car (last +online-feedback-racing-stages+)))
           :promotion-seeds
             (online-feedback-take-seeds
              :promotion +online-feedback-promotion-episodes+)
           :gym-environment-name *current-gym-environment-name*
           :num-observations *num-observations*
           :num-actions *num-actions*
           :decoy-order-mode *decoy-order-mode*
           :cage2-opening-mode *cage2-opening-mode*
           :recurrent-policy-enabled *recurrent-policy-enabled*
           :teacher-backend *teacher-backend*
           :hamming-space-enabled *hamming-space-enabled*
           :hamming-dataset-name *hamming-dataset-name*)
     request-path)
    (setf *online-candidate-process*
            (uiop:launch-program
             (list "sbcl" "--dynamic-space-size" "4096"
                   "--noinform" "--non-interactive"
                   "--load" (namestring worker-script)
                   "--end-toplevel-options" (namestring request-path))
             :input nil :output log-path :error-output :output
             :if-output-exists :supersede :ignore-error-status t)
          *online-candidate-job*
            (list :protocol +online-feedback-protocol+
                  :generation generation :request-path request-path
                  :result-path result-path :log-path log-path)
          *online-candidate-next-submit-generation*
            (+ generation +online-candidate-evaluation-interval+)
          *online-feedback-nominations* nil
          *online-feedback-random-seen* 0)
    (emit-message
     (format nil
             "Generation ~D submitted ~D online feedback nominees: shared fresh racing=~S, independent promotion=~D."
             generation (length candidates) +online-feedback-racing-stages+
             +online-feedback-promotion-episodes+))
    (persist-online-feedback-state)))

(defun consume-online-feedback-result (result)
  "Install only an independently promoted graph, never a one-seed probe."
  (let ((generation (getf result :candidate-generation)))
    (cond
      ((eq (getf result :status) :error)
       (emit-message
        (format nil "Online feedback evaluator failed: ~A"
                (getf result :message))))
      ((or (/= (getf result :incumbent-version)
               *online-feedback-incumbent-version*)
           (not (fitness-values-equivalent-p
                 (getf result :incumbent-fitness) *best-fitness*)))
       (emit-message
        "Discarded online feedback result for a superseded incumbent."))
      ((not (getf result :accepted))
       (emit-message
        (format nil
                "Online feedback batch rejected at ~A: paired-delta=~A margin=~A."
                (getf result :stage) (getf result :paired-delta)
                (getf result :margin))))
      (t
       (let ((candidate (load-best-team (getf result :candidate-path))))
         (ensure-team-observation-compatible candidate *num-observations*)
         (unless (= (length (getf result :candidate-scores))
                    +cage2-online-reference-episodes+)
           (error "Accepted online feedback result lacks monitor scores."))
         (setf *best-team* (deep-copy-team-via-serialization candidate)
               *best-fitness* (getf result :candidate-fitness)
               *online-best-reference-scores*
                 (copy-list (getf result :candidate-scores)))
         (incf *online-feedback-incumbent-version*)
         (emit-message
          (format nil
                  "NEW GLOBAL BEST: online feedback generation=~D lane=~A fresh paired-delta=~,4F margin=~,4F fixed-monitor=~,4F."
                  generation (getf result :candidate-lane)
                  (getf result :paired-delta) (getf result :margin)
                  *best-fitness*))
         (let ((*generation* generation))
           (save-best-team))
         (persist-online-feedback-state))))))

(defun run-online-feedback-batch (request)
  "Run one independent multi-candidate common-seed tournament."
  (let* ((result-path (pathname (getf request :result-path)))
         (started (get-universal-time)))
    (labels ((publish (result)
               (write-readable-object-atomically
                (append (list :protocol +online-feedback-protocol+)
                        result
                        (list :elapsed-seconds
                              (- (get-universal-time) started)))
                result-path))
             (episode-returns (team seeds)
               (loop for seed in seeds
                     collect (cl-gym:rollout
                              team *current-gym-environment-name* seed))))
      (handler-case
          (let* ((*running* t)
                 (*search-active* nil)
                 (*current-search-mode* :online)
                 (*current-gym-environment-name*
                   (getf request :gym-environment-name))
                 (*num-observations* (getf request :num-observations))
                 (*num-actions* (getf request :num-actions))
                 (*decoy-order-mode* (getf request :decoy-order-mode))
                 (*cage2-opening-mode* (getf request :cage2-opening-mode))
                 (*teacher-backend* (getf request :teacher-backend))
                 (*recurrent-policy-enabled*
                   (not (null (getf request :recurrent-policy-enabled))))
                 (*hamming-space-enabled*
                   (getf request :hamming-space-enabled))
                 (*hamming-dataset-name*
                   (getf request :hamming-dataset-name))
                 (*factored-actions-enabled* t)
                 (incumbent (load-best-team (getf request :incumbent-path)))
                 (metadata *loaded-checkpoint-metadata*)
                 (profile (multiple-value-list
                           (checkpoint-execution-profile
                            metadata "Online feedback incumbent")))
                 (*terminal-action-format* (first profile))
                 (*instruction-set-profile* (second profile))
                 (*read-only-register-profile* (third profile))
                 (racing-seeds (getf request :racing-seeds))
                 (racing-stages
                   (or (getf request :racing-stages)
                       +online-feedback-racing-stages+))
                 (promotion-seeds (getf request :promotion-seeds))
                 (contenders
                   (loop for record in (getf request :candidates)
                         collect (list :path (getf record :path)
                                       :generation (getf record :generation)
                                       :training-fitness
                                         (getf record :training-fitness)
                                       :lane (getf record :lane)
                                       :team (load-best-team
                                              (getf record :path))
                                       :returns nil)))
                 (incumbent-returns nil)
                 (racing-audit nil)
                 (prior-stage 0))
            (configure-hamming-observation-space)
            (ensure-team-observation-compatible incumbent *num-observations*)
            (dolist (contender contenders)
              (ensure-team-observation-compatible
               (getf contender :team) *num-observations*))
            (unless (and contenders racing-stages promotion-seeds
                         (every (lambda (stage)
                                  (and (integerp stage)
                                       (> stage 0)
                                       (<= stage (length racing-seeds))))
                                racing-stages)
                         (equal racing-stages
                                (sort (copy-list racing-stages) #'<)))
              (error "Invalid online feedback racing request."))
            (dolist (stage racing-stages)
              (let ((fresh (subseq racing-seeds prior-stage stage)))
                (setf incumbent-returns
                      (append incumbent-returns
                              (episode-returns incumbent fresh)))
                (dolist (contender contenders)
                  (setf (getf contender :returns)
                        (append (getf contender :returns)
                                (episode-returns
                                 (getf contender :team) fresh))))
                (let ((stage-records
                        (mapcar (lambda (contender)
                                  (online-feedback-racing-record
                                   contender incumbent-returns stage))
                                contenders)))
                  (setf racing-audit
                        (nconc racing-audit stage-records))
                  (format t "~&Online feedback racing lanes: stage=~D ~S~%"
                          stage
                          (mapcar (lambda (record)
                                    (list (getf record :lane)
                                          (getf record :paired-delta)
                                          (getf record :continued)))
                                  stage-records))
                  (setf contenders
                        (loop for contender in contenders
                              for record in stage-records
                              when (getf record :continued)
                                collect contender))
                  (setf prior-stage stage))
                (format t "~&Online feedback racing: stage=~D survivors=~D~%"
                        stage (length contenders))
                (finish-output)
                (when (null contenders)
                  (publish
                   (list :status :complete :accepted nil :stage :racing
                         :racing-audit racing-audit
                         :incumbent-version
                           (getf request :incumbent-version)
                         :incumbent-fitness
                           (getf request :incumbent-fitness)
                         :paired-delta nil :margin nil))
                  (return-from run-online-feedback-batch t))))
            (let* ((winner
                     (reduce
                      (lambda (left right)
                        (if (> (arithmetic-mean
                                (mapcar #'- (getf left :returns)
                                        incumbent-returns))
                               (arithmetic-mean
                                (mapcar #'- (getf right :returns)
                                        incumbent-returns)))
                            left right))
                      contenders))
                   (candidate-promotion
                     (episode-returns (getf winner :team) promotion-seeds))
                   (incumbent-promotion
                     (episode-returns incumbent promotion-seeds)))
              (multiple-value-bind (accepted delta margin)
                  (online-feedback-promotion-p
                   candidate-promotion incumbent-promotion)
                (format t "~&Online feedback promotion: accepted=~S paired-delta=~,4F margin=~,4F~%"
                        accepted delta margin)
                (finish-output)
                (let* ((monitor-scores
                         (and accepted
                              (episode-returns
                               (getf winner :team)
                               (make-online-fitness-episode-seeds
                                +cage2-evaluation-seed+
                                +cage2-online-reference-episodes+))))
                       (fitness
                         (if accepted
                             (arithmetic-mean monitor-scores)
                             (arithmetic-mean candidate-promotion))))
                  (publish
                   (list :status :complete :accepted accepted
                         :stage :promotion
                         :candidate-path (getf winner :path)
                         :candidate-generation (getf winner :generation)
                         :candidate-training-fitness
                           (getf winner :training-fitness)
                         :candidate-fitness fitness
                         :candidate-scores monitor-scores
                         :candidate-lane (getf winner :lane)
                         :incumbent-version
                           (getf request :incumbent-version)
                         :incumbent-fitness
                           (getf request :incumbent-fitness)
                         :paired-delta delta :margin margin
                         :racing-audit racing-audit
                         :candidate-promotion-returns candidate-promotion
                         :incumbent-promotion-returns incumbent-promotion
                         :racing-seeds (copy-list racing-seeds)
                         :promotion-seeds (copy-list promotion-seeds)))))))
        (error (condition)
          (publish
           (list :status :error :accepted nil
                 :incumbent-version (getf request :incumbent-version)
                 :incumbent-fitness (getf request :incumbent-fitness)
                 :message (princ-to-string condition)))))))
  t)
