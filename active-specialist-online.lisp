(in-package :cl-tpg)

(defparameter *active-specialist-cycle-interval* 100
  "Minimum generations between independent online gap-discovery launches.")
(defvar *active-specialist-process* nil)
(defvar *active-specialist-job* nil)
(defvar *active-specialist-cycle-count* 0)
(defvar *active-specialist-last-launch-generation* nil)

(defun active-specialist-state-copy ()
  (list :version 1
        :cycle-count *active-specialist-cycle-count*
        :last-launch-generation *active-specialist-last-launch-generation*))

(defun restore-active-specialist-state (state)
  (when state
    (unless (and (= (getf state :version 0) 1)
                 (integerp (getf state :cycle-count))
                 (not (minusp (getf state :cycle-count))))
      (error "Invalid active specialist state: ~S" state))
    (setf *active-specialist-cycle-count* (getf state :cycle-count)
          *active-specialist-last-launch-generation*
            (getf state :last-launch-generation))))

(defun reset-active-specialist-runtime ()
  (when (and *active-specialist-process*
             (ignore-errors (uiop:process-alive-p *active-specialist-process*)))
    (ignore-errors (uiop:terminate-process *active-specialist-process*)))
  (setf *active-specialist-process* nil
        *active-specialist-job* nil
        *active-specialist-cycle-count* 0
        *active-specialist-last-launch-generation* nil))

(defun active-specialist-cycle-directory (id)
  (checkpoint-path *checkpoint-directory*
                   (format nil ".active-specialist/cycle-~A/" id)))

(defun maybe-launch-active-specialist-cycle ()
  "Audit a frozen incumbent asynchronously; never use teacher labels."
  (when (and (eq *current-search-mode* :official-online)
             *best-team* *checkpoint-directory*
             (null *active-specialist-job*)
             (or (null *active-specialist-last-launch-generation*)
                 (>= (- *generation* *active-specialist-last-launch-generation*)
                     *active-specialist-cycle-interval*)))
    (let* ((id (format nil "~D-v~D-t~D"
                       *generation* *official-guided-incumbent-version*
                       (get-universal-time)))
           (directory (active-specialist-cycle-directory id))
           (checkpoint (merge-pathnames "incumbent.lisp" directory))
           (log (merge-pathnames "worker.log" directory))
           (script (merge-pathnames "scripts/run-active-specialist-cycle"
                                    (asdf:system-source-directory :cl-tpg)))
           (seed-root (first (official-guided-take-seeds :nomination 1))))
      (ensure-directories-exist checkpoint)
      (write-official-guided-team-checkpoint
       *best-team* *best-fitness* *generation* checkpoint)
      (setf *active-specialist-job*
            (list :id id :directory (namestring directory)
                  :checkpoint (namestring checkpoint)
                  :checkpoint-sha256 (incubation-file-sha256 checkpoint)
                  :incumbent-version *official-guided-incumbent-version*
                  :seed-root seed-root)
            *active-specialist-last-launch-generation* *generation*)
      (incf *active-specialist-cycle-count*)
      (persist-official-guided-runtime-state)
      (setf *active-specialist-process*
            (uiop:launch-program
             (list "bash" (namestring script) (namestring checkpoint)
                   *current-gym-environment-name*
                   (write-to-string seed-root) (namestring directory)
                   (namestring (asdf:system-source-directory :cl-tpg)))
             :input nil :output log :error-output :output
             :if-output-exists :supersede :ignore-error-status t))
      (emit-message
       (format nil
               "Teacher-free specialist cycle launched: generation=~D incumbent-v~D seed-root=~D log=~A."
               *generation* *official-guided-incumbent-version*
               seed-root (namestring log))))))

(defun poll-active-specialist-cycle ()
  "Import only independently confirmed evidence from the current incumbent."
  (when *active-specialist-job*
    (let* ((job *active-specialist-job*)
           (directory (pathname (getf job :directory)))
           (complete (merge-pathnames "cycle-complete" directory))
           (admission (merge-pathnames "incubation/admission-request.lisp"
                                       directory))
           (confirmation
             (merge-pathnames "incubation/confirmation-request.lisp"
                              directory))
           (summary (merge-pathnames "incubation/confirmation-summary.sexp"
                                     directory)))
      (cond
        ((probe-file complete)
         (when (and (null *official-admission-job*)
                    (null *online-candidate-job*)
                    (null *official-admission-full-queue*))
           (unwind-protect
                (cond
                  ((/= (getf job :incumbent-version)
                       *official-guided-incumbent-version*)
                   (emit-message
                    (format nil "Specialist cycle ~A discarded: incumbent changed."
                            (getf job :id))))
                  ((and (probe-file admission) (probe-file confirmation)
                        (probe-file summary)
                        (getf (rare-failure-read-form summary)
                              :eligible-for-import))
                   (let ((*incubation-admission-import-request*
                           (namestring admission))
                         (*incubation-confirmation-request*
                           (namestring confirmation)))
                     (maybe-import-incubation-admission
                      (getf job :checkpoint))))
                  (t
                   (emit-message
                    (format nil "Specialist cycle ~A found no confirmed repair."
                            (getf job :id)))))
             (setf *active-specialist-process* nil
                   *active-specialist-job* nil)
             (persist-official-guided-runtime-state))))
        ((and *active-specialist-process*
              (not (ignore-errors
                     (uiop:process-alive-p *active-specialist-process*))))
         (emit-message
          (format nil "Specialist cycle ~A failed; see ~Aworker.log."
                  (getf job :id) (getf job :directory)))
         (setf *active-specialist-process* nil
               *active-specialist-job* nil)
         (persist-official-guided-runtime-state))))))
