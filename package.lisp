(defpackage :cl-tpg
	    (:use :cl)
	    (:import-from :lparallel
			  #:*kernel*
			  #:make-kernel
			  #:pmap
			  #:end-kernel)
	    (:export :start-server :stop-server :execute-team
                     :+cage2-evaluation-seed+))

(defpackage :cl-gym
  (:use :cl :cl-tpg)
  (:shadow #:step)
  (:export #:rollout #:obs->array #:make #:reset #:step
           #:cage2-environment-p #:seed-python-random
           #:cl-gym-validate-team)
  (:documentation "A Gymnasium wrapper for CL-TPG."))

(in-package :cl-tpg)
       
