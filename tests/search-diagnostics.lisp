;;; Focused checks for retained search and telemetry diagnostics.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(setf cl-tpg::*checkpoint-directory* nil
      cl-tpg::*generation* 3337
      cl-tpg::*last-search-failure* nil
      cl-tpg::*last-telemetry-error* nil)

(cl-tpg::call-with-recorded-search-failure
 "diagnostic-test"
 (lambda ()
   (error "sentinel failure")))

(assert (equal (getf cl-tpg::*last-search-failure* :message)
               "sentinel failure"))
(assert (= (getf cl-tpg::*last-search-failure* :generation) 3337))
(assert (> (length (getf cl-tpg::*last-search-failure* :backtrace)) 0))

(let ((original-connect (symbol-function 'usocket:socket-connect)))
  (unwind-protect
       (progn
         (setf (symbol-function 'usocket:socket-connect)
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (error "telemetry sentinel")))
         (assert (null (cl-tpg::notify-telemetry "test payload")))
         (assert (equal (getf cl-tpg::*last-telemetry-error* :message)
                        "telemetry sentinel")))
    (setf (symbol-function 'usocket:socket-connect) original-connect)))

(format t "Search diagnostic checks passed.~%")
