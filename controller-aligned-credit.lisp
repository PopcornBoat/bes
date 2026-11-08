(in-package :cl-tpg)

(defparameter +aligned-repair-protocol+ :controller-aligned-repair-v2)

(defun aligned-case-context (identity seed episode step)
  (list :identity identity :seed seed :event (aref (getf episode :steps) step)
        :prefix (loop for row across (getf episode :steps) repeat step
                      collect (getf row :actual-concrete))))

(defun aligned-select-nominations (rows limit &optional (per-seed 2))
  "Round-robin diagnostic strata, first one independent point per seed."
  (let ((table (make-hash-table :test #'equalp))
        (counts (make-hash-table :test #'eql))
        (seen (make-hash-table :test #'equal))
        (keys nil) (selected nil))
    (dolist (row rows)
      (let ((point (list (getf row :trajectory) (getf row :seed) (getf row :step)))
            (key (getf row :stratum)))
        (unless (gethash point seen)
          (setf (gethash point seen) t)
          (unless (gethash key table) (push key keys))
          (push row (gethash key table)))))
    (setf keys (nreverse keys))
    (dolist (key keys) (setf (gethash key table) (nreverse (gethash key table))))
    (block enough
      (loop for cap from 1 to per-seed do
        (loop with progress = t while progress do
          (setf progress nil)
          (dolist (key keys)
            (let ((row (find-if
                        (lambda (r) (< (gethash (getf r :seed) counts 0) cap))
                        (gethash key table))))
              (when row
                (setf progress t)
                (setf (gethash key table) (remove row (gethash key table) :count 1 :test #'eq))
                (incf (gethash (getf row :seed) counts 0))
                (push row selected)
                (when (= (length selected) limit) (return-from enough))))))))
    (nreverse selected)))

(defun aligned-nomination-summary (rows)
  (let ((seeds (make-hash-table :test #'eql))
        (observations (make-hash-table :test #'equalp))
        (accesses (make-hash-table :test #'eql))
        (actions (make-hash-table :test #'equal))
        (sources (make-hash-table :test #'eq)))
    (dolist (row rows)
      (setf (gethash (getf row :seed) seeds) t
            (gethash (getf row :observation) observations) t)
      (incf (gethash (getf row :trajectory) sources 0))
      (incf (gethash (getf row :repair-host-access) accesses 0))
      (incf (gethash (list (getf row :original-concrete) (getf row :alternative-concrete))
                    actions 0)))
    (list :points (length rows) :independent-seeds (hash-table-count seeds)
          :unique-observations (hash-table-count observations)
          :trajectory-sources
          (loop for key being the hash-keys of sources using (hash-value n) collect (cons key n))
          :repair-host-access
          (loop for access from 0 to 2 collect (cons access (gethash access accesses 0)))
          :action-pairs (loop for key being the hash-keys of actions using (hash-value n)
                              collect (cons key n)))))

(defun aligned-nominate-disagreements
       (repair parent controller trace seed repair-target &optional (trajectory :repair))
  "Use actual full-policy disagreement, not hidden correctness or episode wins."
  (let ((rows nil)
        (names (action-agreement-target-names (cage2-controller-agreement controller))))
    (loop for event across (getf trace :steps)
          for step = (getf event :step)
          when (>= step 3) do
            (let* ((old (brute-resolve-team repair controller event))
                   (alternative (brute-resolve-team parent controller event))
                   (actual (cage2-controller-decision-concrete-action old))
                   (other (cage2-controller-decision-concrete-action alternative)))
              (unless (= (if (eq trajectory :repair) actual other)
                         (getf event :actual-concrete))
                (error "Recorded ~S action no longer reproduces." trajectory))
              (unless (= actual other)
                (let* ((snapshot (getf event :privileged-before))
                       (repair-access (py4cl2:pycall "_bes_host_access" snapshot
                                                     (aref names repair-target)))
                       (pair (official-pilot-pair alternative))
                       (alternative-access
                         (if (plusp (first pair))
                             (py4cl2:pycall "_bes_host_access" snapshot
                                           (aref names (first pair))) 0))
                       (observation (getf event :policy-observation)))
                  (push (list :seed seed :step step :trajectory trajectory :observation observation
                              :repair-concrete actual :parent-concrete other
                              :repair-host-access repair-access
                              :alternative-host-access alternative-access
                              :original-concrete actual :alternative-concrete other
                              :stratum (list trajectory observation
                                             (getf event :terminal-team)
                                             actual other repair-access alternative-access
                                             (floor step 25)))
                        rows)))))
    (nreverse rows)))

(defun aligned-find-repair (team spec)
  "Locate the one added learner in a canonically named independent graph."
  (let* ((terminal (if (eq (getf spec :insertion) :root) team
                       (find (getf spec :terminal) (closure team)
                             :key #'team-id :test #'string=)))
         (learner (and terminal (first (team-learners terminal)))))
    (unless (and learner
                 (target-response-36-action-p (action-action (learner-action learner)))
                 (= (target-response-36-action-target
                     (action-action (learner-action learner))) (getf spec :target))
                 (= (target-response-36-action-response
                     (action-action (learner-action learner))) (getf spec :response))
                 (equalp (program-instructions (learner-program learner))
                         (program-instructions
                          (incubation-gate-program (getf spec :predicates)
                                                   (getf spec :margin)))))
      (error "The expected repair learner is absent or has changed."))
    learner))

(defun aligned-refine-child (repair spec predicates margin)
  "Replace one added learner's program; preserve the rest of its copied graph."
  (let* ((child (brute-canonicalize-ids (deep-copy-team-via-serialization repair)))
         (learner (aligned-find-repair child spec)))
    (setf (learner-program learner) (incubation-gate-program predicates margin))
    child))

(defun aligned-rank-gates (cases limit)
  "Preserve measured useful repairs and suppress measured harmful ones."
  (let ((seen (make-hash-table :test #'equal)) (ranked nil) (diagnostics nil))
    (dolist (positive cases)
      (when (plusp (getf positive :keep-advantage))
        (let* ((probe (getf (getf (getf positive :context) :event) :policy-observation))
               (values (active-read-only-register-values))
               (atoms (loop for value across probe for index from 0
                            for ror = (position value values :test #'=)
                            when ror collect (list index ror)))
               (gates (append (mapcar #'list atoms)
                              (loop for tail on atoms append
                                    (loop for other in (rest tail)
                                          collect (list (first tail) other))))))
          (dolist (gate gates)
            (unless (gethash gate seen)
              (setf (gethash gate seen) t)
              (let ((support (make-hash-table :test #'eql)) (effects nil))
                (dolist (case cases)
                  (let* ((context (getf case :context))
                         (fires (brute-gate-matches-p
                                 gate (getf (getf context :event) :policy-observation)))
                         (keep (getf case :keep-advantage)))
                    (when (and fires (plusp keep))
                      (setf (gethash (getf context :seed) support) t))
                    (push (list :seed (getf context :seed) :status :measured
                                :delta (if fires 0.0d0 (- keep))) effects)))
                (let* ((stats (brute-credit-statistics effects))
                       (mean (getf stats :mean))
                       (score (- mean (or (getf stats :se) 0.0d0))))
                  (let ((row (list :predicates gate :score score :mean mean
                                   :se (getf stats :se) :positive-support-seeds
                                   (hash-table-count support))))
                    (push row diagnostics)
                    (when (and (>= (hash-table-count support) 2) (plusp score))
                      (push row ranked))))))))))
    (let ((sorted (stable-sort ranked #'> :key (lambda (row) (getf row :score))))
          (all (stable-sort diagnostics #'> :key (lambda (row) (getf row :score)))))
      (values (subseq sorted 0 (min limit (length sorted)))
              (list :tested (length all) :eligible (length sorted)
                    :best-proxy (first all))))))

(defun aligned-observation-conflicts (cases)
  "Report opposing measurements at identical policy inputs, without runtime memory."
  (let ((groups (make-hash-table :test #'equalp)) (conflicts nil))
    (dolist (case cases)
      (push case (gethash (getf (getf (getf case :context) :event) :policy-observation)
                          groups)))
    (maphash
     (lambda (observation rows)
       (when (and (some (lambda (row) (plusp (getf row :keep-advantage))) rows)
                  (some (lambda (row) (minusp (getf row :keep-advantage))) rows))
         (push (list :observation observation
                     :measurements
                     (mapcar (lambda (row)
                               (let ((context (getf row :context)))
                                 (list :seed (getf context :seed)
                                       :step (getf (getf context :event) :step)
                                       :keep-advantage (getf row :keep-advantage))))
                             (reverse rows)))
               conflicts)))
     groups)
    (stable-sort conflicts #'<
                 :key (lambda (row) (getf (first (getf row :measurements)) :seed)))))

(defun aligned-outcome-key (context)
  (list (first (getf context :identity))
        (getf context :seed) (getf (getf context :event) :step)))

(defun aligned-full-ranking-query
       (env controller continuation alternative episode context output log)
  "Execute one alternative's full ranking on the frozen continuation trajectory."
  (let* ((event (getf context :event))
         (seed (getf context :seed))
         (step (getf event :step))
         (path (merge-pathnames
                (format nil "interventions/~A-~D-~D-~A.sexp"
                        (subseq (first (getf context :identity)) 0 16)
                        seed step (incubation-file-sha256 alternative)) output)))
    ;; ALTERNATIVE is passed as a frozen checkpoint path, not a mutable graph.
    (let* ((alternative-team (brute-canonicalize-ids (load-best-team alternative)))
           (resolved (multiple-value-list (brute-resolve-team alternative-team controller event)))
           (decision (first resolved))
           (ranking (second resolved))
           (concrete (cage2-controller-decision-concrete-action decision)))
      (if (= concrete (getf event :incumbent-concrete))
          (values nil concrete)
          (let ((result
                  (if (probe-file path)
                      (read-readable-object path)
                      (let* ((branch
                               (brute-episode
                                env controller continuation "Cage2-meander-100-v0"
                                seed log :observer
                                (lambda (e) (py4cl2:pycall "_bes_privileged_state" e))
                                :intervention-step step :intervention-ranking ranking
                                :expected-concrete concrete :expected-prefix (getf episode :steps)))
                             (row (list :protocol +aligned-repair-protocol+
                                        :context context :actual-concrete concrete
                                        :delta (- (getf branch :return) (getf episode :return))
                                        :branch-return (getf branch :return)
                                        :safety (brute-episode-safety branch)
                                        :branch branch)))
                        (write-readable-object-atomically row path)
                        row))))
            (unless (and (equalp (getf result :context) context)
                         (= (getf result :actual-concrete) concrete))
              (error "A cached full-ranking intervention belongs to another context."))
            (values result concrete))))))

(defun run-controller-aligned-repair
       (&key parent-path repair-path spec-path screen-directory output
             environment-signature (max-cases 24) (max-candidates 12)
             (extra-queries 24) evaluation-seeds discovery-seeds)
  "Measure C13 interventions, refine the existing learner, and evaluate vs v9."
  (let* ((*num-observations* 62) (*num-actions* 36)
         (*factored-actions-enabled* t) (*terminal-action-format* :target-response-36)
         (*instruction-set-profile* :reduced-eq) (*read-only-register-profile* :cage2-categorical-v1)
         (*decoy-order-mode* :fixed) (*cage2-opening-mode* :fixed)
         (*recurrent-policy-enabled* nil) (*hamming-space-enabled* nil)
         (*random-state* (sb-ext:seed-random-state 153))
         (directory (uiop:ensure-directory-pathname output))
         (screen (if discovery-seeds
                     (merge-pathnames "discovery/" directory)
                     (uiop:ensure-directory-pathname screen-directory)))
         (source (multiple-value-list (load-best-team repair-path)))
         (repair (brute-canonicalize-ids (first source)))
         (metadata (third source))
         (parent (brute-canonicalize-ids (load-best-team parent-path)))
         (spec (getf (read-readable-object spec-path) :spec))
         (seeds (or discovery-seeds
                    (read-readable-object (merge-pathnames "seeds.sexp" screen))))
         (case-cache (make-hash-table :test #'equalp))
         (episode-cache (make-hash-table :test #'eql))
         (known (make-hash-table :test #'equalp))
         (cases nil) (nominations nil) (evaluated nil)
         (controller (make-cage2-controller :decoy-order-profile :meander-heuristic))
         (env nil) (query-count 0)
         (log (merge-pathnames "completed-rollouts.sexp" directory)))
    (unless (and (= (getf spec :target) 8) (= (getf spec :response) 2))
      (error "This bounded refinement protocol expects the selected User2 Restore repair."))
    (aligned-find-repair repair spec)
    (py4cl2:pyexec (uiop:read-file-string
                   (merge-pathnames "scripts/privileged-state.py"
                                    (asdf:system-source-directory :cl-tpg))))
    (setf env (cl-gym::make "Cage2-meander-100-v0"))
    (cl-gym::configure-cage2-controller-option-orders env controller)
    (unwind-protect
         (progn
           (when discovery-seeds
             (write-readable-object-atomically seeds (merge-pathnames "seeds.sexp" screen))
             (loop for seed in seeds for index from 1 do
               (loop for role in '("incumbent" "c13") for team in (list parent repair) do
                 (let ((path (merge-pathnames (format nil "traces/~D-~A.sexp" seed role) screen)))
                   (unless (probe-file path)
                     (write-readable-object-atomically
                      (brute-episode env controller team "Cage2-meander-100-v0" seed log
                                     :observer (lambda (e) (py4cl2:pycall "_bes_privileged_state" e)))
                      path))))
               (format t "~&DISCOVERY ~D/~D seed=~D~%" index (length seeds) seed)
               (finish-output)))
           (when discovery-seeds
             (let ((before nil) (after nil) (before-safety nil) (after-safety nil))
               (dolist (seed seeds)
                 (let ((baseline (read-readable-object
                                  (merge-pathnames (format nil "traces/~D-incumbent.sexp" seed) screen)))
                       (candidate (read-readable-object
                                   (merge-pathnames (format nil "traces/~D-c13.sexp" seed) screen))))
                   (push (getf baseline :return) before)
                   (push (getf candidate :return) after)
                   (push (brute-episode-safety baseline) before-safety)
                   (push (brute-episode-safety candidate) after-safety)))
               (let ((summary (list :seeds seeds :evidence :discovery-only
                                    :parent (robustness-return-summary before)
                                    :repair (robustness-return-summary after)
                                    :paired (robustness-paired-summary after before)
                                    :protected-host-violations
                                    (brute-safety-regressions before-safety after-safety))))
                 (write-readable-object-atomically summary
                                                  (merge-pathnames "discovery-summary.sexp" directory))
                 (format t "~&DISCOVERY PAIRED ~S~%" (getf summary :paired))
                 (finish-output))))
           ;; All actual disagreements are eligible. Hidden state and phase
           ;; diversify diagnostic samples; neither becomes a policy input.
           (let ((available nil))
             (dolist (seed seeds)
               (loop for trajectory in '(:repair :parent)
                     for role in '("c13" "incumbent") do
                 (let ((trace (read-readable-object
                               (merge-pathnames (format nil "traces/~D-~A.sexp" seed role) screen))))
                   (setf available
                         (nconc available
                                (aligned-nominate-disagreements
                                 repair parent controller trace seed (getf spec :target) trajectory))))))
             (setf nominations (aligned-select-nominations available max-cases))
             (let ((sampling (list :available (aligned-nomination-summary available)
                                   :selected (aligned-nomination-summary nominations)
                                   :max-per-seed 2 :method :diagnostic-stratification)))
               (write-readable-object-atomically sampling
                                                (merge-pathnames "sampling.sexp" directory))
               (format t "~&SAMPLING ~S~%" sampling)
               (finish-output)))
           (write-readable-object-atomically
            nominations (merge-pathnames "nominations.sexp" directory))
           (dolist (nomination nominations)
             (let* ((seed (getf nomination :seed))
                    (step (getf nomination :step))
                    (trajectory (getf nomination :trajectory))
                    (continuation (if (eq trajectory :repair) repair parent))
                    (continuation-path (if (eq trajectory :repair) repair-path parent-path))
                    (alternative-path (if (eq trajectory :repair) parent-path repair-path))
                    (episode-key (list trajectory seed))
                    (episode
                      (or (gethash episode-key episode-cache)
                          (let* ((stored (read-readable-object
                                          (merge-pathnames
                                           (format nil "traces/~D-~A.sexp" seed
                                                   (if (eq trajectory :repair) "c13" "incumbent"))
                                           screen)))
                                 (fresh (brute-episode
                                         env controller continuation "Cage2-meander-100-v0" seed log
                                         :observer (lambda (e) (py4cl2:pycall "_bes_privileged_state" e)))))
                            (brute-verify-observer fresh stored)
                            (setf (gethash episode-key episode-cache) fresh))))
                    (source-hash (incubation-file-sha256 continuation-path))
                    (context (aligned-case-context
                              (list source-hash source-hash environment-signature) seed episode step)))
               (multiple-value-bind (result concrete)
                   (aligned-full-ranking-query
                    env controller continuation alternative-path episode context directory log)
                 (when result
                   (let* ((keep (if (eq trajectory :repair)
                                    (- (getf result :delta)) (getf result :delta)))
                          (row (list :context context :nomination nomination
                                     :trajectory trajectory :continuation-path continuation-path
                                     :episode-key episode-key
                                     :repair-delta (if (eq trajectory :repair) 0.0d0 keep)
                                     :alternative-concrete concrete :keep-advantage keep)))
                     (push row cases)
                     (setf (gethash (aligned-outcome-key context) case-cache) row
                           (gethash (brute-credit-key context concrete) known)
                           (getf result :delta))
                     (format t "~&CASE source=~A seed=~D step=~D keep-advantage=~,4F~%"
                             trajectory seed step keep)
                     (finish-output))))))
           (setf cases (nreverse cases))
           (write-readable-object-atomically cases (merge-pathnames "cases.sexp" directory))
           (write-readable-object-atomically
            (aligned-observation-conflicts cases)
            (merge-pathnames "observation-conflicts.sexp" directory))
           (let* ((gate-results (multiple-value-list
                                 (aligned-rank-gates cases (* max-candidates 4))))
                  (gates (first gate-results))
                  (seen (make-hash-table :test #'equal))
                  (variants nil))
             (write-readable-object-atomically gates (merge-pathnames "gate-ranking.sexp" directory))
             (write-readable-object-atomically
              (second gate-results) (merge-pathnames "gate-diagnostics.sexp" directory))
             (format t "~&GATE SEARCH ~S~%" (second gate-results))
             (finish-output)
             ;; All genotype variants are independent copies of C13 with its one
             ;; added learner edited. They remain v9 plus that single learner.
             (block build
               (dolist (gate gates)
                 (dolist (margin '(250.0d0 1000.0d0))
                   (let* ((child (aligned-refine-child repair spec (getf gate :predicates) margin))
                          (effects
                            (loop for case in cases
                                  for context = (getf case :context)
                                  for event = (getf context :event)
                                  for decision = (brute-resolve-team child controller event)
                                  collect (cage2-controller-decision-concrete-action decision))))
                     (unless (gethash effects seen)
                       (setf (gethash effects seen) t)
                       (let* ((id (format nil "refined-~D" (1+ (length variants))))
                              (path (merge-pathnames (format nil "~A.lisp" id) directory))
                              (manifest (list :id id :path (namestring path)
                                              :predicates (getf gate :predicates)
                                              :margin margin :nomination-evidence gate
                                              :aligned-evidence nil)))
                         (brute-save-policy child 0.0d0 path metadata "Cage2-meander-100-v0")
                         (push manifest variants)
                         (when (= (length variants) max-candidates) (return-from build))))))))
             (setf variants (nreverse variants))
             (write-readable-object-atomically variants (merge-pathnames "variants.sexp" directory))
             ;; Measure unknown effective actions rather than treating them as zero.
             (dolist (variant variants)
               (let* ((child (brute-canonicalize-ids (load-best-team (getf variant :path))))
                      (rows nil))
                 (dolist (case cases)
                   (let* ((context (getf case :context))
                          (event (getf context :event))
                          (decision (brute-resolve-team child controller event))
                          (concrete (cage2-controller-decision-concrete-action decision))
                          (key (brute-credit-key context concrete)))
                     (multiple-value-bind (delta present)
                         (if (= concrete (getf event :incumbent-concrete))
                             (values 0.0d0 t) (gethash key known))
                       (when (and (not present) (< query-count extra-queries))
                         (multiple-value-bind (result measured-concrete)
                             (aligned-full-ranking-query
                              env controller
                              (if (eq (getf case :trajectory) :repair) repair parent)
                              (getf variant :path)
                              (gethash (getf case :episode-key) episode-cache)
                              context directory log)
                           (when result
                             (incf query-count)
                             (setf delta (getf result :delta) present t
                                   (gethash (brute-credit-key context measured-concrete) known) delta))))
                       (push (list :seed (getf context :seed) :step (getf event :step)
                                   :actual-concrete concrete :status (if present :measured :unknown)
                                   :delta (and present (- delta (getf case :repair-delta)))) rows))))
                 (setf (getf variant :aligned-evidence)
                       (brute-credit-statistics (nreverse rows)))))
             (write-readable-object-atomically variants (merge-pathnames "aligned-variants.sexp" directory))
             (setf variants
                   (stable-sort variants #'>
                                :key (lambda (v) (or (getf (getf v :aligned-evidence) :mean)
                                                     most-negative-double-float))))
             (when variants
              (let* ((eval-seeds (remove-duplicates
                                 (append evaluation-seeds (mapcar (lambda (c) (getf (getf c :context) :seed)) cases))))
                    (baselines
                      (loop for seed in eval-seeds
                            collect (brute-episode env controller parent "Cage2-meander-100-v0" seed log
                                                   :observer (lambda (e) (py4cl2:pycall "_bes_privileged_state" e)))))
                    (base-returns (mapcar (lambda (e) (getf e :return)) baselines))
                    (base-safety (mapcar #'brute-episode-safety baselines)))
               (dolist (variant variants)
                 (let* ((path (pathname (getf variant :path)))
                        (child (load-best-team path))
                        (episodes (loop for seed in eval-seeds
                                        collect (brute-episode
                                                 env controller child "Cage2-meander-100-v0" seed log
                                                 :observer (lambda (e) (py4cl2:pycall "_bes_privileged_state" e)))))
                        (returns (mapcar (lambda (e) (getf e :return)) episodes))
                        (violations (brute-safety-regressions
                                     base-safety (mapcar #'brute-episode-safety episodes)))
                        (result (list :variant variant :seeds eval-seeds
                                      :baseline-returns base-returns :returns returns
                                      :paired (robustness-paired-summary returns base-returns)
                                      :protected-host-passed (null violations)
                                      :violations violations)))
                   (brute-save-policy child (arithmetic-mean returns) path metadata "Cage2-meander-100-v0")
                   (let ((loaded (load-best-team path)))
                     (loop for seed in eval-seeds for expected in returns
                           for actual = (getf (brute-episode env controller loaded
                                                            "Cage2-meander-100-v0" seed log) :return)
                           unless (= expected actual) do (error "Serialized refined policy changed returns.")))
                   (push result evaluated)
                   (write-readable-object-atomically result
                                                    (merge-pathnames (format nil "~A-result.sexp" (getf variant :id))
                                                                     directory))
                   (format t "~&REFINED ~A paired-mean=~,4F protected-host-passed=~A~%"
                           (getf variant :id) (getf (getf result :paired) :mean) (null violations))
                   (finish-output)))))))
      (when env (py4cl2:pymethod env "close")))
    (setf evaluated (nreverse evaluated))
    (let* ((eligible
             (remove-if-not (lambda (row)
                              (and (getf row :protected-host-passed)
                                   (plusp (getf (getf row :paired) :mean))))
                            evaluated))
           (best (first (stable-sort eligible #'>
                                     :key (lambda (row) (getf (getf row :paired) :mean)))))
           (summary (list :protocol +aligned-repair-protocol+ :parent parent-path :repair repair-path
                          :cases (length cases)
                          :sampling (read-readable-object (merge-pathnames "sampling.sexp" directory))
                          :discovery-seeds seeds
                          :extra-official-queries query-count
                          :best-discovery-path (and best (getf (getf best :variant) :path))
                          :candidates evaluated :evidence :discovery-only)))
      (write-readable-object-atomically summary (merge-pathnames "summary.sexp" directory))
      (with-open-file (out (merge-pathnames "report.txt" directory)
                           :direction :output :if-exists :supersede)
        (format out "Measured cases=~D variants=~D additional queries=~D~%"
                (length cases) (length evaluated) query-count)
        (dolist (case cases)
          (format out "case seed=~D step=~D keep-advantage=~,4F~%"
                  (getf (getf case :context) :seed)
                  (getf (getf (getf case :context) :event) :step)
                  (getf case :keep-advantage)))
        (dolist (row evaluated)
          (format out "~%~A paired=~S protected-host=~A~%"
                  (getf (getf row :variant) :id) (getf row :paired)
                  (getf row :protected-host-passed)))
        (format out "~%Discovery best=~S~%" (getf summary :best-discovery-path))))
    (format t "~&done~%")))
