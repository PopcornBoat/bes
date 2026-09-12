(in-package :cl-tpg)

(defvar *loaded-best-team* nil
  "Most recently loaded best team.")

(defvar *loaded-best-fitness* nil
  "Historical fitness stored with the most recently loaded best team.")

(defvar *loaded-checkpoint-metadata* nil
  "Metadata plist from the most recently loaded versioned checkpoint.")

(defconstant +best-team-checkpoint-version+ 9
  "Checkpoint version recording optional Hamming observation projection.")

(defun checkpoint-path (directory filename)
  "Return pathname for FILENAME under DIRECTORY."
  (merge-pathnames filename
                   (uiop:ensure-directory-pathname directory)))

(defun checkpoint-agent-type ()
  "Infer a short agent type from the active environment or dataset."
  (let* ((source
           (if *current-dataset-name*
               *current-dataset-name*
               *current-gym-environment-name*))
         (name (string-downcase (princ-to-string (or source "agent")))))
    (cond
      ((or (search "b_line" name)
           (search "b-line" name)
           (search "bline" name))
       "bline")
      ((search "meander" name)
       "meander")
      (t
       "agent"))))

(defun checkpoint-training-mode ()
  "Return the active search mode as a filename component."
  (cond
    (*current-dataset-name* "offline")
    ((and *current-gym-environment-name*
          (not (eq *current-gym-environment-name* :none)))
     "online")
    (t "unknown")))

(defun best-team-checkpoint-filename ()
  "Return a stable, configuration-describing best-team filename.

A configuration keeps overwriting its own immediate-best file, while agent,
observation/action shape, mode, and Hamming variants can coexist in one
checkpoint directory."
  (format nil
          "~A-~D-~D-~A-hamming-~A.lisp"
          (checkpoint-agent-type)
          *num-observations*
          *num-actions*
          (checkpoint-training-mode)
          (if *hamming-space-enabled* "on" "off")))

(defun best-team-checkpoint-path (&optional (directory *checkpoint-directory*))
  "Return the default best-team checkpoint file path."
  (checkpoint-path directory (best-team-checkpoint-filename)))

(defun make-best-team-checkpoint-data
       (team fitness &key generation gym-environment-name
                          online-fitness-episodes search-seed
                           fitness-evaluation-protocol dataset-name
                           dataset-fingerprint action-agreement-signature
                           hamming-space-enabled hamming-dataset-fingerprint)
  "Serialize TEAM and its historical-fitness context into a checkpoint envelope."
  `(:checkpoint-version ,+best-team-checkpoint-version+
    :fitness ,fitness
    :generation ,generation
    :gym-environment-name ,gym-environment-name
    :online-fitness-episodes ,online-fitness-episodes
    :search-seed ,search-seed
    :fitness-evaluation-protocol ,fitness-evaluation-protocol
    :dataset-name ,dataset-name
    :dataset-fingerprint ,dataset-fingerprint
    :action-agreement-signature ,action-agreement-signature
    :hamming-space-enabled ,hamming-space-enabled
    :hamming-dataset-fingerprint ,hamming-dataset-fingerprint
    :team ,(serialize-team team (make-hash-table :test #'equal))))

(defun versioned-best-team-checkpoint-p (data)
  "Return true when DATA is a versioned best-team checkpoint envelope."
  (and (listp data)
       (integerp (getf data :checkpoint-version))
       (getf data :team)))

(defun write-best-team-checkpoint
       (team fitness path &key generation gym-environment-name
                               online-fitness-episodes search-seed
                                fitness-evaluation-protocol dataset-name
                                dataset-fingerprint action-agreement-signature
                                hamming-space-enabled hamming-dataset-fingerprint)
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
           :fitness-evaluation-protocol fitness-evaluation-protocol
           :dataset-name dataset-name
           :dataset-fingerprint dataset-fingerprint
           :action-agreement-signature action-agreement-signature
           :hamming-space-enabled hamming-space-enabled
           :hamming-dataset-fingerprint hamming-dataset-fingerprint)
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
   :dataset-name *current-dataset-name*
    :dataset-fingerprint *current-dataset-fingerprint*
    :hamming-space-enabled *hamming-space-enabled*
    :hamming-dataset-fingerprint *current-hamming-dataset-fingerprint*
   :action-agreement-signature
     (and *factored-actions-enabled* (action-agreement-signature))
   :fitness-evaluation-protocol
   (cond
     ((cl-gym:cage2-environment-p *current-gym-environment-name*)
      +cage2-online-fitness-protocol+)
     (*offline-reference-dataset*
      +semantic-offline-fitness-protocol+)
     (t nil)))

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
                           fitness-evaluation-protocol dataset-name
                           dataset-fingerprint action-agreement-signature
                           hamming-space-enabled hamming-dataset-fingerprint)
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
     :fitness-evaluation-protocol fitness-evaluation-protocol
     :dataset-name dataset-name
     :dataset-fingerprint dataset-fingerprint
     :action-agreement-signature action-agreement-signature
     :hamming-space-enabled hamming-space-enabled
     :hamming-dataset-fingerprint hamming-dataset-fingerprint)
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
