(in-package :cl-tpg)

;;; Teacher-free online selection. The fixed CAGE2 controller remains part of
;;; rollout, but teacher labels and imitation scores have no selection role.

(defun online-return-reset-runtime ()
  (setf *online-return-case-returns* nil
        *online-return-incumbent-version* 0
        *online-return-submission-count* 0
        *online-return-best-evaluation* nil))

(defun online-return-state-path ()
  (checkpoint-path *checkpoint-directory* "online-return-state.lisp"))

(defun online-return-persist-runtime ()
  (when (and *online-return-finetuning-enabled* *checkpoint-directory*
             *official-guided-seed-streams*)
    (write-readable-object-atomically
     (list :version 1 :protocol +online-return-finetuning-protocol+
           :checkpoint-filename (best-team-checkpoint-filename)
           :incumbent-version *online-return-incumbent-version*
           :submission-count *online-return-submission-count*
           :seed-streams (official-guided-seed-state-copy)
           :generation *generation*)
     (online-return-state-path))))

(defun online-return-restore-runtime (metadata source-path)
  "Restore stream cursors only for a checkpoint produced by this protocol."
  (let ((own-checkpoint-p
          (eq (getf metadata :fitness-evaluation-protocol)
              +online-return-finetuning-protocol+))
        (state-path (online-return-state-path)))
    (if own-checkpoint-p
        (let* ((state (and (probe-file state-path)
                           (read-readable-object state-path)))
               (checkpoint-streams
                 (getf metadata :online-return-seed-streams))
               (checkpoint-version
                 (getf metadata :online-return-incumbent-version)))
          (unless (and checkpoint-streams checkpoint-version)
            (error "Return checkpoint has no recoverable seed streams: ~A"
                   source-path))
          (unless state
            (error "Return runtime journal is missing; exact resume is unsafe: ~A"
                   state-path))
          (when (and state
                     (not (and (eq (getf state :protocol)
                                   +online-return-finetuning-protocol+)
                               (equal (getf state :checkpoint-filename)
                                      (best-team-checkpoint-filename)))))
            (error "Return runtime journal does not match checkpoint: ~A"
                   state-path))
          ;; The journal can be newer than the best checkpoint because ordinary
          ;; generations and rejected evaluations also reserve seeds.
          (unless (= (getf state :incumbent-version 0)
                     checkpoint-version)
            (error "Return runtime journal and incumbent checkpoint disagree."))
          (restore-official-guided-seed-streams
           (getf state :seed-streams))
          (setf *online-return-incumbent-version* checkpoint-version
                *online-return-submission-count*
                  (getf state :submission-count)
                *online-return-best-evaluation*
                  (copy-tree
                   (getf metadata :online-return-best-evaluation)))
          (emit-message
           (format nil
                   "Return fine-tuning seed streams restored: incumbent-v~D submissions=~D."
                   *online-return-incumbent-version*
                   *online-return-submission-count*)))
        (progn
          (when (probe-file state-path)
            (error "Return checkpoint directory already contains another run: ~A"
                   state-path))
          (setf *online-return-incumbent-version* 1
                *online-return-submission-count* 0
                *online-return-best-evaluation* nil)
          (emit-message
           (format nil "Return fine-tuning imported protected checkpoint: ~A"
                   source-path))))))

(defun online-return-initialize-incumbent
       (loaded-best-team &optional saved-best-fitness)
  "Protect the imported graph; never replace it from a training batch."
  (let* ((own-path (best-team-checkpoint-path))
         (already-saved (probe-file own-path)))
    (when (and already-saved
               (= *online-return-incumbent-version* 1)
               (null *online-return-best-evaluation*))
      (error "Refusing to overwrite an existing return checkpoint: ~A"
             own-path))
    (setf *best-team*
          (deep-copy-team-via-serialization loaded-best-team))
    (if *online-return-best-evaluation*
        (setf *best-fitness*
              (or saved-best-fitness
                  (getf *online-return-best-evaluation* :official-mean)
                  0.0d0))
        (let ((returns
                (cage2-reference-scores
                 *best-team* *current-gym-environment-name*)))
          ;; Initial fixed-root measurement is dashboard-only, never a
          ;; candidate promotion comparator.
          (setf *best-fitness* (arithmetic-mean returns)
                *online-return-best-evaluation*
                  (list :stage :imported-monitor-only
                        :official-mean *best-fitness*
                        :episode-count (length returns)))))
    (unless already-saved (save-best-team))
    (online-return-persist-runtime)
    (emit-message
     (format nil
             "Return fine-tuning protected incumbent v~D: monitor-mean=~,4F; no training-batch promotion."
             *online-return-incumbent-version* *best-fitness*))))

(defun online-return-specialist-order (scores sorted)
  "Round-robin per-seed rankings, excluding the aggregate champion."
  (let* ((length-of-block
           (length (gethash (caar sorted) *online-return-case-returns*)))
         (ranked-cases
           (loop for case-index below length-of-block
                 collect
                 (stable-sort
                  (copy-list scores) #'> :key
                  (lambda (entry)
                    (nth case-index
                         (gethash (car entry)
                                  *online-return-case-returns*))))))
         (chosen nil))
    (loop for rank below (length scores)
          do (dolist (ranking ranked-cases)
               (let ((entry (nth rank ranking)))
                 (when (and entry
                            (not (eq (car entry) (caar sorted)))
                            (not (member entry chosen :test #'eq)))
                   (push entry chosen)))))
    (nreverse chosen)))

(defun online-return-diverse-unselected (scores sorted n-remove)
  "Reserve 15% of survivor slots for distinct per-seed official specialists."
  (let* ((survivor-count (- (length sorted) n-remove))
         (specialist-count
           (min (max 0 (1- survivor-count))
                (max 1 (floor (* survivor-count
                                 +online-return-diversity-fraction+)))))
         (aggregate-count (- survivor-count specialist-count))
         (selected (subseq sorted 0 aggregate-count)))
    (dolist (entry (online-return-specialist-order scores sorted))
      (when (and (< (length selected) survivor-count)
                 (not (member entry selected :test #'eq)))
        (push entry selected)))
    (dolist (entry sorted)
      (when (and (< (length selected) survivor-count)
                 (not (member entry selected :test #'eq)))
        (push entry selected)))
    (remove-if (lambda (entry) (member entry selected :test #'eq))
               scores)))

(defun online-return-candidate-path (artifact-id kind type)
  (merge-pathnames
   (make-pathname :name (format nil "~A-~A" artifact-id kind)
                  :type type)
   (uiop:ensure-directory-pathname
    (checkpoint-path *checkpoint-directory*
                     ".online-return-candidates/"))))

(defun online-return-nominate (scores sorted)
  "Cycle aggregate, per-seed specialist, and random inspection lanes."
  (let* ((slot (mod *online-return-submission-count* 5))
         (specialists (online-return-specialist-order scores sorted)))
    (cond
      ((< slot 3) (values (first sorted) :aggregate))
      ((= slot 3)
       (values (or (first specialists) (first sorted)) :seed-specialist))
      (t
       (let* ((pool (or (rest sorted) sorted))
              (seed (first (official-guided-take-seeds :nomination 1))))
         (values (nth (mod seed (length pool)) pool) :random))))))

(defun online-return-maybe-submit (scores sorted)
  (when (and *checkpoint-directory* *best-team* (null *online-candidate-job*)
             (>= *generation* *online-candidate-next-submit-generation*))
    (multiple-value-bind (entry lane)
        (online-return-nominate scores sorted)
      (let* ((generation *generation*)
             (artifact-id
               (format nil "g~D-v~D-n~D-t~D" generation
                       *online-return-incumbent-version*
                       *online-return-submission-count*
                       (get-universal-time)))
             (candidate-path
               (online-return-candidate-path artifact-id "candidate" "lisp"))
             (incumbent-path
               (online-return-candidate-path artifact-id "incumbent" "lisp"))
             (request-path
               (online-return-candidate-path artifact-id "request" "lisp"))
             (result-path
               (online-return-candidate-path artifact-id "result" "lisp"))
             (log-path
               (online-return-candidate-path artifact-id "worker" "log"))
             (racing-seeds
               (official-guided-take-seeds
                :racing +online-return-screen-episodes+))
             (promotion-seeds
               (official-guided-take-seeds
                :promotion (car (last +online-return-promotion-stages+))))
             (reference-seeds
               (official-guided-take-reference-seeds))
             (worker-script
               (merge-pathnames
                "scripts/run-official-guided-candidate-evaluation.lisp"
                (asdf:system-source-directory :cl-tpg))))
        (write-online-candidate-checkpoint
         (car entry) (cdr entry) generation candidate-path)
        (write-online-candidate-checkpoint
         *best-team* *best-fitness* generation incumbent-path)
        (write-readable-object-atomically
         (list :version 1 :worker-mode :online-return
               :candidate-path (namestring candidate-path)
               :incumbent-path (namestring incumbent-path)
               :result-path (namestring result-path)
               :candidate-generation generation
               :incumbent-version *online-return-incumbent-version*
               :gym-environment-name *current-gym-environment-name*
               :num-observations *num-observations*
               :num-actions *num-actions*
               :decoy-order-mode *decoy-order-mode*
               :cage2-opening-mode *cage2-opening-mode*
               :teacher-backend *teacher-backend*
               :nomination-lanes (list lane)
               :racing-seeds racing-seeds
               :promotion-seeds promotion-seeds
               :promotion-stages (copy-list +online-return-promotion-stages+)
               :reference-seeds reference-seeds)
         request-path)
        (incf *online-return-submission-count*)
        (setf *online-candidate-next-submit-generation*
              (+ generation +online-candidate-evaluation-interval+))
        ;; Reservations are durable before the worker can consume them.
        (online-return-persist-runtime)
        (setf *online-candidate-process*
              (uiop:launch-program
               (list "sbcl" "--dynamic-space-size" "4096"
                     "--noinform" "--non-interactive"
                     "--load" (namestring worker-script)
                     "--end-toplevel-options" (namestring request-path))
               :input nil :output log-path :error-output :output
               :if-output-exists :supersede :ignore-error-status t)
              *online-candidate-job*
              (list :mode :online-return :generation generation
                    :lane lane :candidate-path candidate-path
                    :request-path request-path :result-path result-path
                    :log-path log-path
                    :incumbent-version *online-return-incumbent-version*))
        (emit-message
         (format nil
                 "Generation ~D teacher-free official candidate submitted: lane=~A racing=5 fresh-promotion=~S incumbent-v~D."
                 generation lane +online-return-promotion-stages+
                 *online-return-incumbent-version*))))))

(defun online-return-record-history (result)
  (let ((path (checkpoint-path *checkpoint-directory*
                               "online-return-history.lisp")))
    (with-open-file (out path :direction :output :if-exists :append
                              :if-does-not-exist :create)
      (with-standard-io-syntax
        (write
         (list :generation (getf result :candidate-generation)
               :incumbent-version (getf result :incumbent-version)
               :lane (getf *online-candidate-job* :lane)
               :status (getf result :status)
               :accepted (getf result :accepted)
               :stage (getf (getf result :evaluation-record) :stage)
               :paired-mean
                 (getf (getf result :evaluation-record) :paired-mean)
               :episode-count
                 (getf (getf result :evaluation-record) :episode-count)
               :result-path (getf *online-candidate-job* :result-path))
         :stream out)
        (terpri out)))))

(defun online-return-consume (result)
  (let* ((record (getf result :evaluation-record))
         (version (getf result :incumbent-version))
         (accepted (and (eq (getf result :status) :complete)
                        (getf result :accepted)
                        (eq (getf record :stage) :promotion-stage-4)
                        (eq (getf record :protocol)
                            +online-return-finetuning-protocol+))))
    (online-return-record-history result)
    (cond
      ((not (eq (getf result :status) :complete))
       (emit-message
        (format nil "Teacher-free candidate evaluation failed: ~A"
                (getf result :message))))
      ((/= version *online-return-incumbent-version*)
       (emit-message
        (format nil "Discarded stale teacher-free result against incumbent-v~D."
                version)))
      (accepted
       (let* ((candidate
                (load-best-team
                 (getf *online-candidate-job* :candidate-path)))
              (long-record
                (find 100 (getf record :horizon-records)
                      :key (lambda (item) (getf item :horizon))))
              (new-score (getf long-record :official-mean)))
         (unless (numberp new-score)
           (error "Accepted candidate has no 100-step return record."))
         (setf *best-team* (deep-copy-team-via-serialization candidate)
               *best-fitness* new-score
               *online-return-best-evaluation* (copy-tree record))
         (incf *online-return-incumbent-version*)
         (save-best-team)
         (online-return-persist-runtime)
         (emit-message
          (format nil
                  "TEACHER-FREE OFFICIAL PROMOTION: incumbent-v~D generation=~D long-mean=~,4F paired-aggregate=~,4F."
                  *online-return-incumbent-version*
                  (getf result :candidate-generation)
                  new-score (getf record :paired-mean 0.0d0)))))
      (t
       (emit-message
        (format nil
                "Teacher-free candidate rejected: generation=~D stage=~A paired-delta=~,4F."
                (getf result :candidate-generation)
                (getf record :stage)
                (getf record :paired-mean 0.0d0)))))))

(defun online-return-poll ()
  (when (and *online-candidate-job*
             (eq (getf *online-candidate-job* :mode) :online-return))
    (let ((result-path (getf *online-candidate-job* :result-path)))
      (cond
        ((probe-file result-path)
         (unwind-protect
              (online-return-consume (read-readable-object result-path))
           (setf *online-candidate-process* nil
                 *online-candidate-job* nil)))
        ((and *online-candidate-process*
              (not (ignore-errors
                     (uiop:process-alive-p *online-candidate-process*))))
         (emit-message
          (format nil "Teacher-free worker exited without result; see ~A"
                  (getf *online-candidate-job* :log-path)))
         (setf *online-candidate-process* nil
               *online-candidate-job* nil))))))
