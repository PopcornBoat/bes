(in-package :cl-tpg)

(defstruct dispatch-expert
  team controller-template instruction-profile register-profile ranking-override)

(defun load-dispatch-expert (checkpoint expected-decoy-profile &optional (expected-input-size 62))
  (let ((*loaded-best-team* nil)
        (*loaded-best-fitness* nil)
        (*loaded-checkpoint-metadata* nil))
    (multiple-value-bind (team fitness metadata) (load-best-team checkpoint)
      (declare (ignore fitness))
      (multiple-value-bind (format instructions registers)
          (checkpoint-execution-profile metadata "Dispatch expert")
        (assert (eq format :target-response-36))
        (assert (= (getf metadata :num-observations) expected-input-size))
        (assert (not (getf metadata :recurrent-policy-enabled)))
        (assert (eq (getf metadata :decoy-order-mode) :fixed))
        (assert (eq (getf metadata :cage2-controller-decoy-order-profile)
                    expected-decoy-profile))
        (ensure-team-observation-compatible team expected-input-size)
        (make-dispatch-expert
         :team team :instruction-profile instructions :register-profile registers
         :controller-template (make-cage2-controller
                               :decoy-order-profile expected-decoy-profile))))))

(defun dispatch-install-expert-profile (controller env expert)
  ;; Replace the scheduling configuration in place. Scan, step and used
  ;; Decoy state belong to the same episode and remain in CONTROLLER.
  (let ((template (dispatch-expert-controller-template expert)))
    (setf (cage2-controller-decoy-order-profile controller)
          (cage2-controller-decoy-order-profile template)
          (cage2-controller-option-orders controller)
          (cage2-controller-option-orders template)
          (cage2-controller-decoy-schedule controller)
          (cage2-controller-decoy-schedule template)))
  (cl-gym::configure-cage2-controller-option-orders env controller))

(defun dispatch-expert-decision (expert controller input previous)
  (let ((*factored-actions-enabled* t)
        (*terminal-action-format* :target-response-36)
        (*instruction-set-profile* (dispatch-expert-instruction-profile expert))
        (*read-only-register-profile* (dispatch-expert-register-profile expert)))
    (let ((ranking (execute-team-semantic-ranked (dispatch-expert-team expert) input))
          (override (dispatch-expert-ranking-override expert)))
      (if override
          (cage2-controller-resolve-pair-ranking
           controller (funcall override (mapcar #'semantic-action-category-pair ranking)
                               input controller previous))
          (cage2-controller-resolve-ranking controller ranking)))))

(defun dispatch-sleep-step (env controller)
  ;; The official Sleep action is concrete 0. The bridge's (GLOBAL 0)
  ;; resolves to Monitor (1), so use the underlying ChallengeWrapper.
  (destructuring-bind (observation reward done)
      (py4cl2:pycall "_bes_dispatch_sleep" env)
    (incf (cage2-controller-step controller))
    (values (cl-gym::normalize-obs observation) reward done)))

(defun dispatch-observation-string (observation)
  (map 'string (lambda (value) (digit-char (truncate value))) observation))

(defun dispatch-episode (router bline meander environment horizon seed)
  (py4cl2:pycall "_bes_dispatch_factory_rng")
  (let ((env (cl-gym::make environment))
        (controller (make-cage2-controller :decoy-order-profile :heuristic)))
    (unwind-protect
         (progn
           (cl-gym::configure-cage2-controller-option-orders env controller)
           (reset-post-opening-router router)
           (let ((raw (cl-gym::reset env seed))
                 (reward 0d0)
                 (route nil)
                 (expert nil)
                 (feature-snapshot nil)
                 (handoff-mask nil)
                 (profile nil)
                 (fourth-action nil)
                 (actions nil)
                 (previous nil))
             (dotimes (step horizon)
               (let* ((input (cage2-controller-observe controller raw))
                      (opening (when (< step +post-opening-router-decision+)
                                 (aref +cage2-fixed-opening-rankings+ step))))
                 (assert (= step (cage2-controller-step controller)))
                 (when (= step +post-opening-router-decision+)
                   (assert (null (post-opening-router-selected router)))
                   (setf route (post-opening-route router controller input)
                         expert (ecase route (:b-line bline) (:meander meander) (:sleep nil))
                         feature-snapshot (dispatch-observation-string input)
                         handoff-mask (cage2-controller-decoy-mask controller))
                   (when expert
                     (dispatch-install-expert-profile controller env expert))
                   (setf profile (if expert (cage2-controller-decoy-order-profile controller)
                                     :sleep))
                   (assert (= handoff-mask (cage2-controller-decoy-mask controller))))
                 (if (eq route :sleep)
                     (multiple-value-bind (next delta done) (dispatch-sleep-step env controller)
                       (when done (assert (= (1+ step) horizon)))
                       (setf raw next)
                       (push 0 actions)
                       (incf reward delta))
                     (let* ((decision (if opening
                                          (cage2-controller-resolve-pair-ranking controller opening)
                                          (dispatch-expert-decision expert controller input previous)))
                            (concrete (cage2-controller-decision-concrete-action decision)))
                       (when opening
                         (assert (= concrete (nth step '(51 116 55)))))
                       (multiple-value-bind (next delta terminated truncated info)
                           (cl-gym::step env (cl-gym::controller-decision->cage2-input decision))
                         (when (or terminated truncated) (assert (= (1+ step) horizon)))
                         (when (= (1+ step) horizon) (assert (or terminated truncated)))
                         (cl-gym::commit-controller-step controller decision info)
                         (setf raw next)
                         (push concrete actions)
                         (incf reward delta))))
                 (when (= step +post-opening-router-decision+)
                   (setf fourth-action (first actions)))
                 (setf previous input)))
             (assert (= horizon (cage2-controller-step controller)))
             (assert (eq route (post-opening-route router controller nil)))
             (values reward route profile feature-snapshot handoff-mask fourth-action
                     (nreverse actions))))
      (py4cl2:pymethod env "close"))))

(defun dispatch-full-cell (router-file bline-file meander-file red horizon requests output
                           &key (bline-profile :heuristic) (meander-profile :meander-heuristic)
                                bline-override meander-override)
  (let* ((*teams* nil)
         (*team-id-generator* (make-counter))
         (*learner-id-generator* (make-counter))
         (*num-observations* 62)
         (*num-actions* 36)
         (*factored-actions-enabled* t)
         (*terminal-action-format* :target-response-36)
         (*cage2-opening-mode* :fixed)
         (*decoy-order-mode* :fixed)
         (*cage2-decoy-resolution* :profile)
         (*recurrent-policy-enabled* nil)
         (*policy-episode-registers* nil)
         (*hamming-space-enabled* nil)
         (router (load-post-opening-router router-file))
         (bline (load-dispatch-expert bline-file bline-profile))
         (meander (load-dispatch-expert meander-file meander-profile))
         ;; RED is used only to construct the test environment and label logs.
         (environment (cage2-validation-environment-name red horizon))
         (cases (with-open-file (stream requests)
                  (let ((*read-eval* nil)) (read stream)))))
    (setf (dispatch-expert-ranking-override bline) bline-override
          (dispatch-expert-ranking-override meander) meander-override)
    (py4cl2:pyexec
     "import gymnasium as gym
import random
import numpy as np
import cage2_bridge
def _bes_dispatch_factory_rng():
    random.seed(153)
    np.random.seed(153)
def _bes_dispatch_sleep(env):
    obs, reward, done, _ = env.unwrapped.env.step(0)
    return (obs.tolist(), float(reward), bool(done))")
    (with-open-file (stream output :direction :output :if-exists :error)
      (format stream "episode~Cseed~Croute~Cprofile~Creturn~Csteps~Cobs62_j3~Cdecoy_mask_j3~Cfourth_action~Cactions~%"
              #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab)
      (loop for (index seed) in cases for n from 1
            do (multiple-value-bind (score route profile obs mask fourth actions)
                   (dispatch-episode router bline meander environment horizon seed)
                 (format stream "~D~C~D~C~(~A~)~C~(~A~)~C~,10F~C~D~C~A~C~D~C~D~C~{~D~^,~}~%"
                         index #\Tab seed #\Tab route #\Tab profile #\Tab score #\Tab
                         horizon #\Tab obs #\Tab mask #\Tab fourth #\Tab actions))
               (when (or (= n 1) (zerop (mod n 25)) (= n (length cases)))
                 (finish-output stream)
                 (format t "~&PROGRESS ~A ~D ~D/~D~%" red horizon n (length cases))
                 (finish-output))))))


