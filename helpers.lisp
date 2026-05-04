(in-package :bes)

(defun make-counter ()
  (let ((count 0))
    (lambda ()
      (incf count))))

(defun random-choice (seq)
  "Returns a random element from the sequence SEQ."
  (elt seq (random (length seq))))

(defun random-range (low high)
  "Returns a random number from [LOW, HIGH].
   Preserves the datatype."
  (if (or (floatp high) (floatp low))
      (+ low (* (random 1.0) (- high low)))
      (+ low (random (1+ (- high low))))))

(defun coin-flip (p)
  "Returns T with likelihood p."
  (if (< (random-range 0.0 1.0) p)
      t
      nil))

(defun get-cpu-usage (&optional (interval 1))
  "Returns a single float representing the total CPU utilization (0.0 to 100.0)."
  (flet ((get-raw-cpu ()
	   (with-open-file (s "/proc/stat")
	     (let* ((line (read-line s))
		    (parts (remove-if (lambda (x) (string= x ""))
				      (uiop:split-string line)))
		    (stats (mapcar #'parse-integer (rest parts))))
	       (values (reduce #'+ stats) (fourth stats))))))
    (multiple-value-bind (total1 idle1) (get-raw-cpu)
      (sleep interval)
      (multiple-value-bind (total2 idle2) (get-raw-cpu)
	(let ((total-delta (- total2 total1))
	      (idle-delta (- idle2 idle1)))
	  (if (zerop total-delta)
	      0.0
	      (* 100.0 (- 1 (/ idle-delta total-delta)))))))))
  
(defun get-memory-usage ()
  "Returns the percentage of RAM currently in use (0.0 to 100.0)."
  (with-open-file (s "/proc/meminfo")
    (let (total free buffers cached)
      (loop for line = (read-line s nil)
	    while (and line (or (not total) (not free) (not buffers) (not cached)))
	    do (let* ((parts (remove-if (lambda (x) (string= x ""))
					(uiop:split-string line)))
		      (key (car parts))
		      (val (parse-integer (second parts))))
		 (cond
		   ((string= key "MemTotal:") (setf total val))
		   ((string= key "MemFree:") (setf free val))
		   ((string= key "Buffers:") (setf buffers val))
		   ((string= key "Cached:") (setf cached val)))))
      (if (and total free buffers cached)
	  (let ((used (- total (+ free buffers cached))))
	    (* 100.0 (/ used (float total))))
	  0.0))))
