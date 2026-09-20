;;; Record official CAGE2 trajectories from one BES/TPG checkpoint.
;;; Required: CAGE2_TPG_CHECKPOINT, CAGE2_DT_POLICY_SOURCE, CAGE2_DT_RECORD_DIR.

(require :asdf)
(asdf:load-system :cl-tpg)

(in-package :cl-tpg)

(let* ((checkpoint
         (or (uiop:getenv "CAGE2_TPG_CHECKPOINT")
             (error "CAGE2_TPG_CHECKPOINT is not set.")))
       (episodes
         (parse-integer
          (or (uiop:getenv "CAGE2_TPG_EPISODES") "200")))
       (base-seed
         (parse-integer
          (or (uiop:getenv "CAGE2_TPG_BASE_SEED") "30000153")))
       (team (load-best-team checkpoint)))
  (setf *num-observations* 62
        *num-actions* 11
        *decoy-order-mode* :fixed
        *cage2-opening-mode* :fixed
        *factored-actions-enabled* t
        *hamming-space-enabled* nil
        *running* t)
  (loop for offset below episodes
        for seed from base-seed
        do (cl-gym:rollout team "Cage2Recorded-b_line-100-v0" seed)
           (when (zerop (mod (1+ offset) 10))
             (format t "TPG-COLLECT checkpoint=~A completed=~D/~D~%"
                     checkpoint (1+ offset) episodes)
             (finish-output))))
