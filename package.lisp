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
                     :execute-team-semantic-ranked
                     :semantic-action
                     :semantic-action-target
                     :semantic-action-response
                     :semantic-action-option
                     :make-cage2-controller
                     :cage2-controller-reset
                     :cage2-controller-observe
                     :cage2-controller-resolve-ranking
                     :cage2-controller-commit-decision
                     :cage2-controller-decision
                     :cage2-controller-decision-semantic-action
                     :cage2-controller-decision-concrete-action
                     :cage2-controller-decision-rank
                     :cage2-controller-decision-option
                     :cage2-controller-decision-fallback-p
                     :cage2-bline-heuristic-ranking
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
       
