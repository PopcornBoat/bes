(in-package :cl-tpg)

(defun validation-mean (xs)
  (if xs
      (/ (reduce #'+ xs) (length xs))
      0.0d0))

(defun validation-std (xs)
  (let* ((n (length xs))
         (m (validation-mean xs)))
    (if (< n 2)
        0.0d0
        (sqrt (/ (reduce #'+
                         (mapcar (lambda (x)
                                   (expt (- x m) 2))
                                 xs))
                 (- n 1))))))

(defun seed-cage2-evaluation ()
  "Report initialization of the deterministic CAGE2 episode-seed sequence.

The caller binds the Lisp generator to 153 and supplies each derived seed to the
environment reset. Python and native Lisp backends therefore receive identical
per-episode seed inputs without changing randomness after validation."
  (emit-message
   (format nil
           "CAGE2 validation random seed initialized to ~A."
           +cage2-evaluation-seed+)))

(defun run-validation-rollouts (team gym-environment-name episodes)
  "Run TEAM in GYM-ENVIRONMENT-NAME for EPISODES episodes."
  (loop repeat episodes
        collect (cl-gym:rollout team
                                gym-environment-name
                                (random 9999999))))

(defun emit-validation-result (label scores)
  "Emit one validation result line."
  (let ((mean (validation-mean scores))
        (std (validation-std scores)))
    (emit-message
     (format nil
             "~A: mean=~A std=~A episodes=~A"
             label
             mean
             std
             (length scores)))
    (list :label label
          :episodes (length scores)
          :mean mean
          :std std
          :scores scores)))

(defun emit-cage2-total-result (red-agent-name results)
  "Emit CAGE2 total score for one selected red agent."
  (let* ((means (mapcar (lambda (result)
                          (getf result :mean))
                        results))
         (total (reduce #'+ means)))
    (emit-message
     (format nil
             "~A-total: reward=~A"
             red-agent-name
             total))
    (list :label (format nil "~A-total" red-agent-name)
          :red-agent red-agent-name
          :total total
          :component-means means)))

(defun cage2-validation-environment-name (backend red-agent-name steps)
  "Build the selected official-Python or native-Lisp CAGE2 environment name."
  (let ((prefix
          (ecase backend
            (:cage2 "Cage2")
            (:cage2-lisp "Cage2Lisp"))))
    (format nil "~A-~A-~A-v0" prefix red-agent-name steps)))

(defun validate-cage2-single-red-full
       (team red-agent-name &optional (backend :cage2))
  "CAGE2 mode 1.

Single selected red agent.
Runs:
  30 steps  x 1000 eps
  50 steps  x 1000 eps
  100 steps x 1000 eps

Outputs:
  red-30
  red-50
  red-100
  red-total"
  (let ((results '()))
    (dolist (steps '(30 50 100))
      (let* ((env-name
               (cage2-validation-environment-name
                backend red-agent-name steps))
             (label (format nil "~A-~A" red-agent-name steps))
             (scores (run-validation-rollouts team env-name 1000)))
        (push (emit-validation-result label scores)
              results)))

    (let* ((ordered-results (nreverse results))
           (total-result
            (emit-cage2-total-result red-agent-name ordered-results)))
      (append ordered-results
              (list total-result)))))

(defun validate-cage2-single-red-100
       (team red-agent-name episodes &optional (backend :cage2))
  "CAGE2 mode 2.

Single selected red agent.
Runs:
  100 steps x EPISODES."
  (let* ((env-name
           (cage2-validation-environment-name
            backend red-agent-name 100))
         (label (format nil "~A-100" red-agent-name))
         (scores (run-validation-rollouts team env-name episodes))
         (result (emit-validation-result label scores))
         (total-result
          (emit-cage2-total-result red-agent-name (list result))))
    (list result total-result)))

(defun validate-cage3-full (team)
  "CAGE3 mode 1.

Runs:
  500 steps x 1000 eps.

The 500-step limit is encoded in the Python Gym environment."
  (let* ((env-name "Cage3SharedPolicy-v0")
         (label "cage3-500")
         (scores (run-validation-rollouts team env-name 1000)))
    (list (emit-validation-result label scores))))

(defun validate-cage3-custom-eps (team episodes)
  "CAGE3 mode 2.

Runs:
  500 steps x EPISODES.

The 500-step limit is encoded in the Python Gym environment."
  (let* ((env-name "Cage3SharedPolicy-v0")
         (label "cage3-500")
         (scores (run-validation-rollouts team env-name episodes)))
    (list (emit-validation-result label scores))))

(defun validate-best-team (best-team-path environment mode
                           &key red-agent-name episodes)
  "Load BEST-TEAM-PATH and run validation.

ENVIRONMENT:
  :cage2       official CAGE2 through Python/Py4CL2
  :cage2-lisp  native Lisp cage2-mini
  :cage3

CAGE2 MODE:
  :single-red-full
    Requires RED-AGENT-NAME.
    Runs 30/50/100 steps, 1000 eps each.

  :single-red-100
    Requires RED-AGENT-NAME and EPISODES.
    Runs 100 steps, EPISODES eps.

CAGE3 MODE:
  :full
    Runs 500 steps, 1000 eps.

  :custom-eps
    Requires EPISODES.
    Runs 500 steps, EPISODES eps."
  (let* ((cage2-p (member environment '(:cage2 :cage2-lisp)))
         (*random-state*
           (if cage2-p
               (sb-ext:seed-random-state +cage2-evaluation-seed+)
               *random-state*)))
    (when cage2-p
      (seed-cage2-evaluation))

    (let ((team (load-best-team best-team-path)))
      (emit-message
       (format nil
               "Validation started. best-team=~A environment=~A mode=~A red=~A episodes=~A"
               best-team-path
               environment
               mode
               red-agent-name
               episodes))

      (ecase environment
        ((:cage2 :cage2-lisp)
         (unless red-agent-name
           (error "CAGE2 validation requires RED-AGENT-NAME."))
         (ecase mode
           (:single-red-full
            (validate-cage2-single-red-full
             team red-agent-name environment))
           (:single-red-100
            (unless episodes
              (error "CAGE2 :SINGLE-RED-100 requires EPISODES."))
            (validate-cage2-single-red-100
             team red-agent-name episodes environment))))

        (:cage3
         (ecase mode
           (:full
            (validate-cage3-full team))
           (:custom-eps
            (unless episodes
              (error "CAGE3 :CUSTOM-EPS requires EPISODES."))
            (validate-cage3-custom-eps team episodes))))))))
