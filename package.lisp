(defpackage :cl-tpg
	    (:use :cl)
	    (:import-from :lparallel
			  #:*kernel*
			  #:make-kernel
			  #:pmap
			  #:end-kernel)
	    (:export :start-server :stop-server :execute-team))

(defpackage :cl-gym
  (:use :cl :cl-tpg)
  (:shadow #:step)
  (:export #:rollout)
  (:documentation "A Gymnasium wrapper for CL-TPG."))

(in-package :cl-tpg)
       
