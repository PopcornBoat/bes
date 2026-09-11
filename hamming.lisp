(in-package :cl-tpg)

(defstruct (hamming-observation-index
             (:constructor %make-hamming-observation-index))
  "Immutable demonstrated-observation index used during one run."
  (prototypes #() :type simple-vector)
  (exact (make-hash-table :test #'equalp) :type hash-table)
  (cache (make-hash-table :test #'equalp) :type hash-table)
  (cache-lock (bt:make-lock "hamming-projection-cache"))
  source-path)

(defun hamming-source-fingerprint (path)
  "Return a portable name/byte-size identity for PATH."
  (let ((true-path (truename path)))
    (list :name (file-namestring true-path)
          :bytes (with-open-file
                     (stream true-path
                             :direction :input
                             :element-type '(unsigned-byte 8))
                   (file-length stream)))))

(defun add-hamming-prototype (observation prototypes exact)
  "Add OBSERVATION once, retaining dataset order for deterministic ties."
  (multiple-value-bind (existing present-p)
      (gethash observation exact)
    (declare (ignore existing))
    (unless present-p
      (vector-push-extend observation prototypes)
      (setf (gethash observation exact) observation))))

(defun make-hamming-index-from-dataset (dataset)
  "Build a unique observation index from a loaded semantic DATASET."
  (unless (eq (dataset-action-format dataset) :semantic)
    (error "Hamming projection requires a semantic CAGE2 dataset."))
  (let ((prototypes (make-array 1024 :adjustable t :fill-pointer 0))
        (exact (make-hash-table :test #'equalp)))
    (loop for observation across (observations dataset)
          do (add-hamming-prototype observation prototypes exact))
    (when (zerop (length prototypes))
      (error "Cannot build a Hamming index from an empty dataset."))
    (%make-hamming-observation-index
     :prototypes (coerce prototypes 'simple-vector)
     :exact exact
     :source-path (dataset-source-path dataset))))

(defun hamming-observation-from-semantic-form (form)
  "Return the expanded observation represented by FORM, or NIL if skipped."
  (unless (semantic-transition-form-p form)
    (error "Hamming reference is not a cage2-semantic-v1 dataset: ~S" form))
  (let ((fields (rest form)))
    (when (and (getf fields :representable)
               (getf fields :semantic-action))
      (let ((observation (getf fields :observation))
            (decoy-mask (getf fields :decoy-mask-before 0)))
        (unless (and (listp observation)
                     (= (length observation)
                        +cage2-scan-observation-size+))
          (error
           "Expected ~D source observations in Hamming reference, got ~A."
           +cage2-scan-observation-size+
           (if (listp observation) (length observation) (type-of observation))))
        (append-decoy-availability observation decoy-mask)))))

(defun load-hamming-observation-index (name)
  "Stream NAME and retain only its unique expanded semantic observations.

This avoids retaining action and transition columns when an online run or
validation only needs the demonstrated observation space."
  (let* ((path (resolve-dataset-path name))
         (source-path (namestring (truename path)))
         (prototypes (make-array 1024 :adjustable t :fill-pointer 0))
         (exact (make-hash-table :test #'equalp)))
    (with-open-file (stream path :direction :input)
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
            for observation = (hamming-observation-from-semantic-form form)
            when observation
              do (add-hamming-prototype observation prototypes exact)))
    (when (zerop (length prototypes))
      (error "Hamming reference dataset has no representable observations: ~A"
             source-path))
    (%make-hamming-observation-index
     :prototypes (coerce prototypes 'simple-vector)
     :exact exact
     :source-path source-path)))

(defun same-hamming-source-p (dataset name)
  "Return true when loaded DATASET and NAME identify the same file."
  (and dataset
       (dataset-source-path dataset)
       (equal (truename (dataset-source-path dataset))
              (truename (resolve-dataset-path name)))))

(defun configure-hamming-observation-space (&optional loaded-dataset)
  "Build or clear the fixed observation projector for the next operation.

LOADED-DATASET is reused when it is the configured reference file. Otherwise
the reference is streamed without retaining its unused transition columns."
  (if *hamming-space-enabled*
      (progn
        (unless *factored-actions-enabled*
          (error "Hamming projection is currently supported only for factored CAGE2 policies."))
        (unless (and *hamming-dataset-name*
                     (not (eq *hamming-dataset-name* :none)))
          (error "Hamming projection is enabled but no reference dataset was supplied."))
        (let ((index
                (if (same-hamming-source-p loaded-dataset
                                           *hamming-dataset-name*)
                    (make-hamming-index-from-dataset loaded-dataset)
                    (load-hamming-observation-index *hamming-dataset-name*))))
          (setf *hamming-observation-index* index
                *current-hamming-dataset-fingerprint*
                  (hamming-source-fingerprint
                   (hamming-observation-index-source-path index)))
          (emit-message
           (format nil
                   "Hamming projection enabled: reference=~A unique-observations=~D"
                   (hamming-observation-index-source-path index)
                   (length (hamming-observation-index-prototypes index))))))
      (setf *hamming-observation-index* nil
            *current-hamming-dataset-fingerprint* nil)))

(defun observation-block-mismatch-count (left right start end)
  "Count unequal categorical values in the half-open interval START..END."
  (loop for index from start below end
        count (not (= (aref left index) (aref right index)))))

(defun cage2-weighted-hamming-distance (left right)
  "Return block-normalized weighted Hamming distance as an integer cost.

Raw observation, scan state, and decoy availability contribute 50%, 25%, and
25% of the maximum cost respectively. The equivalent exact integer weights are
40, 104, and 13 per mismatch, avoiding floating-point tie instability."
  (unless (and (= (length left) +cage2-observation-size+)
               (= (length right) +cage2-observation-size+))
    (error "Hamming projection requires two ~D-value CAGE2 observations."
           +cage2-observation-size+))
  (let ((scan-end +cage2-scan-observation-size+))
    (+ (* +hamming-raw-mismatch-weight+
          (observation-block-mismatch-count
           left right 0 +cage2-raw-observation-size+))
       (* +hamming-scan-mismatch-weight+
          (observation-block-mismatch-count
           left right +cage2-raw-observation-size+ scan-end))
       (* +hamming-availability-mismatch-weight+
          (observation-block-mismatch-count
           left right scan-end +cage2-observation-size+)))))

(defun nearest-hamming-observation (observation index)
  "Return the closest demonstrated observation, with first-seen tie-breaking."
  (multiple-value-bind (exact-observation present-p)
      (gethash observation (hamming-observation-index-exact index))
    (if present-p
        exact-observation
        (multiple-value-bind (cached cached-p)
            (bt:with-lock-held ((hamming-observation-index-cache-lock index))
              (gethash observation
                       (hamming-observation-index-cache index)))
          (if cached-p
              cached
              (let ((best nil)
                    (best-distance most-positive-fixnum))
                (loop for prototype across
                        (hamming-observation-index-prototypes index)
                      for distance =
                        (cage2-weighted-hamming-distance observation prototype)
                      when (< distance best-distance)
                        do (setf best prototype
                                 best-distance distance)
                      when (zerop best-distance)
                        do (return))
                (bt:with-lock-held
                    ((hamming-observation-index-cache-lock index))
                  (when (< (hash-table-count
                            (hamming-observation-index-cache index))
                           +hamming-projection-cache-limit+)
                    ;; Runtime observations may be reused by a bridge. Keep an
                    ;; immutable content key in the shared memoization table.
                    (setf (gethash (copy-seq observation)
                                   (hamming-observation-index-cache index))
                          best)))
                best))))))

(defun policy-observation (observation)
  "Return OBSERVATION or its nearest demonstrated CAGE2 prototype.

The switch and reference index are configured once before training or
validation. TPG execution still selects the action; projection only supplies a
known categorical state for observations absent from the reference dataset."
  (if *hamming-space-enabled*
      (progn
        (unless *hamming-observation-index*
          (error "Hamming projection is enabled but its index is not configured."))
        (nearest-hamming-observation observation *hamming-observation-index*))
      observation))
