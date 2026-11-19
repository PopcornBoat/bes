(in-package :cl-tpg)

(defun torch-json-write (value stream)
  (typecase value
    (string
     (write-char #\" stream)
     (loop for char across value do
       (case char
         (#\" (write-string "\\\"" stream))
         (#\\ (write-string "\\\\" stream))
         (#\Newline (write-string "\\n" stream))
         (t (write-char char stream))))
     (write-char #\" stream))
    (number
     (write-string (substitute #\e #\D (substitute #\e #\d (write-to-string value))) stream))
    (sequence
     (write-char #\[ stream)
     (loop for item across (coerce value 'vector) for i from 0 do
       (unless (zerop i) (write-char #\, stream))
       (torch-json-write item stream))
     (write-char #\] stream))
    (t (error "Unsupported export value ~S." value))))

(defun torch-policy-export (checkpoint output)
  (continuous-call "b_line"
   (lambda ()
     (let* ((root (continuous-load checkpoint))
            (nodes (numeric-policy-nodes root))
            (indices (make-hash-table :test #'eq)))
       (loop for node in nodes for i from 0 do (setf (gethash node indices) i))
       (numeric-topology-depth root)
       (with-open-file (out output :direction :output :if-exists :error)
         (torch-json-write
          (vector +num-registers+ (active-read-only-register-values)
           (map 'vector
            (lambda (node)
              (map 'vector
               (lambda (learner)
                 (let ((action (learner-action learner)))
                   (vector
                    (map 'vector
                     (lambda (ins)
                       (vector (instruction-dest ins) (symbol-name (instruction-op ins))
                               (symbol-name (instruction-src1-type ins)) (instruction-src1-val ins)
                               (symbol-name (instruction-src2-type ins)) (instruction-src2-val ins)
                               (instruction-arity ins)))
                     (program-instructions (learner-program learner)))
                    (symbol-name (action-type action))
                    (if (eq (action-type action) :reference)
                        (gethash (action-action action) indices)
                        (vector (target-response-36-action-target (action-action action))
                                (target-response-36-action-response (action-action action)))))))
               (team-learners node)))
            nodes))
          out))))))

(defun torch-bid-reference (checkpoint contexts output)
  (continuous-call "b_line"
   (lambda ()
     (let* ((root (continuous-load checkpoint))
            (nodes (numeric-policy-nodes root)))
       (with-open-file (f output :direction :output :if-exists :error)
         (continuous-row f "obs" "node" "slot" "bid")
         (dolist (text (continuous-read contexts))
           (let ((obs (continuous-obs text)))
             (loop for node in nodes for ni from 0 do
               (loop for learner in (team-learners node) for li from 0 do
                 (continuous-row f text ni li (bid learner obs)))))))))))

