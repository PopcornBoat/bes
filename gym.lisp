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
  "Return true when ENVIRONMENT-NAME identifies a CAGE2 bridge environment."
  (and (stringp environment-name)
       (search "Cage2" environment-name)))

(defun seed-python-random (seed)
  "Seed Python's process-wide random generator once with integer SEED.

Official CAGE2 evaluation uses random.seed(153) before running its episode
sequence. Seeding once per evaluation preserves that advancing sequence;
reseeding every episode would instead repeat one stochastic trajectory."
  (unless (integerp seed)
    (error "Python random seed must be an integer, got ~S." seed))
  (py4cl2:pyexec "import random")
  (py4cl2:pycall "random.seed" seed))

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

(defun rollout (root-team environment-name seed &key (video-path nil))
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
         (episode-reward 0.0)
         (observation (reset env seed)))
    (unwind-protect
         (loop for timestep from 0
               do (let ((action
                          (if (shared-policy-observation-p observation)
                              (shared-policy-actions root-team observation)
                              (cl-tpg:execute-team root-team observation))))
                    (multiple-value-bind (obs rew term trunc info)
                        (step env action)
                      (declare (ignore info))
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

(defun cl-gym-validate-team (team gym-environment-name &optional seed)
  "Run TEAM in a validation Gym environment.

The validation protocol, including episode count, step limits, red agents,
and scoring rules, is owned by the Python environment. Lisp only loads the
team, calls the environment, and returns the reported validation score."
  (cl-gym:rollout team
                  gym-environment-name
                  (or seed (random 9999999))))
