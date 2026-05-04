(in-package :bes)

(defstruct (dataset (:constructor %make-dataset))
  (observations (make-array 0) :type (simple-array (simple-array double-float (*)) (*)))
  (actions (make-array 0) :type simple-vector)
  (rewards (make-array 0 :element-type 'double-float) :type (simple-array double-float (*)))
  (terminations (make-array 0 :element-type 'bit) :type simple-vector)
  (truncations (make-array 0 :element-type 'bit) :type simple-vector)
  (size 0 :type fixnum))

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
		   :size count)))

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
   :size (- end start)))

(defun sample (dataset)
  (let ((len (dataset-size dataset)))
    (if (>= *batch-size* len)
	dataset
	(let ((start (random (- len *batch-size*))))
	  (batch dataset start (+ start *batch-size*))))))

(defun load-dataset (name &key path)
  "Load a dataset from a path on the filesystem.
   If a path is not specified, assume '~/.datasets/'"
  (let* ((dataset-name name)
	 (file-name (if path
		       path
		       (concatenate 'string "~/.datasets/" dataset-name))))
    (with-open-file (in file-name :direction :input)
      (format t "Loading and converting dataset: ~A...~%" file-name)
      (convert-list-to-dataset (read in)))))

(defmacro defdataset (name &key path)
  "Define a global variable containing a dataset loaded from 'datasets/<name>'."
  (let* ((dataset-name (string-trim "*" (symbol-name name)))
	 (file-name (if path
			path
			(concatenate 'string "~/.datasets/" dataset-name))))
    `(defparameter ,name
       (load-dataset ,dataset-name :path ,file-name))))
         
