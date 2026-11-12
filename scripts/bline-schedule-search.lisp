(in-package :cl-tpg)

(defun bline-schedule-search-host-options (schedule)
  (loop for host from 1 below +num-semantic-targets+
        collect (loop for (target option) in schedule when (= target host) collect option)))

(defun bline-schedule-search-read (file)
  (with-open-file (stream file)
    (let ((*read-eval* nil))
      (read stream))))

(defun bline-schedule-search-score (team schedule samples)
  (assert (equal (bline-schedule-search-host-options schedule)
                 (bline-schedule-search-host-options +cage2-heuristic-decoy-schedule+)))
  (let ((*cage2-decoy-schedule-override* schedule))
    (loop for (horizon seed) in samples
          collect (cl-gym:rollout
                   team (cage2-validation-environment-name "b_line" horizon) seed))))

(defun run-bline-schedule-worker (checkpoint request output)
  (let* ((*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*decoy-order-mode* :fixed)
         (*cage2-opening-mode* :fixed)
         (*recurrent-policy-enabled* nil)
         (*hamming-space-enabled* nil)
         (*teacher-backend* :heuristic)
         (*cage2-controller-decoy-order-profile* :heuristic)
         (policy (rare-failure-load-policy :schedule-search checkpoint))
         (metadata (getf policy :metadata))
         (*instruction-set-profile* (getf metadata :instruction-set-profile))
         (*read-only-register-profile* (getf metadata :read-only-register-profile))
         (root (getf policy :team)))
    (destructuring-bind (samples jobs) (bline-schedule-search-read request)
      (with-open-file (out output :direction :output :if-exists :error)
        (loop for (id schedule) in jobs
              for scores = (bline-schedule-search-score root schedule samples)
              do (format out "~D~{~C~,8F~}~%"
                         id (loop for score in scores append (list #\Tab score)))
                 (finish-output out))))))
