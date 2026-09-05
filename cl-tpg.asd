(eval-when (:compile-toplevel :load-toplevel :execute)
  (let* ((root
           (make-pathname :name nil :type nil :defaults *load-truename*))
         (cage2-system
           (merge-pathnames "vendor/cage2-mini/cage2-mini.asd" root)))
    (unless (probe-file cage2-system)
      (error
       "Native cage2-mini is missing. Clone BES with --recurse-submodules or run: git submodule update --init --recursive"))
    (asdf:load-asd cage2-system)))

(asdf:defsystem "cl-tpg"
  :description "A Common Lisp implementation of Tangled Program Graphs"
  :version "0.4"
  :author "Bryce MacInnis"
  :license "GPL-3"
  :depends-on ("usocket" "alexandria" "bordeaux-threads" "lparallel"
               "py4cl2" "cage2-mini")
  :components ((:file "package")
	       (:file "helpers")
	       (:file "globals")
	       (:file "instruction")
	       (:file "program")
	       (:file "action")
	       (:file "learner")
	       (:file "team")
		   (:file "checkpoint")
		   (:file "validation")
	       (:file "mutation")
	       (:file "dataset")
	       (:file "migration")
               (:file "networking")
	       (:file "gym")
	       (:file "main")))
