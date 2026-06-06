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
  "Serialize current population and training metadata."
  `(:generation ,*generation*
    :population-size ,*population-size*
    :num-observations ,*num-observations*
    :num-actions ,*num-actions*
    :gap ,*gap*
    :batch-size ,*batch-size*
    :teams ,(mapcar #'serialize-team *teams*)))

(defun save-population-checkpoint (&optional (directory "population-checkpoint/"))
  "Save full population checkpoint into DIRECTORY/population.lisp."
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
              (*print-pretty* t))
          (write (serialize-team *best-team*) :stream out))))

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
  "Load a saved population checkpoint."
  (with-open-file (in path :direction :input)
    (let* ((data (read in))
           (registry (make-hash-table :test #'equal)))

      (setf *generation* (getf data :generation)
            *population-size* (getf data :population-size)
            *num-observations* (getf data :num-observations)
            *num-actions* (getf data :num-actions)
            *gap* (getf data :gap)
            *batch-size* (getf data :batch-size))

      (setf *teams*
            (mapcar
             (lambda (team-data)
               (deserialize-team team-data registry))
             (getf data :teams)))

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