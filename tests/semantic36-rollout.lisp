;;; Regression checks for the direct Semantic-36 Controller rollout boundary.

(in-package :cl-user)

(defvar *semantic36-rollout-checks* 0)

(defun check-semantic36-rollout (condition description)
  (incf *semantic36-rollout-checks*)
  (unless condition
    (error "Semantic-36 rollout check failed: ~A" description)))

(let ((cl-tpg::*terminal-action-format* :factored))
  (cl-tpg::configure-cage2-terminal-action-format 36)
  (check-semantic36-rollout
   (eq cl-tpg::*terminal-action-format* :target-response-36)
   "36 actions selects the direct target/response genotype")
  (cl-tpg::configure-cage2-terminal-action-format 11)
  (check-semantic36-rollout
   (eq cl-tpg::*terminal-action-format* :factored)
   "11 actions retains the legacy factored contract"))

(let* ((controller
         (cl-tpg:make-cage2-controller :decoy-order-profile :heuristic))
       (decision
         (cl-tpg::cage2-controller-resolve-pair-ranking
          controller '((8 3)))))
  (check-semantic36-rollout
   (equal (cl-gym::controller-decision->cage2-input decision)
          '(8 3 1))
   "Controller sends one exact User2 Decoy option to the bridge")
  (check-semantic36-rollout
   (= (cl-tpg:cage2-controller-decision-concrete-action decision) 51)
   "Controller independently predicts the official concrete action")
  (let ((info (make-hash-table :test #'equal)))
    (setf (gethash "concrete_action" info) 51)
    (cl-gym::commit-controller-step controller decision info))
  (check-semantic36-rollout
   (and (cl-tpg::cage2-controller-decoy-used-p controller 8 1)
        (= (cl-tpg::cage2-controller-step controller) 1))
   "only a bridge-confirmed concrete action advances Controller state"))

(let* ((cl-tpg::*terminal-action-format* :target-response-36)
       (team (cl-tpg::%make-team :id "semantic36-checkpoint"
                                 :learners nil
                                 :option-orders nil))
       (data
         (cl-tpg::make-best-team-checkpoint-data
          team 0.0d0
          :terminal-action-format cl-tpg::*terminal-action-format*)))
  (check-semantic36-rollout
   (eq (getf data :terminal-action-format) :target-response-36)
   "checkpoint metadata preserves the terminal action representation")
  (check-semantic36-rollout
   (= (getf data :checkpoint-version)
      cl-tpg::+best-team-checkpoint-version+)
   "Semantic-36 metadata uses the current checkpoint envelope"))

(let ((cl-tpg::*terminal-action-format* :target-response-36)
      (cl-tpg::*teacher-backend* :heuristic))
  (check-semantic36-rollout
   (cl-tpg::lisp-heuristic-controller-path-p "Cage2-b_line-30-v0")
   "B-line direct Semantic-36 dispatches to the Lisp teacher")
  (check-semantic36-rollout
   (cl-tpg::lisp-heuristic-controller-path-p "Cage2-meander-30-v0")
   "Meander direct Semantic-36 dispatches to its Lisp teacher")
  (check-semantic36-rollout
   (eq (cl-tpg::cage2-heuristic-controller-profile
        "Cage2-meander-30-v0")
       :meander-heuristic)
   "Meander dispatch selects its independent Controller profile"))

(let ((cl-tpg::*teacher-backend* :heuristic)
      (cl-tpg::*cage2-controller-decoy-order-profile* :heuristic)
      (cl-tpg::*num-actions* 36)
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*hamming-space-enabled* nil))
  (cl-tpg::make-fitness-function
   :gym-environment-name "Cage2-meander-100-v0")
  (check-semantic36-rollout
   (eq cl-tpg::*cage2-controller-decoy-order-profile* :meander-heuristic)
   "online Meander saves the Controller profile used by Gym")
  (let* ((team (cl-tpg::%make-team :id "meander-profile-checkpoint"
                                    :learners nil :option-orders nil))
         (data (cl-tpg::make-best-team-checkpoint-data team 0.0d0)))
    (check-semantic36-rollout
     (eq (getf data :cage2-controller-decoy-order-profile)
         :meander-heuristic)
     "Meander checkpoint records its actual rollout profile")))

(let ((cl-tpg::*teacher-backend* :model)
      (cl-tpg::*cage2-controller-decoy-order-profile* :model))
  (check-semantic36-rollout
   (eq (cl-tpg::cage2-rollout-controller-decoy-order-profile
        "Cage2-meander-100-v0")
       :model)
   "non-heuristic controller profiles remain unchanged"))

(format t "Semantic-36 rollout checks passed (~D checks).~%"
        *semantic36-rollout-checks*)
