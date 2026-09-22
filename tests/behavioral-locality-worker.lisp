;;; Simulator-free integration check for the passive Phase-2 worker protocol.

(in-package :cl-user)

(defvar *behavioral-locality-worker-checks* 0)

(defun check-locality-worker (condition description)
  (incf *behavioral-locality-worker-checks*)
  (unless condition
    (error "Behavioral-locality worker check failed: ~A" description)))

(let* ((directory
         (merge-pathnames
          (format nil "bes-locality-worker-~D/" (get-internal-real-time))
          (uiop:temporary-directory)))
       (child-path (merge-pathnames "child.lisp" directory))
       (parent-path (merge-pathnames "parent.lisp" directory))
       (request-path (merge-pathnames "request.lisp" directory))
       (result-path (merge-pathnames "result.lisp" directory))
       (outcome-path (merge-pathnames "outcome.lisp" directory))
       (child (cl-tpg::%make-team :id "sample-child" :learners nil))
       (parent (cl-tpg::%make-team :id "sample-parent" :learners nil))
       (lineage
         '(:mutation-events ((:INSTRUCTION-ADD 1))
           :top1-hamming 0.1d0
           :teacher-rank-changed-rate 0.1d0
           :ranking-distance-mean 0.05d0
           :top-k-overlap-mean 0.95d0
           :child-off-support-rate 0.0d0))
       (original-rollout (symbol-function 'cl-gym:rollout))
       (rollout-call 0))
  (ensure-directories-exist child-path)
  (unwind-protect
       (progn
         (cl-tpg::write-best-team-checkpoint child 0.0d0 child-path
                                             :num-observations 62)
         (cl-tpg::write-best-team-checkpoint parent 0.0d0 parent-path
                                             :num-observations 62)
         (cl-tpg::write-readable-object-atomically
          (list :version 1
                :sample-id "synthetic-1"
                :generation 5
                :stratum :medium-top1
                :child-path (namestring child-path)
                :parent-path (namestring parent-path)
                :result-path (namestring result-path)
                :outcome-path (namestring outcome-path)
                :gym-environment-name "stub"
                :num-observations 62
                :num-actions cl-tpg::+num-semantic-36-actions+
                :decoy-order-mode :fixed
                :cage2-opening-mode :fixed
                :teacher-backend :heuristic
                :seeds '(11 12 13)
                :behavioral-locality lineage)
          request-path)
         (setf (symbol-function 'cl-gym:rollout)
               (lambda (team environment seed)
                 (declare (ignore team environment))
                 (incf rollout-call)
                 (+ (coerce seed 'double-float)
                    (if (oddp rollout-call)
                        5.0d0
                        0.0d0))))
         (cl-tpg::run-behavioral-locality-sample-evaluation request-path)
         (let ((result (cl-tpg::read-readable-object result-path))
               (outcome (cl-tpg::read-readable-object outcome-path)))
           (check-locality-worker
            (and (eq (getf result :status) :complete)
                 (= (getf result :paired-mean) 5.0d0)
                 (= (getf result :episode-count) 3))
            (format nil
                    "worker publishes the paired child/direct-parent result: ~S"
                    result))
           (check-locality-worker
            (and (eq (getf outcome :type) :locality-sample-outcome)
                 (equal (getf outcome :sample-id) "synthetic-1")
                 (equal (getf (getf outcome :evaluation) :evaluated-seeds)
                        '(11 12 13))
                 (equal (getf (getf outcome :evaluation)
                              :behavioral-locality)
                        lineage))
            "worker journal retains seeds, lineage, and sampling identity")))
    (setf (symbol-function 'cl-gym:rollout) original-rollout)
    (dolist (path (list child-path parent-path request-path result-path
                        outcome-path))
      (when (probe-file path)
        (delete-file path)))
    (when (probe-file directory)
      (ignore-errors (uiop:delete-empty-directory directory)))))

(format t "Behavioral-locality worker checks passed: ~D.~%"
        *behavioral-locality-worker-checks*)
