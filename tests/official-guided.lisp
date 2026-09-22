;;; Focused non-simulator checks for the frozen official-guided Phase-1 contract.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *official-guided-checks* 0)

(defun check-official-guided (condition description)
  (incf *official-guided-checks*)
  (unless condition
    (error "Official-guided check failed: ~A" description)))

(cl-tpg::initialize-official-guided-seed-streams 153)
(let* ((before (cl-tpg::official-guided-seed-state-copy))
       (training (cl-tpg::official-guided-take-seeds :training 5))
       (racing (cl-tpg::official-guided-take-seeds :racing 5))
       (promotion (cl-tpg::official-guided-take-seeds :promotion 5))
       (reference (cl-tpg::official-guided-take-reference-seeds 2))
       (after (cl-tpg::official-guided-seed-state-copy)))
  (check-official-guided
   (and (= (length training) 5)
        (= (length racing) 5)
        (= (length promotion) 5)
        (= (length reference) 6))
   "all four seed streams return the requested deterministic block")
  (check-official-guided
   (= (length (remove-duplicates
               (append training racing promotion reference)))
      (+ (length training) (length racing)
         (length promotion) (length reference)))
   "stream namespace bits prevent cross-stream seed reuse")
  (cl-tpg::restore-official-guided-seed-streams before)
  (check-official-guided
   (equal training
          (cl-tpg::official-guided-take-seeds :training 5))
   "restoring a cursor reproduces the exact next block")
  (cl-tpg::restore-official-guided-seed-streams after)
  (check-official-guided
   (= (getf (getf cl-tpg::*official-guided-seed-streams* :promotion)
            :cursor)
      5)
   "serialized state retains an independent promotion cursor"))

(let ((first
        (cl-tpg::official-guided-teacher-controls-p 12345 17 0.5d0))
      (second
        (cl-tpg::official-guided-teacher-controls-p 12345 17 0.5d0)))
  (check-official-guided
   (eq first second)
   "teacher mixing decisions are deterministic and query-only"))

(let ((record
        (cl-tpg::make-official-guided-evaluation-record
         :stage :promotion-stage-3
         :imitation-score 0.75d0
         :seeds '(1 2 3)
         :candidate-returns '(2.0d0 4.0d0 6.0d0)
         :incumbent-returns '(1.0d0 2.0d0 3.0d0)
         :accepted t)))
  (check-official-guided
   (and (= (getf record :official-mean) 4.0d0)
        (= (getf record :episode-count) 3)
        (= (getf record :paired-mean) 2.0d0)
        (= (getf record :paired-variance) 1.0d0)
        (= (getf record :unpaired-variance) 5.0d0)
        (= (getf record :same-seed-correlation) 1.0d0))
   "structured record preserves scalar, uncertainty, seeds, and CRN evidence"))

(let* ((lineage '(:top1-hamming 0.25d0 :mutation-events ((:LEARNER-ADD 1))))
       (record
         (cl-tpg::make-official-guided-parent-child-evaluation-record
          '(3.0d0 1.0d0) '(1.0d0 2.0d0) '(11 12) lineage)))
  (check-official-guided
   (and (eq (getf record :stage) :parent-child-racing)
        (= (getf record :paired-mean) 0.5d0)
        (equal (getf record :behavioral-locality) lineage))
   "direct-parent record pairs child and parent on the exact same seeds"))

(let* ((program
         (cl-tpg::make-program
          :instructions (make-array 0 :fill-pointer t :adjustable t)))
       (source
         (cl-tpg::%make-team
          :id "dagger-source"
          :learners
            (list
             (cl-tpg::make-learner
              :program program
              :action
                (cl-tpg::make-action
                 :type :atomic
                 :action
                   (cl-tpg::make-factored-action
                    :primary 2 :secondary 0))))))
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*teacher-dagger-behavior-team-snapshot* nil)
       (cl-tpg::*teacher-dagger-behavior-fitness* nil)
       (cl-tpg::*teacher-dagger-behavior-generation* nil))
  (cl-tpg::install-teacher-dagger-behavior-team
   source 0.75d0 9 :announce nil)
  (let* ((snapshot cl-tpg::*teacher-dagger-behavior-team-snapshot*)
         (state (cl-tpg::teacher-dagger-behavior-state-copy))
         (source-payload
           (cl-tpg::action-action
            (cl-tpg::learner-action
             (first (cl-tpg::team-learners source))))))
    (setf (cl-tpg::factored-action-primary source-payload) 7)
    (check-official-guided
     (and (not (eq source snapshot))
          (= (cl-tpg::factored-action-primary
              (cl-tpg::action-action
               (cl-tpg::learner-action
                (first (cl-tpg::team-learners snapshot)))))
             2))
     "DAgger behavior snapshot shares no mutable learner/action state")
    (cl-tpg::reset-teacher-dagger-behavior-state)
    (cl-tpg::restore-teacher-dagger-behavior-state state)
    (check-official-guided
     (and (= cl-tpg::*teacher-dagger-behavior-generation* 9)
          (= cl-tpg::*teacher-dagger-behavior-fitness* 0.75d0)
          (= (cl-tpg::factored-action-primary
              (cl-tpg::action-action
               (cl-tpg::learner-action
                (first
                 (cl-tpg::team-learners
                  cl-tpg::*teacher-dagger-behavior-team-snapshot*)))))
             2))
     "DAgger behavior state resumes as an independent serialized graph")))

(multiple-value-bind (continue-p mean margin)
    (cl-tpg::official-guided-continue-p
     '(-10.0d0 -10.0d0 -10.0d0)
     '(0.0d0 0.0d0 0.0d0))
  (check-official-guided
   (and (not continue-p) (= mean -10.0d0) (= margin 0.0d0))
   "a clearly futile challenger is rejected before promotion"))

(multiple-value-bind (promote-p mean margin)
    (cl-tpg::official-guided-promote-p
     '(2.0d0 2.0d0 2.0d0)
     '(1.0d0 1.0d0 1.0d0))
  (check-official-guided
   (and promote-p (= mean 1.0d0) (= margin 0.0d0))
   "only final positive paired evidence can promote"))

(check-official-guided
 (and (= cl-tpg::+official-guided-racing-episodes+ 5)
      (equal cl-tpg::+official-guided-promotion-stages+ '(12 40 100))
      (equal cl-tpg::+official-guided-reference-roots+ '(153 42 2026)))
 "racing, staged promotion, and monitoring roots are frozen by contract")

(let ((cl-tpg::*last-dagger-diagnostics*
        '(:disagreement-rate 0.70d0)))
  (check-official-guided
   (= (cl-tpg::official-guided-teacher-mixing-rate) 0.50d0)
   "high proposal disagreement keeps half of executed actions teacher-controlled"))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0")
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*num-actions* 11)
      (cl-tpg::*decoy-order-mode* :fixed)
      (cl-tpg::*teacher-backend* :model)
      (cl-tpg::*cage2-opening-mode* :fixed)
      (cl-tpg::*hamming-space-enabled* nil)
      (cl-tpg::*recurrent-policy-enabled* nil))
  (check-official-guided
   (string=
    (cl-tpg::best-team-checkpoint-filename)
    "bline-62-11-official-guided-dagger-order-fixed-teacher-model-opening-fixed-hamming-off-memory-stateless.lisp")
   "official-guided checkpoints have an unambiguous experiment name"))

(let ((cl-tpg::*checkpoint-directory* "/tmp/official-guided-test/"))
  (check-official-guided
   (not (equal
         (cl-tpg::official-guided-candidate-path
          "10-v1-t100" "result" "lisp")
         (cl-tpg::official-guided-candidate-path
          "10-v1-t101" "result" "lisp")))
   "candidate artifacts remain distinct when generation numbers repeat"))

(let* ((token (format nil "protected-~D-~D"
                      (get-universal-time) (get-internal-real-time)))
       (directory
         (merge-pathnames (format nil "~A/" token)
                          (uiop:temporary-directory)))
       (cl-tpg::*checkpoint-directory* directory)
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0")
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*num-actions* 11)
       (cl-tpg::*decoy-order-mode* :fixed)
       (cl-tpg::*teacher-backend* :model)
       (cl-tpg::*cage2-opening-mode* :fixed)
       (cl-tpg::*hamming-space-enabled* nil)
       (cl-tpg::*recurrent-policy-enabled* nil)
       (path (cl-tpg::best-team-checkpoint-path)))
  (unwind-protect
       (progn
         (ensure-directories-exist path)
         (with-open-file (stream path :direction :output
                                      :if-exists :supersede
                                      :if-does-not-exist :create)
           (write-string "protected-warm-start" stream))
         (check-official-guided
          (eq (cl-tpg::ensure-official-guided-incumbent-checkpoint)
              :preserved)
          "warm-start initialization refuses to overwrite an existing incumbent")
         (check-official-guided
          (string=
           (with-open-file (stream path :direction :input)
             (let ((text (make-string (file-length stream))))
               (read-sequence text stream)
               text))
           "protected-warm-start")
          "protected warm-start bytes remain unchanged"))
    (when (probe-file path)
      (delete-file path))))

;; Exercise the complete racing -> staged promotion -> monitoring worker without
;; starting CAGE2.  The temporary rollout function gives the candidate a
;; deterministic +1 return on every common seed.
(let* ((token (format nil "~D-~D"
                      (get-universal-time) (get-internal-real-time)))
       (directory (uiop:temporary-directory))
       (candidate-path
         (merge-pathnames (format nil "phase1-~A-candidate.lisp" token)
                          directory))
       (incumbent-path
         (merge-pathnames (format nil "phase1-~A-incumbent.lisp" token)
                          directory))
       (parent-path
         (merge-pathnames (format nil "phase1-~A-parent.lisp" token)
                          directory))
       (request-path
         (merge-pathnames (format nil "phase1-~A-request.lisp" token)
                          directory))
       (result-path
         (merge-pathnames (format nil "phase1-~A-result.lisp" token)
                          directory))
       (candidate (cl-tpg::%make-team :id "phase1-candidate" :learners nil))
       (incumbent (cl-tpg::%make-team :id "phase1-incumbent" :learners nil))
       (parent (cl-tpg::%make-team :id "phase1-parent" :learners nil))
       (original-rollout (symbol-function 'cl-gym:rollout))
       (rollout-count 0))
  (unwind-protect
       (progn
         (cl-tpg::write-best-team-checkpoint candidate 0.75d0 candidate-path)
         (cl-tpg::write-best-team-checkpoint incumbent 0.50d0 incumbent-path)
         (cl-tpg::write-best-team-checkpoint parent 0.70d0 parent-path)
         (cl-tpg::write-readable-object-atomically
          (list :version 1
                :candidate-path (namestring candidate-path)
                :incumbent-path (namestring incumbent-path)
                :direct-parent-path (namestring parent-path)
                :result-path (namestring result-path)
                :candidate-generation 10
                :candidate-imitation-score 0.75d0
                :incumbent-version 3
                :gym-environment-name "Cage2-b_line-100-v0"
                :num-observations 62
                :num-actions 11
                :decoy-order-mode :fixed
                :cage2-opening-mode :fixed
                :teacher-backend :model
                :racing-seeds '(1 2 3 4 5)
                :promotion-seeds (loop for seed from 101 to 200 collect seed)
                :promotion-stages '(12 40 100)
                :reference-seeds '(301 302 303 304 305 306))
          request-path)
         (setf (symbol-function 'cl-gym:rollout)
               (lambda (team environment seed &key video-path)
                 (declare (ignore team environment seed video-path))
                 (incf rollout-count)
                 (cond
                   ;; Racing invokes five candidate/incumbent pairs first.
                   ((<= rollout-count 10)
                    (if (oddp rollout-count) 1.0d0 0.0d0))
                   ;; The same five seeds then evaluate the direct parent.
                   ((<= rollout-count 15) 0.5d0)
                   ;; Remaining promotion/monitoring calls are paired again.
                   (t
                    (if (oddp (- rollout-count 15)) 1.0d0 0.0d0)))))
         (cl-tpg::run-official-guided-candidate-evaluation request-path)
         (let ((result (cl-tpg::read-readable-object result-path)))
           (check-official-guided
            (and (eq (getf result :status) :complete)
                 (getf result :accepted)
                 (eq (getf (getf result :evaluation-record) :stage)
                     :promotion-stage-3)
                 (= (getf (getf result :evaluation-record) :episode-count)
                    100)
                 (= (getf
                     (getf (getf result :evaluation-record)
                           :parent-child-evaluation)
                     :paired-mean)
                    0.5d0)
                 (= (getf (getf result :reference-monitoring) :episode-count)
                    6))
            (format nil
                    "worker promotes only after Stage 3 and keeps monitoring separate: ~S"
                    result))))
    (setf (symbol-function 'cl-gym:rollout) original-rollout)
    (dolist (path (list candidate-path incumbent-path parent-path
                        request-path result-path))
      (when (probe-file path)
        (delete-file path)))))

(format t "~D official-guided checks passed.~%" *official-guided-checks*)
