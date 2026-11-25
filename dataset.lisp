(in-package :cl-tpg)

(defstruct (dataset (:constructor %make-dataset))
  (observations (make-array 0) :type (simple-array (simple-array double-float (*)) (*)))
  (actions (make-array 0) :type simple-vector)
  (rewards (make-array 0 :element-type 'double-float) :type (simple-array double-float (*)))
  (terminations (make-array 0 :element-type 'bit) :type simple-vector)
  (truncations (make-array 0 :element-type 'bit) :type simple-vector)
  (teacher-actions (make-array 0) :type simple-vector)
  (decoy-masks (make-array 0) :type simple-vector)
  (semantic-rankings (make-array 0) :type simple-vector)
  (episode-ids nil)
  (steps nil)
  (episode-ranges nil)
  (size 0 :type fixnum)
  (action-format :atomic :type keyword)
  source-path)

(defun make-dataset-episode-ranges (episode-ids)
  "Return #(START . END) ranges for adjacent rows with the same episode id."
  (when episode-ids
    (let ((count (length episode-ids))
          (ranges nil)
          (start 0))
      (loop while (< start count)
            for episode-id = (aref episode-ids start)
            for end = (loop for index from (1+ start) below count
                            while (equal (aref episode-ids index) episode-id)
                            finally (return index))
            do (push (cons start end) ranges)
               (setf start end))
      (coerce (nreverse ranges) 'vector))))

(defun dataset-episode-metadata-p (dataset)
  "Return true when DATASET preserves episode ids, steps, and episode ranges."
  (and (dataset-episode-ids dataset)
       (dataset-steps dataset)
       (dataset-episode-ranges dataset)
       (= (length (dataset-episode-ids dataset)) (dataset-size dataset))
       (= (length (dataset-steps dataset)) (dataset-size dataset))))

(defun ensure-recurrent-dataset-compatible (dataset description)
  "Validate that DATASET can reproduce episode-local recurrent execution."
  (unless (dataset-episode-metadata-p dataset)
    (error "~A lacks episode-id/step metadata required by recurrent fitness."
           description))
  (let ((seen (make-hash-table :test #'equal))
        (episode-ids (dataset-episode-ids dataset))
        (steps (dataset-steps dataset)))
    (loop for range across (dataset-episode-ranges dataset)
          for start = (car range)
          for end = (cdr range)
          for episode-id = (aref episode-ids start)
          do (when (gethash episode-id seen)
               (error "~A episode ~S occurs in multiple non-adjacent ranges."
                      description episode-id))
             (setf (gethash episode-id seen) t)
             (loop for index from start below end
                   for expected-step from (aref steps start)
                   unless (and (equal (aref episode-ids index) episode-id)
                               (integerp (aref steps index))
                               (= (aref steps index) expected-step))
                     do (error
                         "~A episode ~S has a missing or unordered step near row ~D."
                         description episode-id index))))
  dataset)

(defun recurrent-policy-row-p (dataset index)
  "Return true when INDEX belongs to the policy-owned part of its episode."
  (or (eq *cage2-opening-mode* :policy)
      (>= (aref (dataset-steps dataset) index)
          (length +cage2-fixed-opening-rankings+))))

(defun convert-list-to-dataset (transitions)
  "Converts a raw list of transitions ((obs act rew term trunc)) ..)
   into a dataset struct."
  (declare (optimize (speed 3) (safety 1))
	   (type list transitions))
  (let* ((count (length transitions))
	 (obs-arr (make-array count))
	 (act-arr (make-array count))
	 (rew-arr (make-array count :element-type 'double-float))
	 (term-arr (make-array count))
	 (trunc-arr (make-array count)))
    (loop for transition in transitions
	  for i fixnum from 0
	  do (destructuring-bind (obs act rew term trunc) transition
	       (declare (type list obs))
	       (setf (aref obs-arr i)
		     (make-array (length obs)
				 :element-type 'double-float
				 :initial-contents (mapcar
						    (lambda (x) (coerce x 'double-float))
						    obs)))
	       (setf (aref act-arr i) act)
	       (setf (aref rew-arr i) (coerce rew 'double-float))
	       (setf (aref term-arr i) term)
	       (setf (aref trunc-arr i) trunc)))
    (%make-dataset :observations obs-arr
		   :actions act-arr
		   :rewards rew-arr
		   :terminations term-arr
		   :truncations trunc-arr
		   :teacher-actions (make-array count :initial-element nil)
		   :decoy-masks (make-array count :initial-element 0)
		   :semantic-rankings (make-array count :initial-element nil)
		   :episode-ids nil
		   :steps nil
		   :episode-ranges nil
		   :size count
                   :action-format :atomic)))

(defun semantic-transition-form-p (form)
  "Return true when FORM is one line from a cage2-semantic-v1 dataset."
  (and (consp form)
       (eq (first form) :transition)))

(defun valid-semantic-action-label-p (label)
  "Return true for a canonical (target response option) dataset label."
  (and (listp label)
       (= (length label) 3)
       (destructuring-bind (target response option) label
         (and (integerp target)
              (<= 0 target)
              (< target +num-semantic-targets+)
              (integerp response)
              (<= 0 response)
              (< response 4)
              (integerp option)
              (<= 0 option)
              (< option 8)))))

(defun valid-semantic-pair-p (pair)
  "Return true for one canonical (target response) ranked label."
  (and (listp pair)
       (= (length pair) 2)
       (destructuring-bind (target response) pair
         (and (integerp target)
              (<= 0 target)
              (< target +num-semantic-targets+)
              (integerp response)
              (<= 0 response)
              (< response +num-semantic-responses+)))))

(defun valid-semantic-ranking-p (ranking)
  "Return true for a non-empty duplicate-free target/response ranking."
  (and (listp ranking)
       ranking
       (every #'valid-semantic-pair-p ranking)
       (= (length ranking)
          (length (remove-duplicates ranking :test #'equal)))))

(defun semantic-dataset-p (dataset)
  "Return true for either supported semantic CAGE2 dataset generation."
  (member (dataset-action-format dataset)
          '(:semantic :semantic-ranked)
          :test #'eq))

(defun append-decoy-availability (observation decoy-mask)
  "Append exact host-major binary availability to a 62-value CAGE2 state.

DECOY-MASK uses the collector convention: bit (host*8+option) is one after
that option has been used. Policy values invert the bits so 1.0 means available
and 0.0 means used, matching the online Python bridge."
  (unless (= (length observation) +cage2-scan-observation-size+)
    (error "Expected ~D scan-augmented values before decoy availability, got ~D."
           +cage2-scan-observation-size+
           (length observation)))
  (unless (and (integerp decoy-mask) (not (minusp decoy-mask)))
    (error "Invalid semantic dataset decoy mask: ~S" decoy-mask))
  (let ((result (make-array +cage2-observation-size+
                            :element-type 'double-float)))
    (loop for value in observation
          for index fixnum from 0
          do (setf (aref result index) (coerce value 'double-float)))
    (dotimes (bit +cage2-decoy-availability-size+ result)
      (setf (aref result (+ +cage2-scan-observation-size+ bit))
            (if (logbitp bit decoy-mask) 0.0d0 1.0d0)))))

(defun make-cage2-scan-observation (observation)
  "Copy a stored 62-value CAGE2 observation into a specialized policy vector."
  (unless (and (listp observation)
               (= (length observation) +cage2-scan-observation-size+))
    (error "Expected ~D stored CAGE2 observations, got ~A."
           +cage2-scan-observation-size+
           (if (listp observation) (length observation) (type-of observation))))
  (make-array +cage2-scan-observation-size+
              :element-type 'double-float
              :initial-contents
              (mapcar (lambda (value) (coerce value 'double-float))
                      observation)))

(defun make-cage2-policy-observation (observation decoy-mask)
  "Build the configured 62- or 142-value policy input from one dataset row.

The source format remains unchanged: it stores the first 62 values and the
Decoy mask separately. The 80 availability values are appended only when the
active experiment exposes all 142 bridge values to programs."
  (cond
    ((= *num-observations* +cage2-scan-observation-size+)
     (make-cage2-scan-observation observation))
    ((= *num-observations* +cage2-observation-size+)
     (append-decoy-availability observation decoy-mask))
    (t
     (error "CAGE2 policy observations must be ~D or ~D, got ~S."
            +cage2-scan-observation-size+
            +cage2-observation-size+
            *num-observations*))))

(defun convert-semantic-stream-to-dataset (first-form stream source-path)
  "Read cage2-semantic-v1/v2 forms from STREAM into the in-memory dataset shape.

The collector stores full transitions for future work. The current imitation
fitness retains observation, semantic action, reward, and termination fields;
NEXT-OBSERVATION and provenance remain available in the source file. Rows whose
teacher action cannot be represented are skipped rather than silently relabelled."
  (unless (and (integerp *num-actions*)
               (= *num-actions* +num-semantic-targets+))
    (error "Semantic CAGE2 datasets require *NUM-ACTIONS*=~D, got ~S."
           +num-semantic-targets+
           *num-actions*))
  (unless (valid-cage2-policy-observation-size-p *num-observations*)
    (error
     "Factored CAGE2 datasets require Number of Observations=~D or ~D, got ~S."
     +cage2-scan-observation-size+
     +cage2-observation-size+
     *num-observations*))
  (let ((observation-list nil)
        (action-list nil)
        (reward-list nil)
        (termination-list nil)
        (truncation-list nil)
        (teacher-action-list nil)
        (decoy-mask-list nil)
        (semantic-ranking-list nil)
        (episode-id-list nil)
        (step-list nil)
        (saw-episode-metadata nil)
        (saw-missing-episode-metadata nil)
        (saw-ranking nil)
        (saw-unranked nil)
        (skipped 0))
    (labels ((consume (form)
               (unless (semantic-transition-form-p form)
                 (error "Invalid semantic dataset form: ~S" form))
               (let ((observation (getf (rest form) :observation))
                     (action (getf (rest form) :semantic-action))
                     (representable (getf (rest form) :representable))
                     (reward (getf (rest form) :reward))
                     (teacher-action (getf (rest form) :teacher-action))
                     (decoy-mask (getf (rest form) :decoy-mask-before 0))
                     (episode-id
                       (getf (rest form) :episode-id :not-present))
                     (step (getf (rest form) :step :not-present))
                     (ranking
                       (getf (rest form) :semantic-ranking :not-present))
                     (terminated (getf (rest form) :terminated))
                     (truncated (getf (rest form) :truncated)))
                 (if (and representable action)
                     (progn
                       (unless (and (listp observation)
                                    (= (length observation)
                                       +cage2-scan-observation-size+))
                         (error
                          "Expected ~D source observations, but the semantic dataset row has ~A."
                          +cage2-scan-observation-size+
                          (if (listp observation)
                              (length observation)
                              (type-of observation))))
                       (unless (valid-semantic-action-label-p action)
                         (error "Invalid semantic action label: ~S" action))
                       (if (eq ranking :not-present)
                           (setf saw-unranked t)
                           (progn
                             (unless (valid-semantic-ranking-p ranking)
                               (error "Invalid semantic action ranking: ~S"
                                      ranking))
                             (setf saw-ranking t)))
                       (when (and saw-ranking saw-unranked)
                         (error
                          "Semantic dataset mixes ranked-v2 and unranked-v1 rows."))
                       (unless (numberp reward)
                         (error "Invalid semantic dataset reward: ~S" reward))
                       (unless (and (integerp teacher-action)
                                    (<= 0 teacher-action 144))
                         (error "Invalid semantic dataset teacher action: ~S"
                                teacher-action))
                       (cond
                         ((and (not (eq episode-id :not-present))
                               (not (eq step :not-present)))
                          (unless (and (integerp step) (not (minusp step)))
                            (error "Invalid semantic dataset step: ~S" step))
                          (setf saw-episode-metadata t))
                         ((and (eq episode-id :not-present)
                               (eq step :not-present))
                          (setf saw-missing-episode-metadata t))
                         (t
                          (error
                           "Semantic row must provide both :EPISODE-ID and :STEP.")))
                       (when (and saw-episode-metadata
                                  saw-missing-episode-metadata)
                         (error
                          "Semantic dataset mixes rows with and without episode metadata."))
                       (push (make-cage2-policy-observation observation decoy-mask)
                             observation-list)
                       (push (copy-list action) action-list)
                       (push teacher-action teacher-action-list)
                       (push decoy-mask decoy-mask-list)
                       (push (unless (eq ranking :not-present)
                               (mapcar #'copy-list ranking))
                             semantic-ranking-list)
                       (push (unless (eq episode-id :not-present) episode-id)
                             episode-id-list)
                       (push (unless (eq step :not-present) step)
                             step-list)
                       (push (coerce reward 'double-float) reward-list)
                       (push (if terminated 1 0) termination-list)
                       (push (if truncated 1 0) truncation-list))
                     (incf skipped)))))
      (consume first-form)
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
            do (consume form)))

    (let* ((observations (nreverse observation-list))
           (actions (nreverse action-list))
           (rewards (nreverse reward-list))
           (terminations (nreverse termination-list))
           (truncations (nreverse truncation-list))
           (teacher-actions (nreverse teacher-action-list))
           (decoy-masks (nreverse decoy-mask-list))
           (semantic-rankings (nreverse semantic-ranking-list))
           (episode-ids (and saw-episode-metadata
                             (coerce (nreverse episode-id-list) 'vector)))
           (steps (and saw-episode-metadata
                       (coerce (nreverse step-list) 'vector)))
           (count (length observations))
           (obs-arr (make-array count :initial-contents observations))
           (act-arr (make-array count :initial-contents actions))
           (rew-arr (make-array count
                                :element-type 'double-float
                                :initial-contents rewards))
           (term-arr (make-array count :initial-contents terminations))
           (trunc-arr (make-array count :initial-contents truncations)))
      (format t "Loaded ~D semantic transitions" count)
      (when (> skipped 0)
        (format t "; skipped ~D unsupported rows" skipped))
      (format t ".~%")
      (%make-dataset :observations obs-arr
                     :actions act-arr
                     :rewards rew-arr
                     :terminations term-arr
                     :truncations trunc-arr
                     :teacher-actions
                       (make-array count :initial-contents teacher-actions)
                     :decoy-masks
                       (make-array count :initial-contents decoy-masks)
                     :semantic-rankings
                       (make-array count :initial-contents semantic-rankings)
                     :episode-ids episode-ids
                     :steps steps
                     :episode-ranges
                       (make-dataset-episode-ranges episode-ids)
                     :size count
                     :action-format (if saw-ranking
                                        :semantic-ranked
                                        :semantic)
                     :source-path source-path))))

(defun observations (dataset)
  "Return the observations of DATASET."
  (dataset-observations dataset))

(defun actions (dataset)
  "Return the actions of DATASET."
  (dataset-actions dataset))

(defun rewards (dataset)
  "Return the rewards of DATASET."
  (dataset-rewards dataset))

(defun terminations (dataset)
  "Return the terminations of DATASET."
  (dataset-terminations dataset))

(defun truncations (dataset)
  "Return the truncations of DATASET."
  (dataset-truncations dataset))
  
(defun batch (dataset start end)
  "Returns a NEW dataset containing a subset of tuples from
   START to END of the original DATASET."
  (%make-dataset
   :observations (subseq (observations dataset) start end)
   :actions (subseq (actions dataset) start end)
   :rewards (subseq (rewards dataset) start end)
   :terminations (subseq (terminations dataset) start end)
   :truncations (subseq (truncations dataset) start end)
   :teacher-actions (subseq (dataset-teacher-actions dataset) start end)
   :decoy-masks (subseq (dataset-decoy-masks dataset) start end)
   :semantic-rankings (subseq (dataset-semantic-rankings dataset) start end)
   :episode-ids
     (and (dataset-episode-ids dataset)
          (subseq (dataset-episode-ids dataset) start end))
   :steps
     (and (dataset-steps dataset)
          (subseq (dataset-steps dataset) start end))
   :episode-ranges
     (and (dataset-episode-ids dataset)
          (make-dataset-episode-ranges
           (subseq (dataset-episode-ids dataset) start end)))
   :size (- end start)
   :action-format (dataset-action-format dataset)
   :source-path (dataset-source-path dataset)))

(defun sample (dataset)
  (let ((len (dataset-size dataset)))
    (if (>= *batch-size* len)
	dataset
	(let ((start (random (- len *batch-size*))))
	  (batch dataset start (+ start *batch-size*))))))

(defun resolve-dataset-path (name &key path)
  "Resolve NAME or PATH using the historical ~/.datasets/ convention."
  (let* ((name-string (namestring name))
         (pathname (pathname name-string)))
    (cond
      (path
       (pathname path))
      ((or (uiop:absolute-pathname-p pathname)
           (and (> (length name-string) 0)
                (char= (char name-string 0) #\~))
           (pathname-directory pathname))
       pathname)
      (t
       (merge-pathnames
        pathname
        (uiop:ensure-directory-pathname
         (merge-pathnames ".datasets/"
                          (user-homedir-pathname))))))))

(defun load-dataset (name &key path)
  "Load a legacy atomic dataset or a cage2-semantic-v1 transition stream.

If PATH is supplied, use PATH directly.

If NAME is an absolute path, a relative path containing directory
components, or a home-relative path beginning with ~, use NAME directly.

Otherwise, treat NAME as a dataset filename under ~/.datasets/."
  (let* ((file-name (resolve-dataset-path name :path path))
         (source-path (namestring (truename file-name))))
    (with-open-file (in file-name :direction :input)
      (format t "Loading and converting dataset: ~A...~%" source-path)
      (let ((first-form (read in nil :eof)))
        (when (eq first-form :eof)
          (error "Dataset is empty: ~A" source-path))
        (if (semantic-transition-form-p first-form)
            (convert-semantic-stream-to-dataset first-form in source-path)
            (let ((dataset (convert-list-to-dataset first-form)))
              (setf (dataset-source-path dataset) source-path)
              dataset))))))

(defmacro defdataset (name &key path)
  "Define a global variable containing a dataset loaded from 'datasets/<name>'."
  (let* ((dataset-name (string-trim "*" (symbol-name name)))
	 (file-name (if path
			path
			(concatenate 'string "~/.datasets/" dataset-name))))
    `(defparameter ,name
       (load-dataset ,dataset-name :path ,file-name))))
         
