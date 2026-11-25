(in-package :cl-tpg)

(defconstant +paired-robustness-validation-protocol+
  :official-paired-robustness-validation-v1)

(defun paired-robustness-record-index (records)
  (let ((index (make-hash-table :test #'equal)))
    (dolist (record records index)
      (unless (eq (getf record :protocol)
                  +paired-robustness-validation-protocol+)
        (error "Unexpected paired-validation journal protocol: ~S." record))
      (let ((key (robustness-record-key record)))
        (when (gethash key index)
          (error "Duplicate paired-validation record: ~S." key))
        (setf (gethash key index) record)))))

(defun paired-robustness-validate-records
       (records roots horizons episodes-per-root red-agent)
  (dolist (record records t)
    (let ((root (getf record :root))
          (horizon (getf record :horizon))
          (episode (getf record :episode))
          (seed (getf record :seed)))
      (unless (and (equal (getf record :red-agent) red-agent)
                   (member (getf record :policy)
                           '(:incumbent :challenger))
                   (integerp root) (member root roots :test #'=)
                   (integerp horizon) (member horizon horizons :test #'=)
                   (integerp episode) (<= 0 episode)
                   (< episode episodes-per-root)
                   (numberp (getf record :return))
                   (integerp seed)
                   (= seed (robustness-validation-seed
                            root horizon episode)))
        (error "Paired-validation record does not belong to this run: ~S."
               record)))))

(defun paired-robustness-summary
       (records policies roots horizons episodes-per-root red-agent)
  (let ((expected (* 2 (length roots) (length horizons)
                     episodes-per-root)))
    (list
     :protocol +paired-robustness-validation-protocol+
     :red-agent red-agent
     :seed-namespace +robustness-seed-stream-tag+
     :roots (copy-list roots)
     :horizons (copy-list horizons)
     :episodes-per-root episodes-per-root
     :completed-records (length records)
     :expected-records expected
     :complete-p (= (length records) expected)
     :policies (mapcar #'robustness-policy-description policies)
     :aggregate-cells
       (robustness-aggregate-cell-summaries
        records '(:incumbent :challenger) horizons)
     :aggregate-paired
       (robustness-aggregate-pair-summaries
        records horizons :challenger '(:incumbent))
     :cells
       (robustness-cell-summaries
        records '(:incumbent :challenger) roots horizons)
     :paired
       (robustness-pair-summaries
        records roots horizons :challenger '(:incumbent))
     :same-root-warning
       "Matching seeds couple initial RNG state, not every later event after policies diverge.")))

(defun paired-robustness-write-report (summary path)
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (format stream "Official paired robustness validation: ~A~%"
            (getf summary :red-agent))
    (format stream "progress: ~D/~D complete=~A~%roots: ~S~%horizons: ~S~%episodes/root: ~D~%~%"
            (getf summary :completed-records)
            (getf summary :expected-records)
            (getf summary :complete-p)
            (getf summary :roots)
            (getf summary :horizons)
            (getf summary :episodes-per-root))
    (format stream "Aggregate returns:~%")
    (dolist (cell (getf summary :aggregate-cells))
      (let ((stats (getf cell :statistics)))
        (format stream "h=~3D policy=~10A n=~4D mean=~,4F std=~,4F se=~,4F cvar10=~,4F~%"
                (getf cell :horizon) (getf cell :policy)
                (getf stats :episodes) (getf stats :mean)
                (getf stats :std) (getf stats :se)
                (getf stats :cvar10))))
    (format stream "~%Paired delta (challenger - incumbent):~%")
    (dolist (pair (getf summary :aggregate-paired))
      (let ((stats (getf pair :statistics)))
        (format stream "h=~3D n=~4D mean=~,4F se=~,4F wins/ties/losses=~D/~D/~D~%"
                (getf pair :horizon) (getf stats :episodes)
                (getf stats :mean) (getf stats :se)
                (getf stats :wins) (getf stats :ties)
                (getf stats :losses))))
    (format stream "~%Per-root paired deltas:~%")
    (dolist (pair (getf summary :paired))
      (let ((stats (getf pair :statistics)))
        (format stream "h=~3D root=~8D n=~4D mean=~,4F se=~,4F~%"
                (getf pair :horizon) (getf pair :root)
                (getf stats :episodes) (getf stats :mean)
                (getf stats :se))))
    (format stream "~%~A~%" (getf summary :same-root-warning)))
  path)

(defun paired-robustness-persist
       (records policies roots horizons episodes-per-root red-agent
        output-directory)
  (let ((summary
          (paired-robustness-summary
           records policies roots horizons episodes-per-root red-agent)))
    (rare-failure-write-form
     summary (merge-pathnames "summary.sexp" output-directory))
    (paired-robustness-write-report
     summary (merge-pathnames "report.txt" output-directory))
    summary))

(defun run-paired-robustness-validation
       (incumbent-path challenger-path red-agent output-directory roots
        &key (episodes-per-root 100) (horizons '(30 50 100)))
  "Compare two frozen Semantic-36 policies on identical fresh official seeds.

The journal is append-only and resumable. The training/checkpoint state is not
modified; the heuristic backend selects the same opponent-specific Controller
profile used by official CAGE2 rollout."
  (unless (member red-agent '("b_line" "meander") :test #'string=)
    (error "Unsupported CAGE2 red agent: ~S." red-agent))
  (unless (and roots (every (lambda (root)
                             (and (integerp root) (not (minusp root))))
                           roots))
    (error "Paired robustness roots must be non-negative integers."))
  (unless (and (integerp episodes-per-root) (plusp episodes-per-root))
    (error "Episodes per root must be positive."))
  (unless (and horizons (every (lambda (horizon)
                                 (member horizon '(30 50 100)))
                               horizons))
    (error "Paired robustness horizons must be 30, 50, or 100."))
  (robustness-validate-seed-plan roots horizons episodes-per-root)
  (let* ((output-directory (uiop:ensure-directory-pathname output-directory))
         (journal-path (merge-pathnames "episodes.sexp" output-directory))
         (*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*instruction-set-profile* :reduced-eq)
         (*read-only-register-profile* :cage2-categorical-v1)
         (*decoy-order-mode* :fixed)
         (*cage2-controller-decoy-order-profile*
           (cage2-heuristic-controller-profile
            (cage2-validation-environment-name red-agent (first horizons))))
         (*cage2-opening-mode* :fixed)
         (*teacher-backend* :heuristic)
         (*recurrent-policy-enabled* nil)
         (*hamming-space-enabled* nil)
         (policies
           (list (rare-failure-load-policy :incumbent incumbent-path)
                 (rare-failure-load-policy :challenger challenger-path)))
         (records (robustness-read-journal journal-path))
         (index (paired-robustness-record-index records))
         (completed 0)
         (total (* (length roots) (length horizons)
                   episodes-per-root)))
    (paired-robustness-validate-records
     records roots horizons episodes-per-root red-agent)
    (ensure-directories-exist journal-path)
    (dolist (horizon horizons)
      (let ((environment-name
              (cage2-validation-environment-name red-agent horizon)))
        (dolist (root roots)
          (dotimes (episode episodes-per-root)
            (let ((seed (robustness-validation-seed root horizon episode)))
              (dolist (policy policies)
                (let* ((label (getf policy :label))
                       (key (list horizon root episode label)))
                  (unless (gethash key index)
                    (let ((record
                            (list
                             :protocol +paired-robustness-validation-protocol+
                             :red-agent red-agent
                             :horizon horizon :root root :episode episode
                             :seed seed :policy label
                             :return
                               (coerce
                                (cl-gym:rollout
                                 (getf policy :team) environment-name seed)
                                'double-float))))
                      (robustness-append-journal-record journal-path record)
                      (push record records)
                      (setf (gethash key index) record)))))
              (incf completed)
              (when (or (= completed 1)
                        (zerop (mod completed 10))
                        (= completed total))
                (format t "paired episodes=~D/~D horizon=~D root=~D episode=~D~%"
                        completed total horizon root (1+ episode))
                (finish-output))))
          (paired-robustness-persist
           records policies roots horizons episodes-per-root red-agent
           output-directory))))
    (paired-robustness-persist
     records policies roots horizons episodes-per-root red-agent
     output-directory)))

(defun run-paired-robustness-validation-from-environment ()
  (flet ((required (name)
           (or (uiop:getenv name)
               (error "Required environment variable ~A is missing." name))))
    (run-paired-robustness-validation
     (required "PAIRED_INCUMBENT_CHECKPOINT")
     (required "PAIRED_CHALLENGER_CHECKPOINT")
     (required "PAIRED_RED_AGENT")
     (required "PAIRED_OUTPUT_DIRECTORY")
     (robustness-parse-integers (required "PAIRED_ROOTS"))
     :episodes-per-root
       (parse-integer (required "PAIRED_EPISODES_PER_ROOT"))
     :horizons
       (robustness-parse-integers (required "PAIRED_HORIZONS")))))
