(in-package :cl-tpg)

(defun official-guided-mode-p ()
  "Return true when the frozen Phase-1 official-guided protocol is active."
  (eq *current-search-mode* :official-guided))

(defun official-guided-u64 (value)
  "Return the low unsigned 64 bits of VALUE."
  (ldb (byte 64 0) value))

(defun official-guided-mix64 (value)
  "Deterministically mix VALUE without consuming Common Lisp random state."
  (let ((mixed
          (official-guided-u64
           (+ value #x9E3779B97F4A7C15))))
    (setf mixed
          (official-guided-u64
           (* (logxor mixed (ash mixed -30))
              #xBF58476D1CE4E5B9)))
    (setf mixed
          (official-guided-u64
           (* (logxor mixed (ash mixed -27))
              #x94D049BB133111EB)))
    (official-guided-u64 (logxor mixed (ash mixed -31)))))

(defun official-guided-stream-tag (name)
  "Return the disjoint high-bit namespace assigned to seed stream NAME."
  (ecase name
    (:training 0)
    (:racing 1)
    (:promotion 2)
    (:reference 3)
    ;; Phase-2 diagnostics derive this stream from their own persisted cursor;
    ;; it is not part of the four Phase-1 stream plists.
    (:locality 4)))

(defun official-guided-derived-root (search-seed salt)
  "Derive one reproducible stream root from SEARCH-SEED and SALT."
  (official-guided-mix64 (+ search-seed salt)))

(defun initialize-official-guided-seed-streams (search-seed)
  "Initialize four independent deterministic seed streams."
  (unless (integerp search-seed)
    (error "Official-guided seed initialization requires an integer, got ~S."
           search-seed))
  (setf *official-guided-seed-streams*
        (list
         :version 1
         :training
           (list :roots
                 (list (official-guided-derived-root search-seed 104729))
                 :cursor 0)
         :racing
           (list :roots
                 (list (official-guided-derived-root search-seed 130363))
                 :cursor 0)
         :promotion
           (list :roots
                 (list (official-guided-derived-root search-seed 155921))
                 :cursor 0)
         :reference
           (list :roots (copy-list +official-guided-reference-roots+)
                 :cursor 0)))
  *official-guided-seed-streams*)

(defun official-guided-seed-stream-valid-p (name stream)
  "Return true when STREAM is a valid serialized stream for NAME."
  (and (member name '(:training :racing :promotion :reference) :test #'eq)
       (listp stream)
       (let ((roots (getf stream :roots))
             (cursor (getf stream :cursor)))
         (and (consp roots)
              (every #'integerp roots)
              (integerp cursor)
              (not (minusp cursor))))))

(defun official-guided-seed-streams-valid-p (state)
  "Return true when STATE contains all four recoverable stream cursors."
  (and (listp state)
       (= (getf state :version 0) 1)
       (every
        (lambda (name)
          (official-guided-seed-stream-valid-p name (getf state name)))
        '(:training :racing :promotion :reference))))

(defun restore-official-guided-seed-streams (state)
  "Restore a validated, independently owned seed-stream STATE."
  (unless (official-guided-seed-streams-valid-p state)
    (error "Invalid official-guided seed-stream state: ~S" state))
  (setf *official-guided-seed-streams* (copy-tree state)))

(defun official-guided-seed-at (name root cursor)
  "Return one deterministic environment seed in NAME's disjoint namespace."
  (let* ((tag (official-guided-stream-tag name))
         (payload
           (1+
            (mod (official-guided-mix64 (+ root cursor))
                 +official-guided-seed-payload-mask+))))
    (logior (ash tag +official-guided-seed-payload-bits+) payload)))

(defun official-guided-take-seeds (name count)
  "Take COUNT seeds from one single-root stream and advance its cursor."
  (unless (member name '(:training :racing :promotion) :test #'eq)
    (error "~S is not a single-root official-guided seed stream." name))
  (unless (and (integerp count) (plusp count))
    (error "Official-guided seed count must be positive, got ~S." count))
  (unless *official-guided-seed-streams*
    (error "Official-guided seed streams are not initialized."))
  (let* ((stream (getf *official-guided-seed-streams* name))
         (root (first (getf stream :roots)))
         (cursor (getf stream :cursor))
         (seeds
           (loop for offset below count
                 collect (official-guided-seed-at
                          name root (+ cursor offset)))))
    (incf (getf stream :cursor) count)
    seeds))

(defun official-guided-take-reference-seeds
       (&optional
          (episodes-per-root +official-guided-reference-episodes-per-root+))
  "Take a balanced monitoring block from roots 153, 42, and 2026."
  (unless (and (integerp episodes-per-root) (plusp episodes-per-root))
    (error "Reference episodes per root must be positive, got ~S."
           episodes-per-root))
  (unless *official-guided-seed-streams*
    (error "Official-guided seed streams are not initialized."))
  (let* ((stream (getf *official-guided-seed-streams* :reference))
         (roots (getf stream :roots))
         (cursor (getf stream :cursor))
         (seeds
           (loop for root in roots
                 append
                 (loop for offset below episodes-per-root
                       collect
                       (official-guided-seed-at
                        :reference root (+ cursor offset))))))
    (incf (getf stream :cursor) episodes-per-root)
    seeds))

(defun official-guided-seed-state-copy ()
  "Return a serialization-safe copy of all Phase-1 stream roots and cursors."
  (and *official-guided-seed-streams*
       (copy-tree *official-guided-seed-streams*)))

(defun official-guided-runtime-state ()
  "Return the small recoverable state journaled beside the best checkpoint."
  (list :version 6
        :fitness-protocol +official-guided-fitness-protocol+
        :checkpoint-filename (best-team-checkpoint-filename)
        :generation *generation*
        :search-seed *current-search-seed*
        :seed-streams (official-guided-seed-state-copy)
        :phase4-selection-state
          (and *phase4-selection-enabled*
               (fboundp 'phase4-selection-state-copy)
               (phase4-selection-state-copy))
        :phase4b-routing-repair-state
          (and *phase4b-routing-repair-enabled*
               (fboundp 'phase4b-routing-repair-state-copy)
               (phase4b-routing-repair-state-copy))
        :phase4b-specialist-composition-state
          (and *phase4b-specialist-composition-enabled*
               (fboundp 'phase4b-specialist-composition-state-copy)
               (phase4b-specialist-composition-state-copy))
        :incumbent-version *official-guided-incumbent-version*
        :best-evaluation (copy-tree *official-guided-best-evaluation*)
        :teacher-dagger-behavior-state
          (teacher-dagger-behavior-state-copy)
        :behavioral-locality-state
          (behavioral-locality-state-copy)))

(defun official-guided-state-path ()
  "Return the lightweight runtime-state journal path for the active run."
  (and *checkpoint-directory*
       (checkpoint-path *checkpoint-directory*
                        ".official-guided-state.lisp")))

(defun persist-official-guided-runtime-state ()
  "Atomically persist stream cursors after completed Phase-1 operations."
  (when (and (official-guided-mode-p) *checkpoint-directory*)
    (let* ((destination (official-guided-state-path))
           (temporary
             (make-pathname
              :name ".official-guided-state"
              :type "tmp"
              :defaults destination)))
      (ensure-directories-exist destination)
      (unwind-protect
           (progn
             (with-open-file (stream temporary
                                     :direction :output
                                     :if-exists :supersede
                                     :if-does-not-exist :create)
               (with-standard-io-syntax
                 (let ((*print-circle* t)
                       (*print-readably* t)
                       (*print-pretty* nil))
                   (write (official-guided-runtime-state) :stream stream))))
             (uiop:rename-file-overwriting-target temporary destination))
        (when (probe-file temporary)
          (delete-file temporary))))))

(defun read-official-guided-runtime-state (&optional directory)
  "Read the runtime journal from DIRECTORY or the active checkpoint directory."
  (let ((path
          (if directory
              (checkpoint-path directory ".official-guided-state.lisp")
              (official-guided-state-path))))
    (when (and path (probe-file path))
      (with-open-file (stream path :direction :input)
        (with-standard-io-syntax
          (read stream))))))

(defun restore-official-guided-runtime-state (metadata best-team-path)
  "Restore metadata, preferring a matching output or source-sibling journal."
  (let* ((metadata-state (getf metadata :official-guided-seed-streams))
         (metadata-version
           (or (getf metadata :official-guided-incumbent-version) 0))
         (checkpoint-filename
           (file-namestring (pathname best-team-path)))
         (output-journal (read-official-guided-runtime-state))
         (source-journal
           (read-official-guided-runtime-state
            (uiop:pathname-directory-pathname
             (pathname best-team-path))))
         (journal
           (cond
             ((and output-journal
                   (eq (getf output-journal :fitness-protocol)
                       +official-guided-fitness-protocol+)
                   (string=
                    (getf output-journal :checkpoint-filename "")
                    checkpoint-filename))
              output-journal)
             ((and source-journal
                   (eq (getf source-journal :fitness-protocol)
                       +official-guided-fitness-protocol+)
                   (string=
                    (getf source-journal :checkpoint-filename "")
                    checkpoint-filename))
              source-journal)))
         (journal-matches-p
           (not (null journal)))
         (journal-version
           (and journal-matches-p
                (getf journal :incumbent-version 0)))
         (chosen-state
           (if (and journal-matches-p
                    (>= journal-version metadata-version))
               (getf journal :seed-streams)
               metadata-state))
         (behavioral-state
           (if (and journal-matches-p
                    (>= journal-version metadata-version))
               (getf journal :behavioral-locality-state)
               (getf metadata :behavioral-locality-state)))
         (dagger-behavior-state
           (if (and journal-matches-p
                    (>= journal-version metadata-version))
                (getf journal :teacher-dagger-behavior-state)
                (getf metadata :teacher-dagger-behavior-state)))
         (phase4-selection-state
           (if (and journal-matches-p
                    (>= journal-version metadata-version))
               (getf journal :phase4-selection-state)
               (getf metadata :phase4-selection-state)))
         (phase4b-routing-repair-state
           (if (and journal-matches-p
                    (>= journal-version metadata-version))
               (getf journal :phase4b-routing-repair-state)
               (getf metadata :phase4b-routing-repair-state)))
         (phase4b-specialist-composition-state
           (if (and journal-matches-p
                    (>= journal-version metadata-version))
               (getf journal :phase4b-specialist-composition-state)
               (getf metadata :phase4b-specialist-composition-state))))
    (when chosen-state
      (restore-official-guided-seed-streams chosen-state))
    (setf *official-guided-incumbent-version*
          (if (and journal-matches-p
                   (>= journal-version metadata-version))
              journal-version
              metadata-version)
          *official-guided-best-evaluation*
          (copy-tree
           (if (and journal-matches-p
                    (>= journal-version metadata-version))
               (getf journal :best-evaluation)
               (getf metadata :official-guided-best-evaluation))))
    (when behavioral-state
      (restore-behavioral-locality-state behavioral-state))
    (when dagger-behavior-state
      (restore-teacher-dagger-behavior-state dagger-behavior-state))
    (when (and *phase4-selection-enabled* phase4-selection-state)
      (restore-phase4-selection-state phase4-selection-state))
    (when (and *phase4b-routing-repair-enabled*
               phase4b-routing-repair-state)
      (restore-phase4b-routing-repair-state phase4b-routing-repair-state))
    (when (and *phase4b-specialist-composition-enabled*
               phase4b-specialist-composition-state)
      (restore-phase4b-specialist-composition-state
       phase4b-specialist-composition-state))
    (values chosen-state journal-matches-p)))

(defun official-guided-teacher-mixing-rate ()
  "Return the next mixed-rollout teacher probability from prior disagreement."
  (if (null *last-dagger-diagnostics*)
      0.50d0
      (let ((rate
              (coerce
               (getf *last-dagger-diagnostics* :disagreement-rate 1.0d0)
               'double-float)))
        (loop for (threshold . teacher-rate)
                in +official-guided-teacher-mixing-rates+
              when (>= rate threshold)
                do (return teacher-rate)
              finally (return 0.10d0)))))

(defun official-guided-teacher-controls-p
       (episode-seed timestep teacher-rate)
  "Deterministically choose the actual controller without consuming a stream."
  (let* ((mixed
           (official-guided-mix64
            (+ episode-seed
               (* 1000003 (1+ timestep))
               (* 9176 (or *current-search-seed* 0)))))
         (unit
           (/ (coerce (logand mixed +official-guided-seed-payload-mask+)
                      'double-float)
              (coerce (1+ +official-guided-seed-payload-mask+)
                      'double-float))))
    (< unit teacher-rate)))

(defun official-guided-sample-variance (values)
  "Return unbiased sample variance for VALUES, or zero for fewer than two."
  (if (< (length values) 2)
      0.0d0
      (let ((mean (arithmetic-mean values)))
        (/ (loop for value in values
                 for delta = (- (coerce value 'double-float) mean)
                 sum (* delta delta) into total
                 finally (return (coerce total 'double-float)))
           (coerce (1- (length values)) 'double-float)))))

(defun official-guided-standard-error (values)
  "Return the standard error for numeric VALUES."
  (if (null values)
      0.0d0
      (sqrt (/ (official-guided-sample-variance values)
               (coerce (length values) 'double-float)))))

(defun official-guided-correlation (left right)
  "Return sample correlation for equally sized paired lists, or NIL if undefined."
  (unless (= (length left) (length right))
    (error "Paired score lengths differ: ~D and ~D."
           (length left) (length right)))
  (if (< (length left) 2)
      nil
      (let* ((left-mean (arithmetic-mean left))
             (right-mean (arithmetic-mean right))
             (cross
               (loop for x in left
                     for y in right
                     sum (* (- (coerce x 'double-float) left-mean)
                            (- (coerce y 'double-float) right-mean))
                       into total
                     finally (return (coerce total 'double-float))))
             (denominator
               (sqrt
                (* (loop for x in left
                         sum (expt (- (coerce x 'double-float) left-mean) 2))
                   (loop for y in right
                         sum (expt (- (coerce y 'double-float) right-mean) 2))))))
        (and (plusp denominator) (/ cross denominator)))))

(defun official-guided-comparison-statistics
       (candidate-returns incumbent-returns)
  "Return paired mean, SE, correlation, and paired/unpaired sample variances."
  (unless (= (length candidate-returns) (length incumbent-returns))
    (error "Official paired evaluation lengths differ: ~D and ~D."
           (length candidate-returns) (length incumbent-returns)))
  (let* ((differences (mapcar #'- candidate-returns incumbent-returns))
         (paired-variance (official-guided-sample-variance differences))
         (unpaired-variance
           (+ (official-guided-sample-variance candidate-returns)
              (official-guided-sample-variance incumbent-returns))))
    (values (arithmetic-mean differences)
            (official-guided-standard-error differences)
            (official-guided-correlation candidate-returns incumbent-returns)
            paired-variance
            unpaired-variance
            differences)))

(defun make-official-guided-evaluation-record
       (&key stage imitation-score seeds candidate-returns incumbent-returns
             accepted)
  "Build the structured Phase-1 fitness/evaluation record."
  (multiple-value-bind
        (paired-mean paired-se correlation paired-variance unpaired-variance
         differences)
      (official-guided-comparison-statistics
       candidate-returns incumbent-returns)
    (list :protocol +official-guided-fitness-protocol+
          :stage stage
          :accepted (not (null accepted))
          :imitation-score imitation-score
          :official-returns (copy-list candidate-returns)
          :incumbent-returns (copy-list incumbent-returns)
          :official-mean (arithmetic-mean candidate-returns)
          :official-std (sqrt (official-guided-sample-variance candidate-returns))
          :official-se (official-guided-standard-error candidate-returns)
          :incumbent-mean (arithmetic-mean incumbent-returns)
          :evaluated-seeds (copy-list seeds)
          :episode-count (length seeds)
          :paired-differences differences
          :paired-mean paired-mean
          :paired-se paired-se
          :same-seed-correlation correlation
          :paired-variance paired-variance
          :unpaired-variance unpaired-variance)))

(defun make-official-guided-parent-child-evaluation-record
       (child-returns parent-returns seeds behavioral-locality)
  "Return a causal paired record for one mutated child and its direct parent."
  (append
   (make-official-guided-evaluation-record
    :stage :parent-child-racing
    :imitation-score nil
    :seeds seeds
    :candidate-returns child-returns
    :incumbent-returns parent-returns
    :accepted nil)
   (list :behavioral-locality (copy-tree behavioral-locality))))

(defun official-guided-continue-p (candidate-returns incumbent-returns)
  "Return true unless paired evidence already establishes futility."
  (multiple-value-bind (mean se)
      (official-guided-comparison-statistics
       candidate-returns incumbent-returns)
    (let ((margin (* +official-guided-comparison-standard-errors+ se)))
      (values (> (+ mean margin) 0.0d0) mean margin))))

(defun official-guided-promote-p (candidate-returns incumbent-returns)
  "Promote only after a positive paired uncertainty margin."
  (multiple-value-bind (mean se)
      (official-guided-comparison-statistics
       candidate-returns incumbent-returns)
    (let ((margin (* +official-guided-comparison-standard-errors+ se)))
      (values (> mean margin) mean margin))))
