(defpackage :bes
	    (:use :cl)
	    (:import-from :lparallel
			  #:*kernel*
			  #:make-kernel
			  #:pmap
			  #:end-kernel)
	    (:export :start-server :stop-server :execute-team))

(defpackage :bes-gym
  (:use :cl :bes)
  (:shadow #:step)
  (:export #:rollout)
  (:documentation "A Gymnasium wrapper for BES."))

(in-package :bes)
       
