;;;; socket-utils.lisp

(in-package :bes)

(defparameter *socket* nil)
(defparameter *stream* nil)

(defun socket-request-short (payload &key (host "127.0.0.1") (port 5005))
  "short connect:  connect -> send -> receive -> close."
  (let* ((socket (usocket:socket-connect host port))
         (stream (usocket:socket-stream socket)))
    (unwind-protect
         (progn
           (format stream "~A~%" payload)
           (finish-output stream)
           (read-line stream))
      (usocket:socket-close socket))))

(defun connect-server (&key (host "127.0.0.1") (port 5005))
  "persistent connect to Python server."
  (when *socket*
    (close-server))
  (setf *socket* (usocket:socket-connect host port))
  (setf *stream* (usocket:socket-stream *socket*))
  t)

(defun close-server ()
  "close persistant connection."
  (when *socket*
    (ignore-errors (usocket:socket-close *socket*)))
  (setf *socket* nil
        *stream* nil)
  t)

(defun socket-request-long (payload)
  "persistant connection: use an open socket to connect."
  (unless *stream*
    (error "No active socket connection. Call CONNECT-SERVER first."))
  (format *stream* "~A~%" payload)
  (finish-output *stream*)
  (read-line *stream*))

(defun ping-server-short ()
  (socket-request-short "{\"type\":\"ping\"}"))

(defun ping-server-long ()
  (socket-request-long "{\"type\":\"ping\"}"))
