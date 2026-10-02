(require :asdf)

(let* ((script (or *load-truename* *compile-file-truename*))
       (root (uiop:pathname-parent-directory-pathname
              (uiop:pathname-directory-pathname script))))
  (asdf:load-asd (merge-pathnames #P"cl-tpg.asd" root))
  (asdf:load-system :cl-tpg))

(defun parse-output-registers (text)
  (if text
      (mapcar #'parse-integer
              (uiop:split-string text :separator '(#\,)))
      (list cl-tpg::+bid-register+)))

(let ((arguments (uiop:command-line-arguments)))
  (unless (<= 1 (length arguments) 3)
    (format *error-output*
            "Usage: sbcl --script scripts/analyze-effective-code.lisp CHECKPOINT [REPORT.txt] [OUTPUT-REGISTERS]~%")
    (uiop:quit 2))
  (destructuring-bind (checkpoint &optional report-path register-text)
      arguments
    (unless (probe-file checkpoint)
      (format *error-output* "Checkpoint not found: ~A~%" checkpoint)
      (uiop:quit 2))
    (multiple-value-bind (team fitness metadata)
        (cl-tpg::load-best-team checkpoint)
      (let ((output-registers (parse-output-registers register-text)))
        (if report-path
            (progn
              (ensure-directories-exist report-path)
              (with-open-file
                  (stream report-path
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
                (cl-tpg:write-effective-code-report
                 team
                 :stream stream
                 :checkpoint-path checkpoint
                 :fitness fitness
                 :metadata metadata
                 :output-registers output-registers))
              (format t "Effective-code report written: ~A~%" report-path))
            (cl-tpg:write-effective-code-report
             team
             :checkpoint-path checkpoint
             :fitness fitness
             :metadata metadata
             :output-registers output-registers))))))
