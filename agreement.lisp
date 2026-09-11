(in-package :cl-tpg)

(defstruct action-agreement
  "Cached namespace shared with an environment action resolver."
  schema
  version
  target-names
  host-offsets
  response-names
  monitor-action
  analyse-base
  remove-base
  restore-base
  decoy-names
  decoy-bases
  decoy-orders
  source-path)

(defvar *action-agreement* nil
  "Action namespace loaded for the active factored policy environment.")

(defun agreement-entry-key (section key)
  (format nil "~A.~A" (string-downcase section) (string-downcase key)))

(defun parse-action-agreement-entries (path)
  "Read the dependency-free INI subset used by action agreement files."
  (let ((entries (make-hash-table :test #'equal))
        (section nil))
    (with-open-file (stream path :direction :input)
      (loop for raw = (read-line stream nil)
            while raw
            for line = (string-trim '(#\Space #\Tab #\Return) raw)
            unless (or (zerop (length line))
                       (member (char line 0) '(#\# #\;)))
              do (cond
                   ((and (char= (char line 0) #\[)
                         (char= (char line (1- (length line))) #\]))
                    (setf section (subseq line 1 (1- (length line)))))
                   (t
                    (unless section
                      (error "Agreement entry appears before a section: ~A" line))
                    (let ((separator (position #\= line)))
                      (unless separator
                        (error "Invalid agreement entry: ~A" line))
                      (let ((key (string-trim '(#\Space #\Tab)
                                              (subseq line 0 separator)))
                            (value (string-trim '(#\Space #\Tab)
                                                (subseq line (1+ separator)))))
                        (setf (gethash (agreement-entry-key section key) entries)
                              value)))))))
    entries))

(defun agreement-value (entries section key)
  (or (gethash (agreement-entry-key section key) entries)
      (error "Missing agreement entry [~A] ~A." section key)))

(defun agreement-integer (entries section key)
  (parse-integer (agreement-value entries section key)))

(defun agreement-comma-list (value)
  (mapcar (lambda (item)
            (string-trim '(#\Space #\Tab) item))
          (uiop:split-string value :separator '(#\,))))

(defun indexed-agreement-values (entries section count parser)
  (let ((result (make-array count)))
    (dotimes (index count result)
      (setf (aref result index)
            (funcall parser
                     (agreement-value entries section
                                      (write-to-string index)))))))

(defun validate-decoy-order (order count target-index)
  (unless (and (= (length order) count)
               (equal (sort (copy-list order) #'<)
                      (loop for index below count collect index)))
    (error "Target ~D decoy order is not a permutation of 0..~D: ~S"
           target-index (1- count) order))
  (coerce order 'simple-vector))

(defun load-action-agreement (path)
  "Load and validate PATH once into an ACTION-AGREEMENT structure."
  (let* ((source (truename path))
         (entries (parse-action-agreement-entries source))
         (target-count 11)
         (response-count 4)
         (decoy-count 8)
         (target-pairs
           (indexed-agreement-values
            entries "targets" target-count
            (lambda (value)
              (let ((parts (agreement-comma-list value)))
                (unless (= (length parts) 2)
                  (error "Invalid target agreement value: ~A" value))
                (list (first parts) (parse-integer (second parts)))))))
         (decoy-pairs
           (indexed-agreement-values
            entries "decoys" decoy-count
            (lambda (value)
              (let ((parts (agreement-comma-list value)))
                (unless (= (length parts) 2)
                  (error "Invalid decoy agreement value: ~A" value))
                (list (first parts) (parse-integer (second parts)))))))
         (orders (make-array target-count :initial-element nil)))
    (loop for target from 1 below target-count
          for values = (mapcar #'parse-integer
                               (agreement-comma-list
                                (agreement-value entries "decoy_order"
                                                 (write-to-string target))))
          do (setf (aref orders target)
                   (validate-decoy-order values decoy-count target)))
    (setf *action-agreement*
          (make-action-agreement
           :schema (agreement-value entries "agreement" "schema")
           :version (agreement-integer entries "agreement" "version")
           :target-names (map 'simple-vector #'first target-pairs)
           :host-offsets (map 'simple-vector #'second target-pairs)
           :response-names
           (indexed-agreement-values entries "responses" response-count #'identity)
           :monitor-action (agreement-integer entries "action_ids" "monitor")
           :analyse-base (agreement-integer entries "action_ids" "analyse_base")
           :remove-base (agreement-integer entries "action_ids" "remove_base")
           :restore-base (agreement-integer entries "action_ids" "restore_base")
           :decoy-names (map 'simple-vector #'first decoy-pairs)
           :decoy-bases (map 'simple-vector #'second decoy-pairs)
           :decoy-orders orders
           :source-path (namestring source)))))

(defun default-cage2-action-agreement-path ()
  (asdf:system-relative-pathname "cl-tpg" "agreements/cage2-v1.ini"))

(defun ensure-cage2-action-agreement ()
  "Return the cached CAGE2 agreement, loading the packaged default once."
  (or *action-agreement*
      (load-action-agreement (default-cage2-action-agreement-path))))
