(in-package :cl-tpg)

(defconstant +robustness-validation-protocol+
  :official-robustness-validation-v1)

(defconstant +robustness-seed-stream-tag+ 9
  "High-bit namespace reserved for post-training robustness evaluation.")

(defparameter +robustness-catastrophic-thresholds+
  '(-40.0d0 -50.0d0 -100.0d0))

(defun robustness-validation-seed (root horizon episode-index)
  "Derive one deterministic seed disjoint from all training seed namespaces."
  (unless (and (integerp root) (not (minusp root))
               (member horizon '(30 50 100))
               (integerp episode-index) (not (minusp episode-index)))
    (error "Invalid robustness seed coordinates: root=~S horizon=~S episode=~S."
           root horizon episode-index))
  (let* ((mixed
           (official-guided-mix64
            (+ root (* horizon 1000003) episode-index)))
         (payload
           (1+ (mod mixed +official-guided-seed-payload-mask+))))
    (logior (ash +robustness-seed-stream-tag+
                 +official-guided-seed-payload-bits+)
            payload)))

(defun robustness-validation-seed-namespace (seed)
  (ash seed (- +official-guided-seed-payload-bits+)))

(defun robustness-quantile (values fraction)
  (if (null values)
      0.0d0
      (let* ((sorted (sort (copy-list values) #'<))
             (index (floor (* fraction (1- (length sorted))))))
        (coerce (nth index sorted) 'double-float))))

(defun robustness-cvar (values fraction)
  "Return the mean of the lowest FRACTION of VALUES."
  (if (null values)
      0.0d0
      (let* ((sorted (sort (copy-list values) #'<))
             (count (max 1 (ceiling (* fraction (length sorted))))))
        (validation-mean (subseq sorted 0 count)))))

(defun robustness-standard-error (values)
  (if (plusp (length values))
      (/ (validation-std values)
         (sqrt (coerce (length values) 'double-float)))
      0.0d0))

(defun robustness-return-summary (values)
  (let ((values (mapcar (lambda (value) (coerce value 'double-float)) values)))
    (list :episodes (length values)
          :mean (validation-mean values)
          :std (validation-std values)
          :se (robustness-standard-error values)
          :median (robustness-quantile values 0.5d0)
          :q05 (robustness-quantile values 0.05d0)
          :q10 (robustness-quantile values 0.10d0)
          :cvar05 (robustness-cvar values 0.05d0)
          :cvar10 (robustness-cvar values 0.10d0)
          :minimum (if values (reduce #'min values) 0.0d0)
          :maximum (if values (reduce #'max values) 0.0d0)
          :catastrophic-counts
            (loop for threshold in +robustness-catastrophic-thresholds+
                  collect
                    (cons threshold
                          (count-if (lambda (value) (<= value threshold))
                                    values))))))

(defun robustness-paired-summary (left right)
  "Summarize LEFT-RIGHT paired return differences."
  (unless (= (length left) (length right))
    (error "Paired robustness samples differ in length: ~D versus ~D."
           (length left) (length right)))
  (let* ((deltas (mapcar #'- left right))
         (epsilon 1.0d-9))
    (append
     (robustness-return-summary deltas)
     (list :wins (count-if (lambda (delta) (> delta epsilon)) deltas)
           :ties (count-if (lambda (delta) (<= (abs delta) epsilon)) deltas)
           :losses (count-if (lambda (delta) (< delta (- epsilon))) deltas)))))

(defun robustness-read-journal (path)
  (if (probe-file path)
      (with-open-file (stream path :direction :input)
        (with-standard-io-syntax
          (loop for record = (read stream nil :eof)
                until (eq record :eof)
                collect record)))
      nil))

(defun robustness-append-journal-record (path record)
  (ensure-directories-exist path)
  (with-open-file (stream path
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (with-standard-io-syntax
      (let ((*print-pretty* nil)
            (*print-length* nil)
            (*print-level* nil))
        (prin1 record stream)
        (terpri stream)
        (finish-output stream)))))

(defun robustness-record-key (record)
  (list (getf record :horizon)
        (getf record :root)
        (getf record :episode)
        (getf record :policy)))

(defun robustness-record-index (records)
  (let ((index (make-hash-table :test #'equal)))
    (dolist (record records index)
      (unless (eq (getf record :protocol) +robustness-validation-protocol+)
        (error "Unexpected robustness journal protocol: ~S." record))
      (let ((key (robustness-record-key record)))
        (when (gethash key index)
          (error "Duplicate robustness journal record: ~S." key))
        (setf (gethash key index) record)))))

(defun robustness-values (records policy &key root horizon)
  (loop for record in records
        when (and (eq (getf record :policy) policy)
                  (or (null root) (= (getf record :root) root))
                  (or (null horizon) (= (getf record :horizon) horizon)))
          collect (getf record :return)))

(defun robustness-cell-summaries (records policies roots horizons)
  (loop for horizon in horizons append
        (loop for root in roots append
              (loop for policy in policies
                    for values = (robustness-values
                                  records policy :root root :horizon horizon)
                    collect
                      (list :horizon horizon :root root :policy policy
                            :statistics (robustness-return-summary values))))))

(defun robustness-policy-seed-table (records policy root horizon)
  (let ((table (make-hash-table :test #'eql)))
    (dolist (record records table)
      (when (and (eq (getf record :policy) policy)
                 (or (null root) (= (getf record :root) root))
                 (= (getf record :horizon) horizon))
        (setf (gethash (getf record :seed) table)
              (getf record :return))))))

(defun robustness-pair-summaries (records roots horizons candidate opponents)
  (loop for horizon in horizons append
        (loop for root in roots append
              (loop for opponent in opponents
                    for candidate-table =
                      (robustness-policy-seed-table
                       records candidate root horizon)
                    for opponent-table =
                      (robustness-policy-seed-table
                       records opponent root horizon)
                    for common-seeds =
                      (sort
                       (loop for seed being the hash-keys of candidate-table
                             when (nth-value 1 (gethash seed opponent-table))
                               collect seed)
                       #'<)
                    collect
                      (list
                       :horizon horizon :root root
                       :candidate candidate :opponent opponent
                       :statistics
                         (robustness-paired-summary
                          (mapcar (lambda (seed)
                                    (gethash seed candidate-table))
                                  common-seeds)
                          (mapcar (lambda (seed)
                                    (gethash seed opponent-table))
                                  common-seeds)))))))

(defun robustness-aggregate-cell-summaries (records policies horizons)
  (loop for horizon in horizons append
        (loop for policy in policies
              for values = (robustness-values records policy :horizon horizon)
              collect
                (list :horizon horizon :policy policy
                      :statistics (robustness-return-summary values)))))

(defun robustness-aggregate-pair-summaries
       (records horizons candidate opponents)
  (loop for horizon in horizons append
        (loop for opponent in opponents
              for candidate-table =
                (robustness-policy-seed-table records candidate nil horizon)
              for opponent-table =
                (robustness-policy-seed-table records opponent nil horizon)
              for common-seeds =
                (sort
                 (loop for seed being the hash-keys of candidate-table
                       when (nth-value 1 (gethash seed opponent-table))
                         collect seed)
                 #'<)
              collect
                (list
                 :horizon horizon :candidate candidate :opponent opponent
                 :statistics
                   (robustness-paired-summary
                    (mapcar (lambda (seed) (gethash seed candidate-table))
                            common-seeds)
                    (mapcar (lambda (seed) (gethash seed opponent-table))
                            common-seeds))))))

(defun robustness-policy-description (policy)
  (list :label (getf policy :label)
        :path (getf policy :path)
        :fitness (getf policy :fitness)
        :generation (getf policy :generation)
        :controller-protocol
          (getf (getf policy :metadata) :cage2-controller-protocol)
        :terminal-action-format
          (getf (getf policy :metadata) :terminal-action-format)
        :num-observations
          (getf (getf policy :metadata) :num-observations)))

(defun robustness-build-summary
       (records policies roots horizons episodes-per-root)
  (let* ((labels (mapcar (lambda (policy) (getf policy :label)) policies))
         (expected (* (length labels) (length roots) (length horizons)
                      episodes-per-root)))
    (list
     :protocol +robustness-validation-protocol+
     :seed-namespace +robustness-seed-stream-tag+
     :roots (copy-list roots)
     :horizons (copy-list horizons)
     :episodes-per-root episodes-per-root
     :completed-records (length records)
     :expected-records expected
     :complete-p (= (length records) expected)
     :policies (mapcar #'robustness-policy-description policies)
     :aggregate-cells
       (robustness-aggregate-cell-summaries records labels horizons)
     :aggregate-paired
       (robustness-aggregate-pair-summaries
        records horizons :v14 '(:v13 :compiled))
     :cells (robustness-cell-summaries records labels roots horizons)
     :paired
       (robustness-pair-summaries
        records roots horizons :v14 '(:v13 :compiled))
     :same-root-warning
       "The same seed couples initial RNG state only; diverged policies may consume later randomness differently.")))

(defun robustness-write-text-report (summary path)
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (format stream "Official robustness validation~%")
    (format stream "protocol: ~A~%" (getf summary :protocol))
    (format stream "progress: ~D/~D complete=~A~%"
            (getf summary :completed-records)
            (getf summary :expected-records)
            (getf summary :complete-p))
    (format stream "roots: ~S~%horizons: ~S~%episodes/root: ~D~%~%"
            (getf summary :roots) (getf summary :horizons)
            (getf summary :episodes-per-root))
    (format stream "Aggregate across roots:~%")
    (dolist (cell (getf summary :aggregate-cells))
      (let* ((stats (getf cell :statistics))
             (catastrophic (getf stats :catastrophic-counts)))
        (format stream
                "h=~3D policy=~10A n=~4D mean=~,4F std=~,4F se=~,4F cvar10=~,4F min=~,4F cat40/50/100=~D/~D/~D~%"
                (getf cell :horizon) (getf cell :policy)
                (getf stats :episodes) (getf stats :mean) (getf stats :std)
                (getf stats :se) (getf stats :cvar10) (getf stats :minimum)
                (cdr (assoc -40.0d0 catastrophic))
                (cdr (assoc -50.0d0 catastrophic))
                (cdr (assoc -100.0d0 catastrophic)))))
    (format stream "~%Aggregate paired candidate deltas (v14 - opponent):~%")
    (dolist (pair (getf summary :aggregate-paired))
      (let ((stats (getf pair :statistics)))
        (format stream
                "h=~3D opponent=~10A n=~4D mean=~,4F se=~,4F wins/ties/losses=~D/~D/~D~%"
                (getf pair :horizon) (getf pair :opponent)
                (getf stats :episodes) (getf stats :mean) (getf stats :se)
                (getf stats :wins) (getf stats :ties) (getf stats :losses))))
    (format stream "~%Per-root cells:~%")
    (dolist (cell (getf summary :cells))
      (let* ((stats (getf cell :statistics))
             (catastrophic (getf stats :catastrophic-counts)))
        (format stream
                "h=~3D root=~8D policy=~10A n=~4D mean=~,4F std=~,4F se=~,4F cvar10=~,4F min=~,4F cat40/50/100=~D/~D/~D~%"
                (getf cell :horizon) (getf cell :root) (getf cell :policy)
                (getf stats :episodes) (getf stats :mean) (getf stats :std)
                (getf stats :se) (getf stats :cvar10) (getf stats :minimum)
                (cdr (assoc -40.0d0 catastrophic))
                (cdr (assoc -50.0d0 catastrophic))
                (cdr (assoc -100.0d0 catastrophic)))))
    (format stream "~%Paired candidate deltas (v14 - opponent):~%")
    (dolist (pair (getf summary :paired))
      (let ((stats (getf pair :statistics)))
        (format stream
                "h=~3D root=~8D opponent=~10A n=~4D mean=~,4F se=~,4F wins/ties/losses=~D/~D/~D~%"
                (getf pair :horizon) (getf pair :root) (getf pair :opponent)
                (getf stats :episodes) (getf stats :mean) (getf stats :se)
                (getf stats :wins) (getf stats :ties) (getf stats :losses)))))
  path)

(defun robustness-persist-summary
       (records policies roots horizons episodes-per-root output-directory)
  (let ((summary
          (robustness-build-summary
           records policies roots horizons episodes-per-root)))
    (rare-failure-write-form
     summary (merge-pathnames "summary.sexp" output-directory))
    (robustness-write-text-report
     summary (merge-pathnames "report.txt" output-directory))
    summary))

(defun robustness-validate-seed-plan (roots horizons episodes-per-root)
  (let ((seen (make-hash-table :test #'eql)))
    (dolist (root roots)
      (dolist (horizon horizons)
        (dotimes (episode episodes-per-root)
          (let ((seed (robustness-validation-seed root horizon episode)))
            (unless (= (robustness-validation-seed-namespace seed)
                       +robustness-seed-stream-tag+)
              (error "Robustness seed escaped its namespace: ~D." seed))
            (when (gethash seed seen)
              (error "Robustness seed collision for seed ~D." seed))
            (setf (gethash seed seen) t)))))
    (hash-table-count seen)))

(defun robustness-validate-existing-records
       (records policies roots horizons episodes-per-root)
  (let ((labels (mapcar (lambda (policy) (getf policy :label)) policies)))
    (dolist (record records t)
      (let ((root (getf record :root))
            (horizon (getf record :horizon))
            (episode (getf record :episode))
            (policy (getf record :policy))
            (seed (getf record :seed)))
        (unless (and (member root roots :test #'=)
                     (member horizon horizons :test #'=)
                     (integerp episode) (<= 0 episode)
                     (< episode episodes-per-root)
                     (member policy labels :test #'eq)
                     (= seed (robustness-validation-seed
                              root horizon episode)))
          (error "Robustness journal record does not belong to this run: ~S."
                 record))))))

(defun run-robustness-validation
       (v13-path v14-path compiled-path output-directory roots
        &key (episodes-per-root 100) (horizons '(100)))
  "Run resumable paired official validation on post-training seed streams."
  (unless (and roots (every (lambda (root)
                              (and (integerp root) (not (minusp root))))
                            roots))
    (error "Robustness roots must be non-negative integers, got ~S." roots))
  (unless (and (integerp episodes-per-root) (plusp episodes-per-root))
    (error "Robustness episodes-per-root must be positive, got ~S."
           episodes-per-root))
  (unless (and horizons (every (lambda (horizon)
                                 (member horizon '(30 50 100)))
                               horizons))
    (error "Robustness horizons must use 30, 50, or 100, got ~S." horizons))
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
         (*cage2-controller-decoy-order-profile* :heuristic)
         (*cage2-opening-mode* :fixed)
         (*teacher-backend* :heuristic)
         (*recurrent-policy-enabled* nil)
         (*hamming-space-enabled* nil)
         (policies
           (list (rare-failure-load-policy :v13 v13-path)
                 (rare-failure-load-policy :v14 v14-path)
                 (rare-failure-load-policy :compiled compiled-path)))
         (records (robustness-read-journal journal-path))
         (index (robustness-record-index records))
         (completed-episodes 0)
         (total-episodes (* (length roots) (length horizons)
                            episodes-per-root)))
    (robustness-validate-existing-records
     records policies roots horizons episodes-per-root)
    (ensure-directories-exist journal-path)
    (dolist (horizon horizons)
      (dolist (root roots)
        (dotimes (episode episodes-per-root)
          (let ((seed (robustness-validation-seed root horizon episode)))
            (dolist (policy policies)
              (let* ((label (getf policy :label))
                     (key (list horizon root episode label)))
                (unless (gethash key index)
                  (let* ((environment-name
                           (cage2-validation-environment-name "b_line" horizon))
                         (return
                           (coerce
                            (cl-gym:rollout
                             (getf policy :team) environment-name seed)
                            'double-float))
                         (record
                           (list :protocol +robustness-validation-protocol+
                                 :horizon horizon :root root :episode episode
                                 :seed seed :policy label :return return)))
                    (robustness-append-journal-record journal-path record)
                    (push record records)
                    (setf (gethash key index) record)))))
            (incf completed-episodes)
            (when (or (= completed-episodes 1)
                      (zerop (mod completed-episodes 10))
                      (= completed-episodes total-episodes))
              (format t
                      "robustness episodes=~D/~D horizon=~D root=~D episode=~D seed=~D~%"
                      completed-episodes total-episodes horizon root
                      (1+ episode) seed)
              (finish-output))))
        (robustness-persist-summary
         records policies roots horizons episodes-per-root output-directory)))
    (robustness-persist-summary
     records policies roots horizons episodes-per-root output-directory)))

(defun robustness-parse-integers (text)
  (loop for start = 0 then (1+ comma)
        for comma = (position #\, text :start start)
        for token = (string-trim '(#\Space #\Tab)
                                 (subseq text start comma))
        collect (parse-integer token)
        while comma))

(defun run-robustness-validation-from-environment ()
  (flet ((required (name)
           (or (uiop:getenv name)
               (error "Required environment variable ~A is missing." name))))
    (run-robustness-validation
     (required "ROBUSTNESS_V13_CHECKPOINT")
     (required "ROBUSTNESS_V14_CHECKPOINT")
     (required "ROBUSTNESS_COMPILED_CHECKPOINT")
     (required "ROBUSTNESS_OUTPUT_DIRECTORY")
     (robustness-parse-integers (required "ROBUSTNESS_ROOTS"))
     :episodes-per-root
       (parse-integer (required "ROBUSTNESS_EPISODES_PER_ROOT"))
     :horizons
       (robustness-parse-integers (required "ROBUSTNESS_HORIZONS")))))
