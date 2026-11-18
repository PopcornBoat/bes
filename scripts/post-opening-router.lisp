(in-package :cl-tpg)

(defconstant +post-opening-router-dimension+ 62)
(defconstant +post-opening-router-decision+ 3)
(defparameter +post-opening-router-labels+ #(:b-line :meander :sleep))

(defstruct post-opening-router
  team
  selected)

(defun reset-post-opening-router (router)
  (setf (post-opening-router-selected router) nil)
  router)

(defun load-post-opening-router (checkpoint)
  (let ((*teams* nil)
        (*loaded-best-team* nil) (*loaded-best-fitness* nil)
        (*loaded-checkpoint-metadata* nil))
    (multiple-value-bind (team fitness metadata) (load-best-team checkpoint)
      (declare (ignore fitness))
      (assert (eq :cage2-post-opening-opponent-classifier (getf metadata :fitness-evaluation-protocol)))
      (assert (= +post-opening-router-dimension+ (getf metadata :num-observations)))
      (assert (not (getf metadata :recurrent-policy-enabled)))
      (ensure-team-observation-compatible team +post-opening-router-dimension+)
      (assert (equal '(0 1 2)
                     (sort
                      (loop for learner in (team-learners team)
                            for action = (learner-action learner)
                            do (assert (eq (action-type action) :atomic))
                            collect (action-action action))
                      #'<)))
      (make-post-opening-router :team team))))

(defun post-opening-route (router controller policy-observation)
  "Return NIL during probes, then latch one opponent label for the episode.

Call after Controller has consumed the current wrapper observation and
before committing the current concrete action."
  (or (post-opening-router-selected router)
      (let ((step (cage2-controller-step controller)))
        (cond
          ((< step +post-opening-router-decision+) nil)
          ((= step +post-opening-router-decision+)
           (assert (typep policy-observation '(simple-array double-float (62))))
           (let ((*factored-actions-enabled* nil)
                 (*recurrent-policy-enabled* nil)
                 (*policy-episode-registers* nil)
                 (*hamming-space-enabled* nil))
             (setf (post-opening-router-selected router)
                   (aref +post-opening-router-labels+
                         (execute-team (post-opening-router-team router) policy-observation)))))
          (t (error "Opponent router missed the post-opening decision."))))))

(defun post-opening-router-categories (encoded)
  (assert (= (length encoded) +post-opening-router-dimension+))
  (make-array +post-opening-router-dimension+ :element-type 'double-float
              :initial-contents (map 'list (lambda (c) (coerce (digit-char-p c) 'double-float)) encoded)))

(defun validate-post-opening-router (checkpoint request output)
  (let ((router (load-post-opening-router checkpoint))
        (controller (make-cage2-controller :decoy-order-profile :bline-cardiff-global)))
    (with-open-file (stream output :direction :output :if-exists :error)
      (format stream "seed~Cexpected~Cpredicted~Csame-route-after-decision~%" #\Tab #\Tab #\Tab)
      (dolist (episode (with-open-file (in request)
                         (let ((*read-eval* nil)) (read in))))
        (destructuring-bind (seed expected snapshots) episode
          (assert (= (length snapshots) 4))
          (cage2-controller-reset controller)
          (reset-post-opening-router router)
          (loop for snapshot in snapshots for i from 0
                for input = (cage2-controller-observe controller (post-opening-router-categories snapshot))
                do (assert (equalp input (post-opening-router-categories snapshot)))
                   (cond
                     ((< i 3)
                      (assert (null (post-opening-route router controller input)))
                      (let ((decision (cage2-controller-resolve-pair-ranking
                                       controller (aref +cage2-fixed-opening-rankings+ i))))
                        (assert (= (nth i '(51 116 55))
                                   (cage2-controller-decision-concrete-action decision)))
                        (cage2-controller-commit-decision controller decision)))
                     (t
                      (let* ((first (post-opening-route router controller input))
                             (later (progn
                                      (cage2-controller-commit-decision
                                       controller (make-cage2-controller-monitor-decision controller))
                                      ;; A subsequent call reuses the latch even with no detector input.
                                      (post-opening-route router controller nil))))
                        (assert (eq first later))
                        (format stream "~D~C~(~A~)~C~(~A~)~Ct~%" seed #\Tab
                                (aref +post-opening-router-labels+ expected) #\Tab first #\Tab))))))))))

