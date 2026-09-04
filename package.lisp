(defpackage :cl-tpg
	    (:use :cl)
	    (:import-from :lparallel
			  #:*kernel*
			  #:make-kernel
			  #:pmap
			  #:end-kernel)
	    (:export :start-server
                     :stop-server
                     :execute-team
                     :execute-team-semantic
                     :semantic-action
                     :semantic-action-target
                     :semantic-action-response
                     :semantic-action-option
                     :+global-target+
                     :+num-semantic-targets+
                     :+cage2-evaluation-seed+))

(defpackage :cl-gym
  (:use :cl :cl-tpg)
  (:shadow #:step)
  (:export #:rollout
           #:obs->array
           #:make
           #:reset
           #:step
           #:cage2-environment-p
           #:seed-python-random
           #:cl-gym-validate-team)
  (:documentation "A Gymnasium wrapper for CL-TPG."))

(in-package :cl-tpg)
       
