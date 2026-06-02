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

(defun save-lisp-image-checkpoint (&optional (path "cl-tpg.core"))
  "Save the entire SBCL image. This exits the current Lisp process."
  #+sbcl
  (sb-ext:save-lisp-and-die path :executable t)
  #-sbcl
  (error "Only SBCL supports save-lisp-and-die."))

(defun serialize-population-checkpoint ()
  "Serialize current population and training metadata."
  `(:generation ,*generation*
    :population-size ,*population-size*
    :num-observations ,*num-observations*
    :num-actions ,*num-actions*
    :gap ,*gap*
    :batch-size ,*batch-size*
    :teams ,(mapcar #'serialize-team *teams*)))

(defun save-population-checkpoint (&optional (directory "population-checkpoint/"))
  "Save full population checkpoint without exiting."
  (unless *teams*
    (error "Cannot save population checkpoint: *TEAMS* is NIL."))

  (let* ((dir (uiop:ensure-directory-pathname directory))
         (path (checkpoint-path dir "population.lisp")))
    (ensure-directories-exist dir)
    (with-open-file (out path
                         :direction :output
                         :if-exists :supersede
                         :if-does-not-exist :create)
      (with-standard-io-syntax
        (let ((*print-circle* t)
              (*print-readably* t)
              (*print-pretty* t))
          (write (serialize-population-checkpoint) :stream out))))
    (namestring path)))

(defun best-evaluated-team ()
  "Evaluate current root teams and return best team and best fitness.
Does not mutate or select."
  (unless *teams*
    (error "Cannot find best team: *TEAMS* is NIL."))

  (let* ((scores (evaluate))
         (sorted (sort (copy-list scores) #'> :key #'cdr))
         (best-entry (first sorted)))
    (unless best-entry
      (error "Cannot find best team: no valid evaluated scores."))
    (values (car best-entry) (cdr best-entry))))

(defun save-best-checkpoint (&optional (directory "best-checkpoint/"))
  "Save best individual and metadata without exiting."
  (multiple-value-bind (best-team best-fitness)
      (best-evaluated-team)
    (let* ((dir (uiop:ensure-directory-pathname directory))
           (solution-path (checkpoint-path dir "solution.lisp"))
           (metadata-path (checkpoint-path dir "metadata.lisp")))
      (ensure-directories-exist dir)

      (with-open-file (out solution-path
                           :direction :output
                           :if-exists :supersede
                           :if-does-not-exist :create)
        (with-standard-io-syntax
          (let ((*print-circle* t)
                (*print-readably* t)
                (*print-pretty* t))
            (write (serialize-team best-team) :stream out))))

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
               :best-fitness ,best-fitness
               :population-size ,*population-size*
               :num-observations ,*num-observations*
               :num-actions ,*num-actions*
               :gap ,*gap*
               :batch-size ,*batch-size*)
             :stream out))))

      (namestring dir))))

(defun load-solution (path)
  "Load serialized team solution."
  (with-open-file (in path :direction :input)
    (deserialize-team (read in) (make-hash-table :test #'equal))))

(defun run-solution-on-env (solution-path environment-name &key (seed (random 9999999)))
  "Run one episode using saved solution."
  (let ((team (load-solution solution-path)))
    (cl-gym:rollout team environment-name seed)))

(defun evaluate-solution-mean (solution-path environment-name &key (episodes 100))
  "Evaluate saved solution over EPISODES."
  (let ((team (load-solution solution-path)))
    (/ (loop repeat episodes
             sum (cl-gym:rollout team environment-name (random 9999999)))
       episodes)))

(defun load-population-checkpoint (path)
  "Load a saved population checkpoint."

  (with-open-file (in path :direction :input)
    (let* ((data (read in))
           (registry (make-hash-table :test #'equal)))

      ;; restore metadata
      (setf *generation*      (getf data :generation)
            *population-size* (getf data :population-size)
            *num-observations* (getf data :num-observations)
            *num-actions*      (getf data :num-actions)
            *gap*              (getf data :gap)
            *batch-size*       (getf data :batch-size))

      ;; restore teams
      (setf *teams*
            (mapcar
             (lambda (team-data)
               (deserialize-team team-data registry))
             (getf data :teams)))

      *teams*)))