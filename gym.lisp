(in-package :cl-gym)

(defun obs->array (obs)
  "Coerces an observation OBS from list to simple double-float array.
   Our TPG implementation assumes double-float arrays for maximum performance.
   Py4CL sends the observations as lists."
  (map '(simple-array double-float (*))
	 (lambda (x) (coerce x 'double-float))
	 obs))

(defun make (environment-name &key (video-path nil))
  "Makes a new Gymnasium environment. If you are using a custom Gymnasium environment,
   make sure to register it first."
  (if video-path
      (let ((env (py4cl2:pycall "gym.make" environment-name :render_mode "rgb_array")))
	(py4cl2:pycall "gym.wrappers.RecordVideo"
		       env
		       "./"
		       :episode_trigger (py4cl2:pyeval "lambda x: True")))
      (py4cl2:pycall "gym.make" environment-name)))
  
(defun reset (env seed)
  "Reset the environment to a fresh start (determined by SEED).
   Calls env.reset(seed=SEED)."
  (obs->array (car (py4cl2:pymethod env "reset" :seed seed))))

(defun step (env action)
  "Interact with the environment by taking action ACTION.
   Calls env.step(action) in Python."
  (destructuring-bind (obs rew term trunc info)
      (py4cl2:pymethod env "step" action)
    (values (obs->array obs) rew term trunc info)))

(defun rollout (root-team environment-name seed &key (video-path nil))
  "Runs a complete episode against a Gymnasium environment with name ENVIRONMENT-NAME
   using ROOT-TEAM as the policy. Specify a SEED to control for the starting state.
   Specify a filename for video-path if you want to record a video of the agent."
  (py4cl2:pyexec "import gymnasium as gym")
  (let* ((env (make environment-name :video-path video-path))
	 (episode-reward 0.0)
	 (observation (reset env seed)))
    (unwind-protect
	 (loop for timestep from 0
	       do (let ((action (cl-tpg:execute-team root-team observation)))
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
       
		  
		  
    
	 
  



