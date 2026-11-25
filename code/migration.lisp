(in-package :cl-tpg)

(defun make-migration-buffer ()
  "Encapsulate the migration buffer in a closure."
  (let ((queue '())
	(lock (bt:make-lock "migrant-buffer-lock")))
    (list
     ;; Thread-safe push function
     (lambda (migrant)
       (bt:with-lock-held (lock)
	 (setf queue (nconc queue (list migrant)))))
     ;; Thread-safe pop function
     (lambda ()
       (bt:with-lock-held (lock)
	 (when queue
	   (let ((migrant (car queue)))
	     (setf queue (cdr queue))
	     migrant)))))))

(defparameter *root-migration-buffer* (make-migration-buffer)
  "Thread-safe queue for incoming root teams.")

(defparameter *internal-migration-buffer* (make-migration-buffer)
  "Thread-safe queue for incoming internal teams.")

(defun pop-internal-team ()
  "Pop an internal team from the internal teams buffer."
  (funcall (second *internal-migration-buffer*)))

(defun push-internal-team (team)
  "Push an internal team onto the internal teams buffer."
  (funcall (first *internal-migration-buffer*) team))

(defun pop-root-team ()
  "Pop a root team from the root teams buffer."
  (funcall (second *root-migration-buffer*)))

(defun push-root-team (team)
  "Push a root team onto the root teams migration buffer."
  (funcall (first *root-migration-buffer*) team))
      
