(in-package :cl-gym)

(defun obs->array (obs)
  "Coerces a flat observation OBS into a simple double-float array."
  (map '(simple-array double-float (*))
       (lambda (x) (coerce x 'double-float))
       obs))

(defun matrix-observation-p (obs)
  "Returns T if OBS is a rank-2 array, e.g. Cage3 obs #2A(...)."
  (and (arrayp obs)
       (= (array-rank obs) 2)))

(defun matrix->row-arrays (matrix)
  "Convert a rank-2 array into a list of rank-1 double-float arrays."
  (loop for i below (array-dimension matrix 0)
        collect
        (let* ((cols (array-dimension matrix 1))
               (row (make-array cols :element-type 'double-float)))
          (loop for j below cols
                do (setf (aref row j)
                         (coerce (aref matrix i j) 'double-float)))
          row)))

(defun nested-observation-p (obs)
  "Returns T if OBS looks like a nested multi-agent observation list."
  (and (listp obs)
       obs
       (listp (first obs))))

(defun obs->matrix (obs)
  "Coerce nested observation list into a list of double-float arrays."
  (mapcar #'obs->array obs))

(defun normalize-obs (obs)
  "Convert OBS into:
   - simple double-float array for normal single-agent envs
   - list of simple double-float arrays for shared-policy multi-agent envs"
  (cond
    ;; Py4CL may convert NumPy shape (18, obs_dim) into Lisp #2A(...)
    ((matrix-observation-p obs)
     (matrix->row-arrays obs))

    ;; Or it may arrive as nested lists.
    ((nested-observation-p obs)
     (obs->matrix obs))

    ;; Normal single-agent observation.
    (t
     (obs->array obs))))

(defun shared-policy-observation-p (observation)
  "Returns T if OBSERVATION is a list of per-agent observation arrays."
  (and (listp observation)
       observation
       (typep (first observation) '(simple-array double-float (*)))))

(defun shared-policy-actions (root-team observation)
  "Apply ROOT-TEAM once per per-agent observation."
  (mapcar (lambda (single-observation)
            (cl-tpg:execute-team root-team single-observation))
          observation))

(defun cage2-environment-p (environment-name)
  "Return true when ENVIRONMENT-NAME identifies any CAGE2 backend."
  (and (stringp environment-name)
       (search "Cage2" environment-name)))

(defun seed-python-random (seed)
  "Seed Python's process-wide random generator once with integer SEED.

This remains available for callers that need process-wide Python seeding.
Normal CAGE2 fitness now supplies a distinct explicit seed to each environment
reset instead."
  (unless (integerp seed)
    (error "Python random seed must be an integer, got ~S." seed))
  (py4cl2:pyexec "import random")
  (py4cl2:pycall "random.seed" seed))

(defun semantic-response-index (response)
  "Return the Python bridge index for a BES semantic host RESPONSE."
  (case response
    (:analyse 0)
    (:remove 1)
    (:restore 2)
    (:decoy 3)
    (otherwise nil)))

(defun semantic-action->cage2-input (action)
  "Convert a BES SEMANTIC-ACTION into py4cl2-friendly integer input.

The Python bridge accepts (TARGET RESPONSE OPTION). GLOBAL and defensive
:MONITOR fallbacks canonicalize to (0 0 0). Non-Decoy responses use option 0."
  (let* ((target (cl-tpg:semantic-action-target action))
         (response (cl-tpg:semantic-action-response action))
         (option (cl-tpg:semantic-action-option action))
         (response-index (semantic-response-index response)))
    (cond
      ((or (not (integerp target))
           (< target cl-tpg:+global-target+)
           (>= target cl-tpg:+num-semantic-targets+)
           (= target cl-tpg:+global-target+)
           (eq response :monitor)
           (null response-index))
       (list cl-tpg:+global-target+ 0 0))
      ((eq response :decoy)
       (if (and (integerp option) (<= 0 option 7))
           (list target response-index option)
           (list cl-tpg:+global-target+ 0 0)))
      (t
       (list target response-index 0)))))

(defun cage2-policy-decision (root-team observation controller)
  "Resolve the CAGE2 policy's Top-8 proposals into a bridge action."
  (unless (= (length observation) cl-tpg::+cage2-observation-size+)
    (error "Expected ~D bridge-augmented CAGE2 observations, got ~D."
           cl-tpg::+cage2-observation-size+ (length observation)))
  (cl-tpg::cage2-controller-resolve-ranking
   controller (cl-tpg::execute-team-semantic-ranked root-team observation)))

(defun cage2-info-value (info name)
  "Read NAME from a py4cl2-converted Gym info mapping."
  (let ((keyword (intern (string-upcase name) :keyword)))
    (cond
      ((hash-table-p info)
       (multiple-value-bind (value found-p) (gethash name info)
         (if found-p value (gethash keyword info))))
      ((listp info)
       (or (ignore-errors (cdr (assoc name info :test #'string=)))
           (ignore-errors (cdr (assoc keyword info :test #'eq)))
           (ignore-errors (getf info keyword))))
      (t nil))))

(defun commit-controller-step (controller decision info)
  "Commit DECISION using the concrete action reported by the bridge."
  (let ((actual (cage2-info-value info "concrete_action")))
    (unless (integerp actual)
      (error "CAGE2 bridge did not report an integer concrete_action: ~S"
             info))
    (cl-tpg::cage2-controller-commit-decision controller decision actual)))

(defun make (environment-name &key (video-path nil))
  "Makes a new Gymnasium environment."
  (if video-path
      (let ((env (py4cl2:pycall "gym.make" environment-name :render_mode "rgb_array")))
        (py4cl2:pycall "gym.wrappers.RecordVideo"
                       env
                       "./"
                       :episode_trigger (py4cl2:pyeval "lambda x: True")))
      (py4cl2:pycall "gym.make" environment-name)))

(defun reset (env seed)
  "Reset the environment to a fresh start."
  (normalize-obs
   (car (py4cl2:pymethod env "reset" :seed seed))))

(defun step (env action)
  "Interact with the environment by taking ACTION."
  (destructuring-bind (obs rew term trunc info)
      (py4cl2:pymethod env "step" action)
    (values (normalize-obs obs) rew term trunc info)))

(defun rollout-python (root-team environment-name seed &key (video-path nil))
  "Run one complete episode.

Supports:
- normal single-agent Gymnasium envs
- Cage2 single-agent envs
- Cage3 shared-policy multi-agent envs"
  (py4cl2:pyexec "import gymnasium as gym")

  (when (search "Cage2" environment-name)
    (py4cl2:pyexec "import cage2_bridge"))

  (when (search "Cage3" environment-name)
    (py4cl2:pyexec "import cage3_bridge"))

  (let* ((env (make environment-name :video-path video-path))
         (controller (when (cage2-environment-p environment-name)
                       (cl-tpg::make-cage2-controller)))
         (episode-reward 0.0)
         (observation (reset env seed)))
    (unwind-protect
         (loop for timestep from 0
               do (let* ((decision (when controller
                                      (cage2-policy-decision
                                       root-team observation controller)))
                         (action (cond
                                   (decision
                                    (semantic-action->cage2-input
                                     (cl-tpg::cage2-controller-decision-semantic-action
                                      decision)))
                                   ((shared-policy-observation-p observation)
                                    (shared-policy-actions root-team observation))
                                   (t (cl-tpg:execute-team root-team observation)))))
                    (multiple-value-bind (obs rew term trunc info)
                        (step env action)
                      (when decision
                        (commit-controller-step controller decision info))
                      (incf episode-reward rew)
                      (setf observation obs)
                      (when (or term trunc)
                        (return)))))
      (ignore-errors
        (py4cl2:pymethod env "close")
        (when (and video-path
                   (probe-file "rl-video-episode-0.mp4"))
          (rename-file "rl-video-episode-0.mp4" video-path))))
    episode-reward))

(defun rollout (root-team environment-name seed &key (video-path nil))
  "Run a rollout through the Python Gymnasium bridge."
  (rollout-python root-team environment-name seed :video-path video-path))

(defun cl-gym-validate-team (team gym-environment-name &optional seed)
  "Run TEAM in a validation Gym environment.

The validation protocol, including episode count, step limits, red agents,
and scoring rules, is owned by the Python environment. Lisp only loads the
team, calls the environment, and returns the reported validation score."
  (cl-gym:rollout team
                  gym-environment-name
                  (or seed (random 9999999))))
