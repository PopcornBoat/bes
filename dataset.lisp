(in-package :cl-tpg)

(defstruct (dataset (:constructor %make-dataset))
  (observations (make-array 0) :type (simple-array (simple-array double-float (*)) (*)))
  (actions (make-array 0) :type simple-vector)
  (rewards (make-array 0 :element-type 'double-float) :type (simple-array double-float (*)))
  (terminations (make-array 0 :element-type 'bit) :type simple-vector)
  (truncations (make-array 0 :element-type 'bit) :type simple-vector)
  (teacher-actions (make-array 0) :type simple-vector)
  (decoy-masks (make-array 0) :type simple-vector)
  (size 0 :type fixnum)
  (action-format :atomic :type keyword)
  source-path)

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

(defun convert-semantic-stream-to-dataset (first-form stream source-path)
  "Read cage2-semantic-v1 forms from STREAM into the in-memory dataset shape.

The collector stores full transitions for future work. The current imitation
fitness retains observation, semantic action, reward, and termination fields;
NEXT-OBSERVATION and provenance remain available in the source file. Rows whose
teacher action cannot be represented are skipped rather than silently relabelled."
  (unless (and (integerp *num-actions*)
               (= *num-actions* +num-semantic-targets+))
    (error "Semantic CAGE2 datasets require *NUM-ACTIONS*=~D, got ~S."
           +num-semantic-targets+
           *num-actions*))
  (unless (= *num-observations* +cage2-observation-size+)
    (error
     "Factored CAGE2 datasets require Number of Observations=~D, got ~S."
     +cage2-observation-size+
     *num-observations*))
  (let ((observation-list nil)
        (action-list nil)
        (reward-list nil)
        (termination-list nil)
        (truncation-list nil)
        (teacher-action-list nil)
        (decoy-mask-list nil)
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
                       (unless (numberp reward)
                         (error "Invalid semantic dataset reward: ~S" reward))
                       (unless (and (integerp teacher-action)
                                    (<= 0 teacher-action 144))
                         (error "Invalid semantic dataset teacher action: ~S"
                                teacher-action))
                       (push (append-decoy-availability observation decoy-mask)
                             observation-list)
                       (push (copy-list action) action-list)
                       (push teacher-action teacher-action-list)
                       (push decoy-mask decoy-mask-list)
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
                     :size count
                     :action-format :semantic
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
         
