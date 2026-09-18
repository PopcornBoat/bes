(require :asdf)

(let* ((script-directory
         (uiop:pathname-directory-pathname *load-truename*))
       (repository-directory
         (uiop:pathname-parent-directory-pathname script-directory))
       (system-file
         (merge-pathnames "cl-tpg.asd" repository-directory))
       (arguments (uiop:command-line-arguments)))
  (unless (= (length arguments) 1)
    (error "Expected one staged-evaluation request path, got ~S." arguments))
  (asdf:load-asd system-file)
  (asdf:load-system :cl-tpg)
  (handler-case
      (progn
        ;; Resolve after ASDF has created the package; the Lisp reader parses
        ;; this complete form before any of its load calls execute.
        (funcall (intern "RUN-ONLINE-CANDIDATE-EVALUATION" :cl-tpg)
                 (first arguments))
        (uiop:quit 0))
    (error (condition)
      (format *error-output*
              "~&Independent online evaluator failed: ~A~%"
              condition)
      (uiop:quit 1))))
