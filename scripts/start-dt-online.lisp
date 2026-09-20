;;; Start phase-two TPG training against the five-member CAGE2 digital twin.
;;; Required environment variable: CAGE2_PHASE2_WARMSTART
;;; Optional: CAGE2_PHASE2_CHECKPOINT_DIR and CAGE2_PHASE2_SEED.

(require :asdf)
(asdf:load-system :cl-tpg)

(in-package :cl-tpg)

(defun required-environment-value (name)
  (or (uiop:getenv name)
      (error "Required environment variable ~A is not set." name)))

(let* ((warmstart (required-environment-value "CAGE2_PHASE2_WARMSTART"))
       (checkpoint-directory
         (or (uiop:getenv "CAGE2_PHASE2_CHECKPOINT_DIR")
             "/home/hardison/checkpoints/digital-twin/bline-62/"))
       (seed-text (or (uiop:getenv "CAGE2_PHASE2_SEED") "153"))
       (seed (parse-integer seed-text)))
  (format t "Starting CAGE2 phase two from ~A~%" warmstart)
  (format t "Digital-twin checkpoints: ~A~%"
          (required-environment-value "CAGE2_DT_CHECKPOINT_DIR"))
  (handle-resume-search
   (list
    :mode :online
    :gym-environment-name "Cage2Twin-b_line-100-v0"
    :dataset-name :none
    :best-team-path warmstart
    :checkpoint-directory checkpoint-directory
    :num-observations 62
    :num-actions 11
    ;; The bridge is sequential today; 80 keeps phase-two generations practical.
    :population-size 80
    :init-num-learners 3
    :max-num-learners 32
    :p-add 0.2d0
    :p-del 0.1d0
    :p-mut 0.5d0
    :p-act 0.2d0
    :p-swap 0.1d0
    :gap 0.5d0
    :init-program-size 100
    :max-program-size 256
    :p-add-instr 0.9d0
    :p-del-instr 0.5d0
    :p-swap-instrs 1.0d0
    :p-mut-constant 0.5d0
    :p-mut-constant-sign 0.1d0
    :migration-interval 50
    :batch-size 1000
    ;; One shared seed per member gives five rollouts/team/generation.
    :online-fitness-episodes 1
    :hamming-space-enabled :disabled
    :hamming-dataset-name :none
    :decoy-order-mode :fixed
    :cage2-opening-mode :fixed
    :teacher-forcing-rollout-mode :dagger
    :seed seed))
  (loop while *search-active*
        do (sleep 10))
  (when *last-search-failure*
    (error "Phase-two training stopped after failure: ~A"
           *last-search-failure*)))
