(in-package :cl-tpg)

(defvar *loaded-best-team* nil
  "Most recently loaded best team.")

(defvar *loaded-best-fitness* nil
  "Historical fitness stored with the most recently loaded best team.")

(defvar *loaded-checkpoint-metadata* nil
  "Metadata plist from the most recently loaded versioned checkpoint.")

(defconstant +best-team-checkpoint-version+ 4
  "Current version of the best-team checkpoint envelope.")

(defun checkpoint-path (directory filename)
  "Return pathname for FILENAME under DIRECTORY."
  (merge-pathnames filename
                   (uiop:ensure-directory-pathname directory)))

(defun best-team-checkpoint-path (&optional (directory *checkpoint-directory*))
  "Return the default best-team checkpoint file path."
  (checkpoint-path directory "best-team.lisp"))

(defun make-best-team-checkpoint-data
       (team fitness &key generation gym-environment-name
                          online-fitness-episodes search-seed
                          fitness-evaluation-protocol)
  "Serialize TEAM and its historical-fitness context into a checkpoint envelope."
  `(:checkpoint-version ,+best-team-checkpoint-version+
    :fitness ,fitness
    :generation ,generation
    :gym-environment-name ,gym-environment-name
    :online-fitness-episodes ,online-fitness-episodes
    :search-seed ,search-seed
    :fitness-evaluation-protocol ,fitness-evaluation-protocol
    :team ,(serialize-team team (make-hash-table :test #'equal))))

(defun versioned-best-team-checkpoint-p (data)
  "Return true when DATA is a versioned best-team checkpoint envelope."
  (and (listp data)
       (integerp (getf data :checkpoint-version))
       (getf data :team)))

(defun write-best-team-checkpoint
       (team fitness path &key generation gym-environment-name
                               online-fitness-episodes search-seed
                               fitness-evaluation-protocol)
  "Write TEAM, FITNESS, and provenance metadata to PATH."
  (ensure-directories-exist path)

  (with-open-file (out path
                       :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (with-standard-io-syntax
      (let ((*print-circle* t)
            (*print-readably* t)
            (*print-pretty* nil))
        (write
         (make-best-team-checkpoint-data
           team
           fitness
           :generation generation
           :gym-environment-name gym-environment-name
           :online-fitness-episodes online-fitness-episodes
           :search-seed search-seed
           :fitness-evaluation-protocol fitness-evaluation-protocol)
         :stream out))))

  path)

(defun save-best-team (&optional (path (best-team-checkpoint-path)))
  "Save the frozen *BEST-TEAM* and its historical fitness to PATH."
  (unless *best-team*
    (error "Cannot save best team: *BEST-TEAM* is NIL."))

  (write-best-team-checkpoint
   *best-team*
   *best-fitness*
   path
   :generation *generation*
   :gym-environment-name *current-gym-environment-name*
   :online-fitness-episodes *online-fitness-episodes*
   :search-seed *current-search-seed*
   :fitness-evaluation-protocol
   (and (cl-gym:cage2-environment-p *current-gym-environment-name*)
        +cage2-online-fitness-protocol+))

  (emit-message
   (format nil
           "Best team saved immediately: ~A"
           (namestring path)))

  path)

(defun load-best-team (path)
  "Load a best team from PATH.

Versioned checkpoints return TEAM, FITNESS, and METADATA as three values.
Legacy files containing only serialized team data remain fully supported and
return NIL for FITNESS and METADATA."
  (let* ((data
           (with-open-file (in path :direction :input)
             (with-standard-io-syntax
               (read in))))
         (versioned-p (versioned-best-team-checkpoint-p data))
         (team-data (if versioned-p (getf data :team) data))
         (fitness (and versioned-p (getf data :fitness)))
         (metadata
           (and versioned-p
                (loop for (key value) on data by #'cddr
                      unless (eq key :team)
                        append (list key value))))
         (team
           (deserialize-team
            team-data
            (make-hash-table :test #'equal))))
    (setf *loaded-best-team* team
          *loaded-best-fitness* fitness
          *loaded-checkpoint-metadata* metadata)
    (values team fitness metadata)))

(defun upgrade-best-team-checkpoint
       (path fitness &key output-path generation gym-environment-name
                          online-fitness-episodes search-seed
                          fitness-evaluation-protocol)
  "Add fitness metadata to a legacy best-team checkpoint.

OUTPUT-PATH defaults to PATH.  Supplying a different path is recommended when
preserving the original legacy file."
  (unless (numberp fitness)
    (error "Checkpoint fitness must be numeric, got ~S." fitness))
  (let ((team (load-best-team path))
        (destination (or output-path path)))
    (write-best-team-checkpoint
     team
     fitness
     destination
     :generation generation
     :gym-environment-name gym-environment-name
     :online-fitness-episodes online-fitness-episodes
     :search-seed search-seed
     :fitness-evaluation-protocol fitness-evaluation-protocol)
    (emit-message
     (format nil
             "Best-team checkpoint metadata written: ~A fitness=~A"
             (namestring (pathname destination))
             fitness))
    destination))

(defun clear-loaded-best-team ()
  "Clear the loaded best team."
  (setf *loaded-best-team* nil
        *loaded-best-fitness* nil
        *loaded-checkpoint-metadata* nil))

(defun deep-copy-team-via-serialization (team)
  "Create a fully independent copy of TEAM using the existing
TPG serialization/deserialization mechanism.

Unlike CLONE-TEAM, this copies the complete referenced team graph
instead of sharing internal referenced teams."
  (let ((serialized
          (serialize-team
           team
           (make-hash-table :test #'equal))))
    (deserialize-team
     serialized
     (make-hash-table :test #'equal))))
