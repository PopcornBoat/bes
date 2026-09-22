(require :asdf)

(let* ((script (or *load-truename* *compile-file-truename*))
       (root (uiop:pathname-parent-directory-pathname
              (uiop:pathname-directory-pathname script))))
  (asdf:load-asd (merge-pathnames #P"cl-tpg.asd" root))
  (asdf:load-system :cl-tpg))

(let ((arguments (uiop:command-line-arguments)))
  (unless (<= 1 (length arguments) 2)
    (format *error-output*
            "Usage: sbcl --script scripts/analyze-behavioral-locality.lisp JOURNAL [REPORT.md]~%")
    (uiop:quit 2))
  (let ((input (first arguments))
        (output (second arguments)))
    (unless (probe-file input)
      (format *error-output* "Behavioral-locality journal not found: ~A~%" input)
      (uiop:quit 2))
    (cl-tpg::analyze-behavioral-locality-journal
     input :output-path output)
    (when output
      (format t "Behavioral-locality report written: ~A~%" output))))
