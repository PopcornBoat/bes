;;; Focused non-simulator checks for donor-free multi-source admission.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *official-admission-checks* 0)

(defun check-official-admission (condition description)
  (incf *official-admission-checks*)
  (unless condition
    (error "Official admission check failed: ~A" description)))

(cl-tpg::initialize-official-guided-seed-streams 153)
(let* ((before (cl-tpg::official-guided-seed-state-copy))
       (admission (cl-tpg::official-guided-take-seeds :admission 2))
       (nomination (cl-tpg::official-guided-take-seeds :nomination 2)))
  (check-official-admission
   (and (= (length admission) 2)
        (= (length nomination) 2)
        (null (intersection admission nomination)))
   "admission and random nomination use disjoint deterministic streams")
  (cl-tpg::restore-official-guided-seed-streams before)
  (check-official-admission
   (equal admission
          (cl-tpg::official-guided-take-seeds :admission 2))
   "admission seed cursor is exactly replayable"))

(multiple-value-bind (keep mean se upper reason)
    (cl-tpg::official-admission-continue-p
     '(-2.0d0 -2.0d0) '(0.0d0 0.0d0))
  (declare (ignore se upper))
  (check-official-admission
   (and keep (= mean -2.0d0) (eq reason :uncertain-or-promising))
   "a small negative result is retained rather than treated as proof of failure"))

(multiple-value-bind (keep mean se upper reason)
    (cl-tpg::official-admission-continue-p
     '(-6.0d0 -6.0d0) '(0.0d0 0.0d0))
  (declare (ignore mean se upper))
  (check-official-admission
   (and (not keep) (eq reason :clearly-futile))
   "only a clearly negative upper confidence bound is rejected"))

(multiple-value-bind (keep mean se upper reason)
    (cl-tpg::official-admission-continue-p
     '(-100.0d0) '(0.0d0))
  (declare (ignore mean se upper reason))
  (check-official-admission
   keep
   "one noisy episode can never reject a candidate"))

(let* ((seeds (loop for seed from 1 to 100 collect seed))
       (incumbent (make-list 100 :initial-element 0.0d0))
       (candidate-a
         (list :candidate-id "a" :candidate-imitation-score 0.5d0
               :lanes '(:aggregate)
               :tournament-returns
                 (make-list 100 :initial-element 1.0d0)))
       (candidate-b
         (list :candidate-id "b" :candidate-imitation-score 0.9d0
               :lanes '(:random-control)
               :tournament-returns
                 (make-list 100 :initial-element 0.5d0)))
       (candidate-c
         (list :candidate-id "c" :candidate-imitation-score 1.0d0
               :lanes '(:specialist)
               :tournament-returns
                 (make-list 100 :initial-element -10.0d0))))
  (multiple-value-bind (records winner returned-seeds incumbent-returns)
      (cl-tpg::official-admission-tournament-select
       (list candidate-c candidate-b candidate-a) incumbent seeds)
    (let ((rejected
            (find "c" records :test #'string=
                              :key (lambda (record)
                                     (getf record :candidate-id)))))
      (check-official-admission
       (and (string= (getf winner :candidate-id) "a")
            (getf winner :tournament-selected)
            (= (length (getf winner :tournament-stages)) 4)
            (= (length (getf rejected :tournament-stages)) 1)
            (equal returned-seeds seeds)
            (equal incumbent-returns incumbent))
       "common-seed tournament is order-independent, staged, and selects one winner"))))

(let* ((teams (loop for index below 12 collect (intern (format nil "A~D" index))))
       (scores
         (loop for team in teams
               for fitness from 12 downto 1
               collect (cons team (coerce fitness 'double-float))))
       (sorted (copy-list scores))
       (phase-key '(:phase :steps-50-99))
       (pair-key '(:teacher-pair 2 3))
       (cl-tpg::*grouped-case-groups*
         (list (list :key phase-key :indices #(0 1))
               (list :key pair-key :indices #(2 3))))
       (cl-tpg::*grouped-team-group-scores* (make-hash-table :test #'eq))
       (cl-tpg::*grouped-team-row-behaviors* (make-hash-table :test #'eq))
       (cl-tpg::*official-admission-lane-statistics* nil))
  (loop for team in teams
        for index from 0
        do (let ((table (make-hash-table :test #'equal)))
             ;; Different roots lead the two specialist cases.
             (setf (gethash phase-key table)
                     (if (= index 3) 100.0d0 (coerce index 'double-float))
                   (gethash pair-key table)
                     (if (= index 4) 100.0d0
                         (coerce (- 12 index) 'double-float))
                   (gethash team cl-tpg::*grouped-team-group-scores*) table
                   (gethash team cl-tpg::*grouped-team-row-behaviors*)
                     (vector index (mod index 3) (mod index 5) (mod index 7)))))
  (cl-tpg::initialize-official-guided-seed-streams 153)
  (let* ((nominations
           (cl-tpg::official-admission-nominate scores sorted))
         (lanes
           (remove-duplicates
            (mapcan (lambda (record) (copy-list (getf record :lanes)))
                    nominations)
            :test #'eq)))
    (check-official-admission
     (= (length nominations) 8)
     "the default deduplicated batch contains eight distinct policies")
    (check-official-admission
     (every (lambda (lane) (member lane lanes :test #'eq))
            '(:aggregate :specialist :behavioral-diversity
              :critical-error :random-control))
     "all five nomination lanes contribute provenance")
    (check-official-admission
     (= (count :random-control nominations
               :test (lambda (lane record)
                       (member lane (getf record :lanes) :test #'eq)))
        2)
     "random control samples two policies only after deterministic lanes deduplicate")))

;; Exercise the batch worker without starting CAGE2.  The stubbed official
;; environment makes one candidate mildly negative and one clearly futile.
(let* ((token (format nil "~D-~D"
                      (get-universal-time) (get-internal-real-time)))
       (directory (uiop:temporary-directory))
       (incumbent-path
         (merge-pathnames (format nil "admission-~A-incumbent.lisp" token)
                          directory))
       (mild-path
         (merge-pathnames (format nil "admission-~A-mild.lisp" token)
                          directory))
       (bad-path
         (merge-pathnames (format nil "admission-~A-bad.lisp" token)
                          directory))
       (request-path
         (merge-pathnames (format nil "admission-~A-request.lisp" token)
                          directory))
       (result-path
         (merge-pathnames (format nil "admission-~A-result.lisp" token)
                          directory))
       (incumbent (cl-tpg::%make-team :id "admission-incumbent" :learners nil))
       (mild (cl-tpg::%make-team :id "admission-mild" :learners nil))
       (bad (cl-tpg::%make-team :id "admission-bad" :learners nil))
       (original-rollout (symbol-function 'cl-gym:rollout))
       (rollout-count 0))
  (unwind-protect
       (progn
         (let ((cl-tpg::*instruction-set-profile* :reduced-eq)
               (cl-tpg::*read-only-register-profile* :cage2-categorical-v1))
           (cl-tpg::write-best-team-checkpoint incumbent 0.5d0 incumbent-path)
           (cl-tpg::write-best-team-checkpoint mild 0.4d0 mild-path)
           (cl-tpg::write-best-team-checkpoint bad 0.3d0 bad-path))
         (cl-tpg::write-readable-object-atomically
          (list :version 1
                :protocol cl-tpg::+official-admission-protocol+
                :incumbent-path (namestring incumbent-path)
                :incumbent-version 7
                :result-path (namestring result-path)
                :gym-environment-name "Cage2-b_line-100-v0"
                :num-observations 62
                :num-actions 36
                :decoy-order-mode :fixed
                :cage2-opening-mode :fixed
                :teacher-backend :heuristic
                :seeds '(11 12)
                :candidates
                  (list
                   (list :candidate-id "mild"
                         :candidate-path (namestring mild-path)
                         :candidate-generation 10
                         :candidate-imitation-score 0.4d0
                         :lanes '(:random-control))
                   (list :candidate-id "bad"
                         :candidate-path (namestring bad-path)
                         :candidate-generation 10
                         :candidate-imitation-score 0.3d0
                         :lanes '(:specialist))))
          request-path)
         (setf (symbol-function 'cl-gym:rollout)
               (lambda (team environment seed &key video-path)
                 (declare (ignore team environment seed video-path))
                 (incf rollout-count)
                 (cond
                   ((<= rollout-count 2) 0.0d0)
                   ((<= rollout-count 4) -2.0d0)
                   (t -10.0d0))))
         (cl-tpg::run-official-admission-evaluation request-path)
         (let* ((result (cl-tpg::read-readable-object result-path))
                (records (getf result :candidate-results))
                (mild-record (find "mild" records :test #'string=
                                   :key (lambda (x) (getf x :candidate-id))))
                (bad-record (find "bad" records :test #'string=
                                  :key (lambda (x) (getf x :candidate-id)))))
           (check-official-admission
            (and (eq (getf result :status) :complete)
                 (getf mild-record :keep)
                 (not (getf bad-record :keep))
                 (equal (getf mild-record :incumbent-returns)
                        (getf bad-record :incumbent-returns))
                 (equal (getf mild-record :lanes) '(:random-control)))
            (format nil
                    "batch worker shares incumbent seeds and applies only the negative filter: ~S"
                    result))))
    (setf (symbol-function 'cl-gym:rollout) original-rollout)
    (dolist (path (list incumbent-path mild-path bad-path
                        request-path result-path))
      (when (probe-file path)
        (delete-file path)))))

(format t "~D official-admission checks passed.~%"
        *official-admission-checks*)
