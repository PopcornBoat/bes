(in-package :cl-tpg)

(defvar *loaded-best-team* nil
  "Most recently loaded best team.")

(defun checkpoint-path (directory filename)
  "Return pathname for FILENAME under DIRECTORY."
  (merge-pathnames filename
                   (uiop:ensure-directory-pathname directory)))

(defun best-team-checkpoint-path (&optional (directory *checkpoint-directory*))
  "Return the default best-team checkpoint file path."
  (checkpoint-path directory "best-team.lisp"))

(defun save-best-team (&optional (path (best-team-checkpoint-path)))
  "Save the current *BEST-TEAM* to PATH."
  (unless *best-team*
    (error "Cannot save best team: *BEST-TEAM* is NIL."))

  (ensure-directories-exist path)

  (with-open-file (out path
                       :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (with-standard-io-syntax
      (let ((*print-circle* t)
            (*print-readably* t)
            (*print-pretty* nil))
        (write (serialize-team *best-team*) :stream out))))

  (emit-message
   (format nil "Best team saved: ~A" (namestring path)))

  path)

(defun maybe-save-best-team ()
  "Save *BEST-TEAM* every *CHECKPOINT-INTERVAL* generations."
  (when (and *best-team*
             *checkpoint-directory*
             (numberp *checkpoint-interval*)
             (> *checkpoint-interval* 0)
             (= (mod *generation* *checkpoint-interval*) 0))
    (save-best-team)))

(defun load-best-team (path)
  "Load best team from PATH and store it in *LOADED-BEST-TEAM*."
  (setf *loaded-best-team*
        (with-open-file (in path :direction :input)
          (with-standard-io-syntax
            (deserialize-team
             (read in)
             (make-hash-table :test #'equal))))))

(defun clear-loaded-best-team ()
  "Clear the loaded best team."
  (setf *loaded-best-team* nil))