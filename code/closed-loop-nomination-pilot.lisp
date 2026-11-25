(in-package :cl-tpg)

(defparameter +nomination-pilot-protocol+ :closed-loop-nomination-pilot-v1)

(defun nomination-random-order (items seed)
  "Independent deterministic lottery; never consumes the mutation RNG."
  (let ((state (sb-ext:seed-random-state seed))
        (vector (coerce items 'vector)))
    (loop for i downfrom (1- (length vector)) above 0
          do (rotatef (aref vector i) (aref vector (random (1+ i) state))))
    (coerce vector 'list)))

(defun nomination-id-seed (text root)
  (loop with value = root for character across text
        do (setf value (logand #xffffffff
                              (* 16777619 (logxor value (char-code character)))))
        finally (return value)))

(defun nomination-screen-status (deltas violations)
  "Negative filter, not a requirement for positive early return."
  (cond (violations :protected-host-regression)
        ((and (>= (length deltas) 5)
              (< (+ (arithmetic-mean deltas)
                    (* 2.0d0 (sample-standard-error deltas))) -10.0d0))
         :clear-severe-regression)
        (t :continue)))

(defun nomination-confirm-choice (lottery statuses)
  "Pick the first non-rejected entry in the pre-outcome lottery."
  (find-if (lambda (id) (eq (cdr (assoc id statuses :test #'equal)) :continue))
           lottery))

(defun nomination-new-group (observation terminal path direct-mask)
  (list :observation (copy-seq observation) :terminal terminal :path path
        :direct-mask direct-mask :rows 0 :persistence 0.0d0
        :seeds (make-hash-table :test #'eql)
        :executions (make-array 36 :initial-element 0)
        :top8 (make-array 36 :initial-element 0)
        :contexts nil))

(defun nomination-build-catalog (parent controller trace-directory root)
  "Only incumbent observations, actions and rewards enter nomination signals."
  (let ((groups (make-hash-table :test #'equalp)) (ordered nil)
        (masks (make-hash-table :test #'equal))
        (team-map (make-hash-table :test #'equal))
        (global-values (make-array 62))
        (contexts nil))
    (dolist (team (closure parent))
      (setf (gethash (team-id team) team-map) team))
    (dotimes (i 62) (setf (aref global-values i) (make-hash-table :test #'eql)))
    (dolist (path (sort (directory (merge-pathnames "*-incumbent.sexp" trace-directory))
                       #'string< :key #'namestring))
      (let* ((episode (read-readable-object path))
             (seed (getf episode :seed))
             (last-obs nil) (last-action nil) (state-run 0) (action-run 0))
        (loop for event across (getf episode :steps)
              for step = (getf event :step)
              when (>= step 3) do
                (let* ((obs (getf event :policy-observation))
                       (terminal (getf event :terminal-team))
                       (key (list obs terminal (getf event :active-path)))
                       (pair (getf event :executed-pair))
                       (action (semantic-36-pair-index (first pair) (second pair)))
                       (group
                         (or (gethash key groups)
                             (let* ((team (gethash terminal team-map))
                                    (direct (or (gethash terminal masks)
                                                (setf (gethash terminal masks)
                                                      (structural-opportunity-mask-for-team team)))))
                               (unless team (error "Unknown archived terminal ~A." terminal))
                               (let ((new (nomination-new-group
                                           obs terminal (getf event :active-path) direct)))
                                 (setf (gethash key groups) new)
                                 (push new ordered)
                                 new)))))
                  (unless (= (length obs) 62) (error "Expected 62 policy inputs."))
                  (setf state-run (if (equalp obs last-obs) (1+ state-run) 1)
                        action-run (if (eql (getf event :actual-concrete) last-action)
                                       (1+ action-run) 1)
                        last-obs obs last-action (getf event :actual-concrete))
                  (incf (getf group :rows))
                  (incf (getf group :persistence)
                        (if (minusp (getf event :reward))
                            (/ (min 5 (1- (max state-run action-run))) 5.0d0)
                            0.0d0))
                  (setf (gethash seed (getf group :seeds)) t)
                  (when action (incf (aref (getf group :executions) action)))
                  (loop for pair in (getf event :ranking) repeat 8
                        for index = (semantic-36-pair-index (first pair) (second pair))
                        when index do (incf (aref (getf group :top8) index)))
                  (dotimes (i 62)
                    (setf (gethash (aref obs i) (aref global-values i)) t))
                  (when (< (length (getf group :contexts)) 4)
                    (unless (find seed (getf group :contexts) :key (lambda (c) (getf c :seed)))
                      (push (list :seed seed :event
                                  (loop for k in '(:step :policy-observation :controller-before
                                                   :incumbent-concrete :actual-concrete
                                                   :ranking :active-path :terminal-team)
                                        append (list k (getf event k))))
                            (getf group :contexts))))))))
    (let* ((eligible (remove-if (lambda (g) (< (hash-table-count (getf g :seeds)) 2))
                                (nreverse ordered)))
           (selected (subseq (stable-sort eligible #'>
                                         :key (lambda (g) (hash-table-count (getf g :seeds))))
                             0 (min 24 (length eligible))))
           (varying (loop for i below 62 when (> (hash-table-count (aref global-values i)) 1)
                          collect i))
           (seen (make-hash-table :test #'equal))
           (catalog nil) (next 0))
      (loop for group in selected for group-index from 1 do
        (let* ((probe-context (first (last (getf group :contexts))))
               (event (getf probe-context :event))
               (obs (getf group :observation))
               (features (nomination-random-order varying (+ root group-index)))
               (predicates
                 (loop for index in features
                       for ror = (position (aref obs index) (active-read-only-register-values) :test #'=)
                       when ror collect (list index ror) into result
                       when (= (length result) 2) return result))
               (feasible (structural-opportunity-feasible-mask controller
                                                              (getf event :controller-before)))
               (exposure (hash-table-count (getf group :seeds))))
          (unless (= (length predicates) 2) (error "Insufficient categorical varying features."))
          (setf contexts (nconc contexts (reverse (getf group :contexts))))
          (dotimes (index 36)
            (let* ((pair (semantic-36-index-pair index))
                   (decision (progn
                               (brute-restore-controller controller (getf event :controller-before))
                               (cage2-controller-resolve-pair-ranking controller (list pair))))
                   (recipe (list (getf group :terminal) predicates pair 250.0d0)))
              (when (and (logbitp index feasible)
                         (/= (getf event :actual-concrete)
                             (cage2-controller-decision-concrete-action decision)))
                (let* ((rows (getf group :rows))
                       (coverage (/ (+ (if (logbitp index (getf group :direct-mask)) 0.0d0 1.0d0)
                                       (- 1.0d0 (/ (aref (getf group :top8) index) rows))
                                       (- 1.0d0 (/ (aref (getf group :executions) index) rows)))
                                    3.0d0))
                       (score (* (log (1+ exposure)) coverage))
                       (failure (* score (+ 1.0d0 (/ (getf group :persistence) rows))))
                       (existing (gethash recipe seen)))
                  (if existing
                      (progn
                        (push group-index (getf existing :groups))
                        (setf (getf existing :coverage-score)
                              (max score (getf existing :coverage-score))
                              (getf existing :failure-score)
                              (max failure (getf existing :failure-score))))
                      (let* ((id (format nil "opportunity-~4,'0D" (incf next)))
                             (row
                               (list :id id :groups (list group-index)
                                     :coverage-score score :failure-score failure
                                     :exposure-seeds exposure :rows rows
                                     :persistence (/ (getf group :persistence) rows)
                                     :generator-seed (+ root group-index)
                                     :spec (list :id id :probe obs :target (first pair)
                                                 :response (second pair) :predicates predicates
                                                 :margin 250.0d0 :insertion :terminal
                                                 :terminal (getf group :terminal)))))
                        (setf (gethash recipe seen) row)
                        (push row catalog)))))))))
      (values (nreverse catalog) contexts
              (list :input-groups (hash-table-count groups)
                    :eligible-groups (length eligible) :selected-groups (length selected)
                    :catalog-size next :probe-contexts (length contexts)
                    :signal :observed-only :runtime-inputs 62)))))

(defun nomination-select-lanes (catalog count root)
  (unless (>= (length catalog) count) (error "Too few eligible opportunities."))
  (loop for lane in '(:coverage :failure :random)
        for order = (case lane
                      (:coverage (stable-sort (nomination-random-order
                                     catalog (nomination-id-seed "ties" root)) #'> :key
                                               (lambda (r) (getf r :coverage-score))))
                      (:failure (stable-sort (nomination-random-order
                                     catalog (nomination-id-seed "ties" root)) #'> :key
                                              (lambda (r) (getf r :failure-score))))
                      (t (nomination-random-order catalog (nomination-id-seed "random" root))))
        for ids = (mapcar (lambda (r) (getf r :id)) (subseq order 0 count))
        collect (list :lane lane :nominations ids
                      :confirmation-lottery
                      (nomination-random-order ids
                                               (nomination-id-seed (symbol-name lane) (+ root 1))))))

(defun nomination-probe (parent child controller contexts)
  (let ((changed 0))
    (dolist (context contexts)
      (let* ((event (getf context :event))
             (before (brute-resolve-team parent controller event))
             (after (brute-resolve-team child controller event)))
        (unless (= (getf event :actual-concrete)
                   (cage2-controller-decision-concrete-action before))
          (error "Probe archive does not reproduce the parent."))
        (unless (= (cage2-controller-decision-concrete-action before)
                   (cage2-controller-decision-concrete-action after))
          (incf changed))))
    (list :contexts (length contexts) :actual-changes changed)))

(defun nomination-save-child (child path metadata)
  (write-best-team-checkpoint
   child 0.0d0 path :gym-environment-name "Cage2-meander-100-v0"
   :generation (getf metadata :generation) :num-observations 62
   :online-fitness-episodes 0 :search-seed (getf metadata :search-seed)
   :action-agreement-signature (getf metadata :action-agreement-signature)
   :fitness-evaluation-protocol +nomination-pilot-protocol+
   :decoy-order-mode :fixed :cage2-opening-mode :fixed :recurrent-policy-enabled nil
   :teacher-backend nil :instruction-set-profile :reduced-eq
   :read-only-register-profile :cage2-categorical-v1
   :terminal-action-format :target-response-36))

(defun nomination-read-journal (path)
  (if (probe-file path) (robustness-read-journal path) nil))

(defun nomination-evaluate (env controller parent team id stage seeds output)
  "No intervention: TEAM controls every post-opening step of a full episode."
  (let* ((journal (merge-pathnames "official-journal.sexp" output))
         (prior (nomination-read-journal journal))
         (episodes nil) (total 0))
    (dolist (seed seeds)
      (let* ((key (list stage id seed))
             (done (find key prior :test #'equal :key (lambda (r) (getf r :key))))
             (result
               (or done
                   (let* ((starts (merge-pathnames "rollout-starts.sexp" output))
                          (start-check
                            (progn
                              (when (find key (nomination-read-journal starts)
                                          :test #'equal :key (lambda (r) (getf r :key)))
                                (error "Unfinished rollout ~S; partial transition cost is unknown. No automatic retry." key))
                              (robustness-append-journal-record starts (list :key key))))
                          (episode (official-pilot-run-episode
                                    env controller team "Cage2-meander-100-v0" seed
                                    :observer (lambda (e) (py4cl2:pycall "_bes_privileged_state" e))))
                          (changed
                            (loop for event across (getf episode :steps)
                                  when (>= (getf event :step) 3)
                                    count
                                    (/= (getf event :actual-concrete)
                                        (cage2-controller-decision-concrete-action
                                         (brute-resolve-team parent controller event)))))
                          (row (list :protocol +nomination-pilot-protocol+ :key key
                                     :stage stage :policy id :seed seed
                                     :return (getf episode :return)
                                     :transitions (length (getf episode :steps))
                                     :actual-changed-steps changed
                                     :safety (brute-episode-safety episode))))
                     (declare (ignore start-check))
                     (robustness-append-journal-record journal row)
                     row))))
        (incf total (getf result :transitions))
        (push result episodes)))
    (list :policy id :stage stage :episodes (nreverse episodes) :transitions total)))

(defun nomination-comparison (candidate baseline)
  (let* ((rows (getf candidate :episodes)) (base (getf baseline :episodes))
         (returns (mapcar (lambda (r) (getf r :return)) rows))
         (before (mapcar (lambda (r) (getf r :return)) base)))
    (unless (equal (mapcar (lambda (r) (getf r :seed)) rows)
                   (mapcar (lambda (r) (getf r :seed)) base))
      (error "Closed-loop comparison seeds differ."))
    (let* ((deltas (mapcar #'- returns before))
           (violations (brute-safety-regressions
                        (mapcar (lambda (r) (getf r :safety)) base)
                        (mapcar (lambda (r) (getf r :safety)) rows)))
           (mean (arithmetic-mean deltas))
           (se (sample-standard-error deltas)))
      (list :paired (robustness-paired-summary returns before)
            :sample-se se :violations violations
            :screen-status (nomination-screen-status deltas violations)
            :positive-mean (plusp mean)
            :positive-exploratory-evidence
            (and (= (length deltas) 20) (null violations) (> (- mean (* 2.093d0 se)) 0.0d0))
            :evidence-label :unadjusted-exploratory-not-promotion))))

(defun run-closed-loop-nomination-pilot
       (&key parent-path trace-directory output screen-seeds confirmation-seeds
             (per-lane 4) (generator-root 830118))
  (let* ((*num-observations* 62) (*num-actions* 36)
         (*factored-actions-enabled* t) (*terminal-action-format* :target-response-36)
         (*instruction-set-profile* :reduced-eq) (*read-only-register-profile* :cage2-categorical-v1)
         (*decoy-order-mode* :fixed) (*cage2-opening-mode* :fixed)
         (*recurrent-policy-enabled* nil) (*hamming-space-enabled* nil)
         (*random-state* (sb-ext:seed-random-state generator-root))
         (source (multiple-value-list (load-best-team parent-path)))
         (parent (brute-canonicalize-ids (first source))) (metadata (third source))
         (directory (uiop:ensure-directory-pathname output))
         (controller (make-cage2-controller :decoy-order-profile :meander-heuristic))
         (parent-sha (incubation-file-sha256 parent-path))
         (catalog-path (merge-pathnames "catalog.sexp" directory))
         (lanes nil) (built nil) (screen-results nil) (confirm-results nil)
         (env nil))
    (unless (and (= (getf metadata :num-observations) 62)
                 (eq (getf metadata :terminal-action-format) :target-response-36)
                 (not (getf metadata :recurrent-policy-enabled)))
      (error "Pilot requires the frozen stateless 62-input Semantic-36 policy."))
    (multiple-value-bind (catalog contexts audit)
        (nomination-build-catalog parent controller
                                  (uiop:ensure-directory-pathname trace-directory) generator-root)
      (setf lanes (nomination-select-lanes catalog per-lane generator-root))
      (let ((frozen (list :protocol +nomination-pilot-protocol+
                          :parent-sha256 parent-sha :audit audit :catalog catalog :lanes lanes)))
        (when (and (probe-file catalog-path)
                   (not (equalp frozen (read-readable-object catalog-path))))
          (error "Frozen shared catalog changed."))
        (write-readable-object-atomically frozen catalog-path))
      (format t "~&CATALOG ~S~%" audit) (finish-output)
      (dolist (id (remove-duplicates (loop for lane in lanes append (getf lane :nominations))
                                     :test #'equal))
        (let* ((entry (find id catalog :key (lambda (r) (getf r :id)) :test #'equal))
               (child (incubation-child parent (getf entry :spec)))
               (probe (and child (nomination-probe parent child controller contexts)))
               (active (and probe (plusp (getf probe :actual-changes))))
               (path (merge-pathnames (format nil "offspring/~A.lisp" id) directory)))
          (when child
            (brute-canonicalize-ids child)
            (nomination-save-child child path metadata)
            (unless (equalp probe (nomination-probe parent (load-best-team path) controller contexts))
              (error "Serialization changed candidate activation.")))
          (push (list :id id :executable (not (null child)) :probe probe :active active
                      :path (and child (namestring path))
                      :checkpoint-sha256 (and child (incubation-file-sha256 path))) built)
          (format t "~&BUILD ~A executable=~A probe=~S~%" id (not (null child)) probe)
          (finish-output)))
      (setf built (nreverse built))
      (write-readable-object-atomically built (merge-pathnames "built.sexp" directory)))
    (unless (equal parent-sha (incubation-file-sha256 parent-path))
      (error "Frozen parent checkpoint changed."))
    (py4cl2:pyexec (uiop:read-file-string
                   (merge-pathnames "scripts/privileged-state.py" (asdf:system-source-directory :cl-tpg))))
    (setf env (cl-gym::make "Cage2-meander-100-v0"))
    (cl-gym::configure-cage2-controller-option-orders env controller)
    (unwind-protect
         (let ((baseline (nomination-evaluate env controller parent parent "incumbent"
                                              :screen screen-seeds directory)))
           (dolist (entry built)
             (when (getf entry :active)
               (let* ((id (getf entry :id))
                      (evaluation (nomination-evaluate env controller parent
                                                       (load-best-team (getf entry :path))
                                                       id :screen screen-seeds directory))
                      (comparison (nomination-comparison evaluation baseline))
                      (row (list :id id :evaluation evaluation :comparison comparison)))
                 (push row screen-results)
                 (write-readable-object-atomically row
                                                  (merge-pathnames (format nil "screen/~A.sexp" id) directory))
                 (format t "~&SCREEN ~A ~S~%" id comparison) (finish-output))))
           (setf screen-results (nreverse screen-results))
           (write-readable-object-atomically screen-results (merge-pathnames "screen-results.sexp" directory))
           (let ((statuses
                   (loop for row in screen-results
                         collect (cons (getf row :id) (getf (getf row :comparison) :screen-status))))
                 (choices nil))
             (dolist (lane lanes)
               (push (list :lane (getf lane :lane)
                           :id (nomination-confirm-choice (getf lane :confirmation-lottery) statuses))
                     choices))
             (setf choices (nreverse choices))
             (write-readable-object-atomically choices (merge-pathnames "confirmation-choices.sexp" directory))
             (when (some (lambda (r) (getf r :id)) choices)
               (let ((confirmation-baseline
                       (nomination-evaluate env controller parent parent "incumbent"
                                            :confirmation confirmation-seeds directory)))
                 (dolist (id (remove-duplicates (remove nil (mapcar (lambda (r) (getf r :id)) choices))
                                               :test #'equal))
                   (let* ((entry (find id built :key (lambda (r) (getf r :id)) :test #'equal))
                          (evaluation (nomination-evaluate env controller parent
                                                           (load-best-team (getf entry :path))
                                                           id :confirmation confirmation-seeds directory))
                          (comparison (nomination-comparison evaluation confirmation-baseline))
                          (row (list :id id :evaluation evaluation :comparison comparison)))
                     (push row confirm-results)
                     (write-readable-object-atomically row
                                                      (merge-pathnames (format nil "confirmation/~A.sexp" id) directory))
                     (format t "~&CONFIRM ~A ~S~%" id comparison) (finish-output)))))
             (write-readable-object-atomically
              (list :choices choices :results (nreverse confirm-results)
                    :promotion-attempted nil :historical-best-modified nil)
              (merge-pathnames "confirmation-results.sexp" directory))))
      (when env (py4cl2:pymethod env "close")))
    (let* ((journal (nomination-read-journal (merge-pathnames "official-journal.sexp" directory)))
           (confirm (read-readable-object (merge-pathnames "confirmation-results.sexp" directory)))
           (funnels
             (loop for lane in lanes
                   for ids = (getf lane :nominations)
                   for choice = (getf (find (getf lane :lane) (getf confirm :choices)
                                          :key (lambda (r) (getf r :lane))) :id)
                   for result = (find choice (getf confirm :results)
                                      :key (lambda (r) (getf r :id)) :test #'equal)
                   collect
                   (list :lane (getf lane :lane) :nominations (length ids)
                         :executable (count-if (lambda (r) (and (member (getf r :id) ids :test #'equal)
                                                                (getf r :executable))) built)
                         :probe-active (count-if (lambda (r) (and (member (getf r :id) ids :test #'equal)
                                                                 (getf r :active))) built)
                         :screen-tested (count-if (lambda (r) (member (getf r :id) ids :test #'equal))
                                                  screen-results)
                         :closed-loop-active
                         (count-if (lambda (r) (and (member (getf r :id) ids :test #'equal)
                                                   (some (lambda (e) (plusp (getf e :actual-changed-steps)))
                                                         (getf (getf r :evaluation) :episodes))))
                                   screen-results)
                         :fresh-tested (if result 1 0)
                         :fresh-positive-mean (and result (getf (getf result :comparison) :positive-mean))
                         :fresh-positive-evidence
                         (and result (getf (getf result :comparison) :positive-exploratory-evidence))
                         :generation-official-transitions 0 :probe-official-transitions 0
                         :attributed-screen-transitions
                         (loop for r in screen-results when (member (getf r :id) ids :test #'equal)
                               sum (getf (getf r :evaluation) :transitions))
                         :attributed-confirmation-transitions
                         (if result (getf (getf result :evaluation) :transitions) 0)
                         :confirmation-choice choice :promotions 0 :promotion-attempted nil)))
           (summary (list :protocol +nomination-pilot-protocol+ :funnels funnels
                          :actual-official-transitions
                          (reduce #'+ journal :key (lambda (r) (getf r :transitions)) :initial-value 0)
                          :official-episodes (length journal)
                          :stage-accounting
                          (loop for stage in '(:screen :confirmation)
                                collect (list :stage stage
                                              :actual-transitions
                                              (loop for r in journal when (eq stage (getf r :stage))
                                                    sum (getf r :transitions))
                                              :baseline-transitions
                                              (loop for r in journal
                                                    when (and (eq stage (getf r :stage))
                                                              (equal "incumbent" (getf r :policy)))
                                                    sum (getf r :transitions))))
                          :unique-nominations (length built)
                          :baseline-reuse :identical-parent-environment-controller-seeds
                          :cross-lane-overlap-not-independent t
                          :promotion-attempted nil :evidence :exploratory)))
      (write-readable-object-atomically summary (merge-pathnames "summary.sexp" directory))
      (with-open-file (out (merge-pathnames "report.txt" directory)
                           :direction :output :if-exists :supersede)
        (format out "~S~%" summary)
        (dolist (row (getf confirm :results))
          (format out "~%CONFIRM ~A ~S~%" (getf row :id) (getf row :comparison))))
      (format t "~&SUMMARY ~S~%done~%" summary)
      (finish-output))))
