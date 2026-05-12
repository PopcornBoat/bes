(asdf:defsystem "cl-tpg"
  :description "A Common Lisp implementation of Tangled Program Graphs"
  :version "0.4"
  :author "Bryce MacInnis"
  :license "GPL-3"
  :depends-on ("usocket" "alexandria" "bordeaux-threads" "lparallel" "py4cl2")
  :components ((:file "package")
	       (:file "helpers")
	       (:file "globals")
	       (:file "instruction")
	       (:file "program")
	       (:file "action")
	       (:file "learner")
	       (:file "team")
	       (:file "mutation")
	       (:file "dataset")
	       (:file "migration")
               (:file "networking")
	       (:file "gym")
	       (:file "main")))
