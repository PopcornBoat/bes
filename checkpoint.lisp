(in-package :cl-tpg)

(defun checkpoint-path (directory filename)
  "Return pathname for FILENAME under DIRECTORY."
  (merge-pathnames filename
                   (uiop:ensure-directory-pathname directory)))

(defun checkpoint-timestamp ()
  "Return timestamp string for checkpoint naming."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time))
    (format nil "~4,'0D~2,'0D~2,'0D_~2,'0D~2,'0D~2,'0D"
            year month day hour min sec)))

(defun checkpoint-directory-name (&key (mode "manual"))
  "Return a timestamped checkpoint directory name."
  (format nil "~A_g~A_~A_checkpoint/"
          (checkpoint-timestamp)
          *generation*
          mode))

(defun save-lisp-image-checkpoint (&optional (path "cl-tpg.core"))
  "Save the entire SBCL image. This exits the current Lisp process."
  #+sbcl
  (sb-ext:save-lisp-and-die path :executable t)
  #-sbcl
  (error "Only SBCL supports save-lisp-and-die."))

(defun serialize-population-checkpoint ()
  "Serialize current root population and all training metadata."
  (let ((seen (make-hash-table :test #'equal)))
    `(:generation ,*generation*
      :population-size ,*population-size*
      :num-observations ,*num-observations*
      :num-actions ,*num-actions*

      :init-num-learners ,*init-num-learners*
      :max-num-learners ,*max-num-learners*
      :p-add ,*p-add*
      :p-del ,*p-del*
      :p-mut ,*p-mut*
      :p-act ,*p-act*
      :p-swap ,*p-swap*
      :gap ,*gap*

      :init-program-size ,*init-program-size*
      :max-program-size ,*max-program-size*
      :p-add-instr ,*p-add-instr*
      :p-del-instr ,*p-del-instr*
      :p-swap-instrs ,*p-swap-instrs*
      :p-mut-constant ,*p-mut-constant*
      :p-mut-constant-sign ,*p-mut-constant-sign*

      :migration-interval ,*migration-interval*
      :batch-size ,*batch-size*
      :checkpoint-directory ,*checkpoint-directory*
      :checkpoint-interval ,*checkpoint-interval*
      :best-fitness ,*best-fitness*

      :root-teams ,(mapcar (lambda (team)
                             (serialize-team team seen))
                           (root-teams)))))

(defun save-population-checkpoint (&optional (directory "population-checkpoint/"))
  "Save root population checkpoint into DIRECTORY/population.lisp."
  (unless (root-teams)
    (error "Cannot save population checkpoint: no root teams."))

  (let* ((dir (uiop:ensure-directory-pathname directory))
         (path (checkpoint-path dir "population.lisp"))
         (data (serialize-population-checkpoint)))
    (ensure-directories-exist dir)

    (with-open-file (out path
                         :direction :output
                         :if-exists :supersede
                         :if-does-not-exist :create)
      (with-standard-io-syntax
        (let ((*print-circle* t)
              (*print-readably* t)
              (*print-pretty* nil))
          (write data :stream out))))

    (namestring path)))

(defun save-best-team (&optional (directory "best-team/"))
  "Save current best team into DIRECTORY/best-team.lisp and DIRECTORY/metadata.lisp."
  (unless *best-team*
    (error "Cannot save best team: *BEST-TEAM* is NIL. Run search first."))

  (let* ((dir (uiop:ensure-directory-pathname directory))
         (team-path (checkpoint-path dir "best-team.lisp"))
         (metadata-path (checkpoint-path dir "metadata.lisp")))
    (ensure-directories-exist dir)

    (with-open-file (out team-path
                         :direction :output
                         :if-exists :supersede
                         :if-does-not-exist :create)
      (with-standard-io-syntax
        (let ((*print-circle* t)
              (*print-readably* t)
              (*print-pretty* nil))
          (write (serialize-team *best-team*) :stream out))))

    (with-open-file (out metadata-path
                         :direction :output
                         :if-exists :supersede
                         :if-does-not-exist :create)
      (with-standard-io-syntax
        (let ((*print-circle* t)
              (*print-readably* t)
              (*print-pretty* nil))
          (write
           `(:generation ,*generation*
             :best-fitness ,*best-fitness*
             :population-size ,*population-size*
             :num-observations ,*num-observations*
             :num-actions ,*num-actions*
             :gap ,*gap*
             :batch-size ,*batch-size*)
           :stream out))))

    (namestring dir)))

(defun save-checkpoint (&optional (directory *checkpoint-directory*) &key (mode "manual"))
  "Save both population and best team into a single timestamped checkpoint directory."
  (let* ((root (uiop:ensure-directory-pathname directory))
         (checkpoint-dir (checkpoint-path root (checkpoint-directory-name :mode mode)))
         (population-dir checkpoint-dir)
         (best-team-dir (checkpoint-path checkpoint-dir "best-team/"))
         (metadata-path (checkpoint-path checkpoint-dir "metadata.lisp")))
    (ensure-directories-exist checkpoint-dir)

    (let ((population-path (save-population-checkpoint population-dir))
          (best-team-path (save-best-team best-team-dir)))
      (with-open-file (out metadata-path
                           :direction :output
                           :if-exists :supersede
                           :if-does-not-exist :create)
        (with-standard-io-syntax
          (let ((*print-circle* t)
                (*print-readably* t)
                (*print-pretty* t))
            (write
             `(:generation ,*generation*
               :best-fitness ,*best-fitness*
               :population-file ,population-path
               :best-team-directory ,best-team-path
               :mode ,mode
               :timestamp ,(checkpoint-timestamp))
             :stream out))))

      (namestring checkpoint-dir))))

(defun maybe-save-checkpoint ()
  "Automatically save full checkpoint every *CHECKPOINT-INTERVAL* generations."
  (when (and *teams*
             *best-team*
             *checkpoint-directory*
             (numberp *checkpoint-interval*)
             (> *checkpoint-interval* 0)
             (= (mod *generation* *checkpoint-interval*) 0))
    (let ((path (save-checkpoint *checkpoint-directory* :mode "auto")))
      (emit-message
       (format nil "Auto checkpoint saved: ~A" path)))))

(defun load-best-team (path)
  "Load serialized best team from PATH."
  (with-open-file (in path :direction :input)
    (deserialize-team (read in) (make-hash-table :test #'equal))))

(defun load-solution (path)
  "Compatibility alias. Load serialized team solution."
  (load-best-team path))

(defun run-solution-on-env (solution-path environment-name &key (seed (random 9999999)))
  "Run one episode using saved best team / solution."
  (let ((team (load-best-team solution-path)))
    (cl-gym:rollout team environment-name seed)))

(defun evaluate-solution-mean (solution-path environment-name &key (episodes 100))
  "Evaluate saved best team / solution over EPISODES."
  (let ((team (load-best-team solution-path)))
    (/ (loop repeat episodes
             sum (cl-gym:rollout team environment-name (random 9999999)))
       episodes)))

(defun load-population-checkpoint (path)
  "Load a saved root population checkpoint."
  (with-open-file (in path :direction :input)
    (let* ((data (read in))
           (registry (make-hash-table :test #'equal))
           (serialized-roots (getf data :root-teams)))

      (unless serialized-roots
        (error "Checkpoint has no :ROOT-TEAMS field."))

      (setf *generation* (getf data :generation)
            *population-size* (getf data :population-size)
            *num-observations* (getf data :num-observations)
            *num-actions* (getf data :num-actions)

            *init-num-learners* (getf data :init-num-learners)
            *max-num-learners* (getf data :max-num-learners)
            *p-add* (getf data :p-add)
            *p-del* (getf data :p-del)
            *p-mut* (getf data :p-mut)
            *p-act* (getf data :p-act)
            *p-swap* (getf data :p-swap)
            *gap* (getf data :gap)

            *init-program-size* (getf data :init-program-size)
            *max-program-size* (getf data :max-program-size)
            *p-add-instr* (getf data :p-add-instr)
            *p-del-instr* (getf data :p-del-instr)
            *p-swap-instrs* (getf data :p-swap-instrs)
            *p-mut-constant* (getf data :p-mut-constant)
            *p-mut-constant-sign* (getf data :p-mut-constant-sign)

            *migration-interval* (getf data :migration-interval)
            *batch-size* (getf data :batch-size)
            *checkpoint-directory* (getf data :checkpoint-directory)
            *checkpoint-interval* (or (getf data :checkpoint-interval) 50)
            *best-fitness* (getf data :best-fitness))

      (setf *teams*
            (mapcar (lambda (team-data)
                      (deserialize-team team-data registry t))
                    serialized-roots))

      *teams*)))

(defun load-checkpoint (directory)
  "Load population and best team from a full checkpoint directory."
  (let* ((dir (uiop:ensure-directory-pathname directory))
         (population-path (checkpoint-path dir "population.lisp"))
         (best-team-path (checkpoint-path dir "best-team/best-team.lisp"))
         (best-metadata-path (checkpoint-path dir "best-team/metadata.lisp")))

    (load-population-checkpoint population-path)

    (when (probe-file best-team-path)
      (setf *best-team* (load-best-team best-team-path)))

    (when (probe-file best-metadata-path)
      (with-open-file (in best-metadata-path :direction :input)
        (let ((metadata (read in)))
          (setf *best-fitness* (getf metadata :best-fitness)))))

    (values (length *teams*) *generation* *best-fitness*)))




 ;;debugging
 (defun readable-object-p (obj)
  "Return T if OBJ can be printed readably."
  (handler-case
      (progn
        (with-output-to-string (s)
          (with-standard-io-syntax
            (let ((*print-circle* t)
                  (*print-readably* t)
                  (*print-pretty* nil))
              (write obj :stream s))))
        t)
    (error () nil)))

(defun debug-non-readable-object (obj path)
  "Print information about a non-readable object."
  (format t "~&[CHECKPOINT DEBUG] Non-readable object found.~%")
  (format t "[CHECKPOINT DEBUG] Path: ~S~%" path)
  (format t "[CHECKPOINT DEBUG] Type: ~S~%" (type-of obj))
  (format t "[CHECKPOINT DEBUG] Object: ~A~%" obj)
  #+sbcl
  (sb-debug:print-backtrace :stream *standard-output*))

(defun find-non-readable-object (obj &optional (path '(:root)) (seen (make-hash-table :test #'eq)))
  "Walk OBJ and return two values: bad-object and path.
Only intended for checkpoint debugging."
  (cond
    ;; Avoid infinite walk on circular structures.
    ((and (consp obj) (gethash obj seen))
     (values nil nil))

    ((consp obj)
     (setf (gethash obj seen) t)
     (loop for current on obj
           for i from 0
           do
             (multiple-value-bind (bad bad-path)
                 (find-non-readable-object (car current)
                                           (append path (list :car i))
                                           seen)
               (when bad
                 (return-from find-non-readable-object
                   (values bad bad-path))))
           finally
             (when (cdr current)
               (multiple-value-bind (bad bad-path)
                   (find-non-readable-object (cdr current)
                                             (append path (list :cdr-tail))
                                             seen)
                 (when bad
                   (return-from find-non-readable-object
                     (values bad bad-path))))))
     (values nil nil))

    ;; Vectors / arrays.
    ((arrayp obj)
     (if (readable-object-p obj)
         (values nil nil)
         (values obj path)))

    ;; Hash tables are not expected in serialized checkpoint.
    ((hash-table-p obj)
     (values obj path))

    ;; Atom.
    ((readable-object-p obj)
     (values nil nil))

    (t
     (values obj path))))

(defun assert-checkpoint-readable (data)
  "Signal a useful error if DATA contains a non-readable object."
  (multiple-value-bind (bad path)
      (find-non-readable-object data)
    (when bad
      (debug-non-readable-object bad path)
      (error "Checkpoint contains non-readable object at ~S: ~A"
             path bad)))
  t)

(defun find-object-path-eq (target obj &optional (path '(:root)) (seen (make-hash-table :test #'eq)))
  "Find TARGET in OBJ by EQ and return path, or NIL."
  (cond
    ((eq target obj)
     path)

    ((and (consp obj) (gethash obj seen))
     nil)

    ((consp obj)
     (setf (gethash obj seen) t)
     (or (find-object-path-eq target (car obj) (append path '(:car)) seen)
         (find-object-path-eq target (cdr obj) (append path '(:cdr)) seen)))

    ((arrayp obj)
     (loop for i below (array-total-size obj)
           for found = (find-object-path-eq
                        target
                        (row-major-aref obj i)
                        (append path (list :array i))
                        seen)
           when found
             return found))

    (t nil)))

(defun find-object-path-eq (target obj &optional (path '(:root)) (seen (make-hash-table :test #'eq)))
  "Find TARGET in OBJ by EQ and return path, or NIL."
  (cond
    ((eq target obj)
     path)

    ((and (consp obj) (gethash obj seen))
     nil)

    ((consp obj)
     (setf (gethash obj seen) t)
     (or (find-object-path-eq target (car obj) (append path '(:car)) seen)
         (find-object-path-eq target (cdr obj) (append path '(:cdr)) seen)))

    ((arrayp obj)
     (loop for i below (array-total-size obj)
           for found = (find-object-path-eq
                        target
                        (row-major-aref obj i)
                        (append path (list :array i))
                        seen)
           when found
             return found))

    (t nil)))