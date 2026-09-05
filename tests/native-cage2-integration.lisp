;;; Standalone native-backend smoke test. It stubs BES policy execution so the
;;; dispatch can be tested without Quicklisp or a Python interpreter.

(defparameter *test-root*
  (merge-pathnames
   "../"
   (make-pathname :name nil :type nil :defaults *load-truename*)))

(load (merge-pathnames
       "vendor/cage2-mini/lisp/load-source.lisp"
       *test-root*))

(defpackage :cl-tpg
  (:use :cl)
  (:export :execute-team
           :execute-team-semantic
           :semantic-action
           :semantic-action-target
           :semantic-action-response
           :semantic-action-option
           :+global-target+
           :+num-semantic-targets+))

(in-package :cl-tpg)

(defconstant +global-target+ 0)
(defconstant +num-semantic-targets+ 11)
(defconstant +cage2-evaluation-seed+ 153)
(defvar *policy-calls* 0)
(defstruct semantic-action target response option)

(defun execute-team (team observation)
  (declare (ignore team observation))
  0)

(defun execute-team-semantic (team observation)
  (declare (ignore team))
  (assert (typep observation '(simple-array double-float (52))))
  (incf *policy-calls*)
  (make-semantic-action :target 0 :response :monitor :option nil))

(defpackage :py4cl2
  (:use :cl)
  (:export :pyexec :pycall :pymethod :pyeval))

(in-package :py4cl2)

(defun python-was-called (&rest arguments)
  (declare (ignore arguments))
  (error "Native CAGE2 unexpectedly called Python"))

(setf (symbol-function 'pyexec) #'python-was-called
      (symbol-function 'pycall) #'python-was-called
      (symbol-function 'pymethod) #'python-was-called
      (symbol-function 'pyeval) #'python-was-called)

(defpackage :cl-gym
  (:use :cl :cl-tpg)
  (:shadow #:step)
  (:export #:rollout #:seed-python-random))

(in-package :cl-user)

(load (merge-pathnames "gym.lisp" *test-root*))

(in-package :cl-tpg)

(defun emit-message (message)
  (declare (ignore message)))

(defun load-best-team (path)
  (declare (ignore path))
  nil)

(in-package :cl-user)

(load (merge-pathnames "validation.lisp" *test-root*))

(defvar *checks* 0)

(defun check (condition description)
  (incf *checks*)
  (unless condition
    (error "Check failed: ~A" description)))

(check (cl-gym::cage2-environment-p "Cage2-b_line-100-v0")
       "official CAGE2 classification")
(check (cl-gym::cage2-environment-p "Cage2Lisp-b_line-100-v0")
       "native CAGE2 classification")
(check (not (cl-gym::lisp-cage2-environment-p "Cage2-b_line-100-v0"))
       "official backend remains non-native")
(check (cl-gym::lisp-cage2-environment-p "Cage2Lisp-b_line-100-v0")
       "native backend recognition")
(check (equal (cl-gym::lisp-cage2-environment-spec
               "Cage2Lisp-meander-50-v0")
              '(:meander 50))
       "native environment parsing")
(check (= (length cl-gym::*lisp-cage2-environments*) 9)
       "all red-agent and validation-step combinations")

(let ((action
        (cl-tpg::make-semantic-action
         :target 5 :response :restore :option nil)))
  (check (= (cl-gym::semantic-action->cage2-id action) 139)
         "semantic action translation"))

(setf cl-tpg::*policy-calls* 0)
(check (= (cl-gym::rollout nil "Cage2Lisp-sleep-30-v0" 153) 0d0)
       "native rollout reward")
(check (= cl-tpg::*policy-calls* 30)
       "native rollout length")

(setf cl-tpg::*policy-calls* 0)
(let ((results
        (cl-tpg::validate-best-team
         "stub-checkpoint"
         :cage2-lisp
         :single-red-100
         :red-agent-name "sleep"
         :episodes 2)))
  (check (= (length results) 2)
         "native validation result and total")
  (check (= cl-tpg::*policy-calls* 200)
         "native validation episode count"))

(format t "~D native BES/CAGE2 integration checks passed.~%" *checks*)
