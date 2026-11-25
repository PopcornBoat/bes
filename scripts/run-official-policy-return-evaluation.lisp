(require :asdf)

(let* ((script-directory
         (uiop:pathname-directory-pathname *load-truename*))
       (repository-directory
         (uiop:pathname-parent-directory-pathname script-directory))
       (system-file
         (merge-pathnames "cl-tpg.asd" repository-directory))
       (arguments (uiop:command-line-arguments)))
  (unless (= (length arguments) 1)
    (error "Expected one policy-return request path, got ~S." arguments))
  (asdf:load-asd system-file)
  (asdf:load-system :cl-tpg)
  (handler-case
      (progn
        (funcall
         (intern "RUN-OFFICIAL-POLICY-RETURN-EVALUATION" :cl-tpg)
         (first arguments))
        (uiop:quit 0))
    (error (condition)
      (format *error-output*
              "~&Official policy-return evaluator failed: ~A~%"
              condition)
      (uiop:quit 1))))
