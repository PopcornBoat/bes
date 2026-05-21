(in-package :cl-tpg)

(defun checkpoint-path (directory filename)
  (merge-pathnames filename
                   (uiop:ensure-directory-pathname directory)))

(defun save-best-checkpoint (&optional (directory "checkpoint-best/"))
  "Save the current best team and metadata into DIRECTORY.
Creates:
  solution.lisp
  metadata.lisp"
  (unless *teams*
    (error "Cannot save best checkpoint: *TEAMS* is NIL. Run search first."))

  (let* ((scores (evaluate))
         (sorted (sort (copy-list scores) #'> :key #'cdr))
         (best-entry (first sorted))
         (best-team (car best-entry))
         (best-fitness (cdr best-entry))
         (dir (uiop:ensure-directory-pathname directory))
         (solution-path (checkpoint-path dir "solution.lisp"))
         (metadata-path (checkpoint-path dir "metadata.lisp")))

    (unless best-entry
      (error "Cannot save best checkpoint: no valid team scores."))

    (ensure-directories-exist dir)

    ;; Save solution.
    (with-open-file (out solution-path
                         :direction :output
                         :if-exists :supersede
                         :if-does-not-exist :create)
      (with-standard-io-syntax
        (let ((*print-circle* t)
              (*print-readably* t)
              (*print-pretty* t))
          (write (serialize-team best-team) :stream out))))

    ;; Save metadata.
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

    directory))