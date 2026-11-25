;;; Focused checks for the shared action-agreement namespace.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(let ((agreement (cl-tpg::ensure-cage2-action-agreement)))
  (assert (string= (cl-tpg::action-agreement-schema agreement)
                   "cage2-factored-v1"))
  (assert (= (cl-tpg::action-agreement-version agreement) 1))
  (assert (string= (aref (cl-tpg::action-agreement-target-names agreement) 8)
                   "User2"))
  (assert (= (aref (cl-tpg::action-agreement-host-offsets agreement) 8) 10))
  (assert (= (cl-tpg::action-agreement-monitor-action agreement) 1))
  (assert (equalp (aref (cl-tpg::action-agreement-decoy-orders agreement) 8)
                  #(1 6 0 4 2 3 5 7))))

(format t "Action agreement checks passed.~%")
