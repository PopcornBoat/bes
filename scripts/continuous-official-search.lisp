(in-package :cl-tpg)

(defun continuous-read (path)
  (with-open-file (stream path)
    (let ((*read-eval* nil)) (read stream))))

(defun continuous-row (stream &rest values)
  (format stream "~{~A~^~C~}~%"
          (loop for value in values for first = t then nil
                append (if first (list value) (list #\Tab value)))))

(defun continuous-obs (text)
  (assert (= 62 (length text)))
  (make-array 62 :element-type 'double-float
              :initial-contents (map 'list (lambda (c) (coerce (digit-char-p c) 'double-float)) text)))

(defun continuous-encoded (observation)
  (map 'string (lambda (x) (digit-char (truncate x))) observation))

(defun continuous-profile (opponent)
  (ecase (intern (string-upcase opponent) :keyword)
    (:b_line :bline-cardiff-global)
    (:meander :meander-cardiff-global)))

(defun continuous-call (opponent function)
  (let ((*num-observations* 62) (*num-actions* 36)
        (*factored-actions-enabled* t) (*terminal-action-format* :target-response-36)
        (*read-only-register-profile* :cage2-categorical-v1)
        (*instruction-set-profile* :reduced-eq)
        (*cage2-opening-mode* :fixed) (*decoy-order-mode* :fixed)
        (*cage2-controller-decoy-order-profile* (continuous-profile opponent))
        (*cage2-decoy-resolution* :profile)
        (*recurrent-policy-enabled* nil) (*hamming-space-enabled* nil)
        (*teams* nil) (*team-id-generator* (make-counter))
        (*learner-id-generator* (make-counter)))
    (funcall function)))

(defun continuous-load (path)
  (multiple-value-bind (team fitness metadata) (load-best-team path)
    (declare (ignore fitness))
    (multiple-value-bind (format instructions registers)
        (checkpoint-execution-profile metadata "Continuous search")
      (assert (and (eq format :target-response-36) (= (getf metadata :num-observations) 62)
                   (not (getf metadata :recurrent-policy-enabled))))
      (assert (eq registers *read-only-register-profile*))
      (assert (eq instructions *instruction-set-profile*)))
    (ensure-team-observation-compatible team 62)
    team))

(defun continuous-ranking (team observation)
  (mapcar #'semantic-action-category-pair (execute-team-semantic-ranked team observation)))

(defun continuous-path (team observation)
  "Read-only trace of the native deterministic Top-1 path."
  (let ((current team) (visited nil) (path nil))
    (loop
      (assert (not (member current visited :test #'eq)))
      (push current visited)
      (assert (< (length visited) +max-team-traversal-depth+))
      (let* ((ranked (stable-sort
                      (loop for learner in (team-learners current)
                            collect (cons learner (bid learner observation)))
                      #'> :key #'cdr))
             (winner (caar ranked))
             (score (cdar ranked))
             (runner (and (cdr ranked) (cdadr ranked)))
             (action (learner-action winner)))
        (push (list (team-id current) (learner-id winner) score
                    (and runner (- score runner))) path)
        (if (eq (action-type action) :atomic)
            (return (let ((*print-pretty* nil)) (format nil "~S" (nreverse path))))
            (setf current (action-action action)))))))

(defun continuous-episode (team controller environment horizon seed stream label)
  (py4cl2:pycall "_continuous_seed")
  (let ((env (cl-gym::make environment))
        (reward 0d0))
    (unwind-protect
         (progn
           (cl-gym::configure-cage2-controller-option-orders env controller)
           (cage2-controller-reset controller)
           (call-with-fresh-policy-episode
            (lambda ()
              (let ((raw (cl-gym::reset env seed)))
                (dotimes (step horizon)
                  (let* ((observation (cage2-controller-observe controller raw))
                         (ranking (if (< step 3) (aref +cage2-fixed-opening-rankings+ step)
                                      (continuous-ranking team observation)))
                         (decision (cage2-controller-resolve-pair-ranking controller ranking))
                         (pair (semantic-action-category-pair (cage2-controller-decision-semantic-action decision)))
                         (mask (cage2-controller-decoy-mask controller)))
                    (multiple-value-bind (next delta terminated truncated info)
                        (cl-gym::step env (cl-gym::controller-decision->cage2-input decision))
                      (cl-gym::commit-controller-step controller decision info)
                      (let* ((restore (if (= (second pair) 2) 1 0))
                             (loss (py4cl2:pycall "_continuous_loss" env delta restore)))
                        (continuous-row stream horizon seed label step (continuous-encoded observation)
                                        mask (cage2-controller-decision-concrete-action decision) delta restore
                                        (format nil "~D:~D" (first pair) (second pair))
                                        (format nil "~{~{~D:~D~}~^;~}" ranking) loss
                                        (if (< step 3) "OPENING" (continuous-path team observation))))
                      (incf reward delta)
                      (setf raw next)
                      (when (or terminated truncated) (assert (= horizon (1+ step)))))))))))
      (py4cl2:pymethod env "close"))
    reward))

(defun continuous-evaluate (opponent arms requests output)
  (continuous-call
   opponent
   (lambda ()
     (let ((teams (loop for (name path) in (continuous-read arms)
                        collect (list name (continuous-load path))))
           (controller (make-cage2-controller)))
       (py4cl2:pyexec
        "import gymnasium as gym
import cage2_bridge
import random
import numpy as np
import json
def _continuous_seed():
    random.seed(153)
    np.random.seed(153)
def _continuous_loss(env, reward, restore):
    parts = env.unwrapped.env.get_reward_breakdown('Blue')
    assert abs(sum(sum(x) for x in parts.values()) - restore - reward) < 1e-7
    return json.dumps(parts,sort_keys=True,separators=(',',':'))")
       (with-open-file (returns (merge-pathnames "returns.tsv" output) :direction :output :if-exists :error)
         (with-open-file (trace (merge-pathnames "trace.tsv" output) :direction :output :if-exists :error)
           (continuous-row returns "horizon" "seed" "arm" "return")
           (continuous-row trace "horizon" "seed" "arm" "step" "obs" "mask" "concrete" "reward"
                           "restore" "pair" "top8" "host" "native_path")
           (loop for (horizon seed) in (continuous-read requests) for n from 1
                 for environment = (cage2-validation-environment-name opponent horizon)
                 do (dolist (item teams)
                      (destructuring-bind (name team) item
                        (continuous-row returns horizon seed name
                                        (continuous-episode team controller environment horizon seed trace name))))
                    (when (or (= n 1) (zerop (mod n 4)))
                      (finish-output returns)
                      (finish-output trace)
                      (format t "~&PROGRESS ~A completed=~D~%" opponent n)
                      (finish-output)))))))))

(defun continuous-instruction (dest op t1 v1 t2 v2)
  (%make-instruction :dest dest :op op :src1-type t1 :src1-val (coerce v1 'double-float)
                     :src2-type t2 :src2-val (coerce v2 'double-float) :arity 2))

(defun continuous-program (instructions)
  (make-program :instructions (make-array (length instructions) :adjustable t :fill-pointer t
                                         :initial-contents instructions)))

(defun continuous-constant (score)
  (continuous-program (list (continuous-instruction 0 :add :const score :const 0))))

(defun continuous-terminal (ranking)
  (make-team :type :internal
             :learners (loop for (target response) in ranking for rank from 0 collect
                             (make-learner
                              :program (continuous-constant (- 16 rank))
                              :action (make-action :type :atomic :action
                                                   (make-target-response-36-action :target target :response response))))))

(defun continuous-gate (observation)
  (continuous-program
   (cons (continuous-instruction 0 :add :const 1 :const 0)
         (loop for char across observation for i from 0 append
               (list (continuous-instruction 1 :eq :obs i :const (digit-char-p char))
                     (continuous-instruction 0 :mul :reg 0 :reg 1))))))

(defun continuous-write (team path opponent)
  (write-best-team-checkpoint
   team nil path :gym-environment-name (cage2-validation-environment-name opponent 100)
   :fitness-evaluation-protocol :continuous-official-candidate
   :num-observations 62 :decoy-order-mode :fixed :cage2-opening-mode :fixed
   :recurrent-policy-enabled nil))

(defun continuous-build (opponent incumbent request output)
  (continuous-call
   opponent
   (lambda ()
     (dolist (spec (continuous-read request))
       (destructuring-bind (name kind seed observations alternative) spec
         (let* ((source (continuous-load incumbent))
                (original (loop for text in observations collect
                                (list text (continuous-ranking source (continuous-obs text)))))
                (*random-state* (sb-ext:seed-random-state seed))
                (*teams* (closure source))
                (root source))
           (cond
             ((string= kind "specialist")
              (setf root
                    (make-team
                     :type :root :learners
                     (append
                      (loop for (text native) in original
                            for ranking = (cons alternative (subseq (remove alternative native :test #'equal)
                                                                   0 (min 7 (count-if-not
                                                                             (lambda (x) (equal x alternative)) native))))
                            collect (make-learner :program (continuous-gate text)
                                                  :action (make-action :type :reference
                                                                       :action (continuous-terminal ranking))))
                      (list (make-learner :program (continuous-constant 0.5d0)
                                          :action (make-action :type :reference :action source)))))))
             (t
              (let* ((*max-program-size* 256) (*init-program-size* 8)
                     (*instruction-mutation-mode* :field-local)
                     (*p-add-instr* 0.2d0) (*p-del-instr* 0.1d0)
                     (*p-swap-instrs* 0.1d0) (*p-mut-constant* 0.5d0)
                     (*p-mut-constant-sign* 0.1d0)
                     (*p-add* 0.1d0) (*p-del* 0.1d0) (*p-mut* 1d0) (*p-act* 0.1d0)
                     (*p-swap* 0.1d0) (*max-num-learners* 32)
                     (team (random-choice (closure source)))
                     (learner (if (string= kind "active-instruction")
                                  (nth-value 0 (execute-team-to-terminal source (continuous-obs (first observations))))
                                  (random-choice (team-learners team)))))
                (cond
                  ((string= kind "team") (mutate-team team))
                  ((string= kind "terminal")
                   (when (eq (action-type (learner-action learner)) :atomic)
                     (setf (action-action (learner-action learner))
                           (mutated-atomic-action-value (action-action (learner-action learner))))))
                  (t (mutate-program-field-local (learner-program learner)))))))
           (dolist (node (closure root))
             (setf (team-type node) (if (eq node root) :root :internal)))
           (ensure-team-observation-compatible root 62)
           (let* ((path (merge-pathnames (format nil "~A.lisp" name) output)))
             (continuous-write root path opponent)
             (let ((restored (continuous-load path)))
               (dolist (item original)
                 (destructuring-bind (text native) item
                   (let ((actual (continuous-ranking restored (continuous-obs text))))
                     (when (string= kind "specialist")
                       (assert (equal (first actual) alternative)))
                     (assert (equal actual (continuous-ranking root (continuous-obs text)))))))))
           (format t "~&BUILT ~A kind=~A~%" name kind)
           (finish-output)))))))


(defun continuous-contract (opponent path)
  (continuous-call opponent
   (lambda ()
     (let ((controller (make-cage2-controller)))
       (with-open-file (out path :direction :output :if-exists :supersede)
         (continuous-row out "target" "option" "concrete" "mask")
         (dolist (pair (cage2-controller-decoy-schedule controller))
           (destructuring-bind (target option) pair
             (continuous-row out target option
                             (cage2-controller-concrete-action controller target 3 option)
                             (ash 1 (+ (* (1- target) 8) option))))))))))

(defun continuous-probe (opponent checkpoint request output)
  (continuous-call opponent
   (lambda ()
     (let ((team (continuous-load checkpoint)) (controller (make-cage2-controller)))
       (with-open-file (out output :direction :output :if-exists :error)
         (continuous-row out "obs" "mask" "pair" "concrete" "top8")
         (dolist (item (continuous-read request))
           (destructuring-bind (text mask) item
             (let* ((ranking (continuous-ranking team (continuous-obs text))))
               (setf (cage2-controller-decoy-mask controller) mask)
               (let* ((decision (cage2-controller-resolve-pair-ranking controller ranking))
                      (pair (semantic-action-category-pair
                             (cage2-controller-decision-semantic-action decision))))
                 (continuous-row out text mask (format nil "~D:~D" (first pair) (second pair))
                                 (cage2-controller-decision-concrete-action decision)
                                 (format nil "~{~{~D:~D~}~^;~}" ranking)))))))))))
