;;; Focused regression checks for the pure Lisp-side CAGE2 Controller.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *controller-checks* 0)

(defun check-controller (condition description)
  (incf *controller-checks*)
  (unless condition
    (error "Controller check failed: ~A" description)))

(defun controller-semantic (target response)
  (cl-tpg::make-semantic-action
   :target target :response response :option nil))

;; Scan history is episode-local and policy input remains exactly 62 values.
(let* ((controller (cl-tpg:make-cage2-controller))
       (raw (make-array 52 :initial-element 0.0d0))
       (initial (cl-tpg:cage2-controller-observe controller raw)))
  (check-controller (= (length initial) 62)
                    "controller emits only raw plus scan state")
  (check-controller
   (every #'zerop (subseq initial 52))
   "scan state starts clear")
  (setf (aref raw 0) 1.0d0)
  (let ((first-scan
          (cl-tpg:cage2-controller-observe controller raw)))
    (check-controller (= (aref first-scan 52) 2.0d0)
                      "Defender becomes latest scan"))
  (fill raw 0.0d0)
  (setf (aref raw 4) 1.0d0)
  (let ((second-scan
          (cl-tpg:cage2-controller-observe controller raw)))
    (check-controller
     (and (= (aref second-scan 52) 1.0d0)
          (= (aref second-scan 53) 2.0d0))
     "a newer scan demotes the previous latest scan"))
  (cl-tpg:cage2-controller-reset controller)
  (check-controller
   (and (zerop (cl-tpg::cage2-controller-step controller))
        (zerop (cl-tpg::cage2-controller-decoy-mask controller))
        (every #'zerop (cl-tpg::cage2-controller-scan-state controller)))
   "episode reset clears all controller state"))

;; Proposal resolution is pure. State changes only after the selected concrete
;; action is confirmed through COMMIT-DECISION.
(let* ((controller
         (cl-tpg:make-cage2-controller :decoy-order-profile :model))
       (ranking
         (list (controller-semantic 1 :decoy)
               (controller-semantic 8 :analyse)))
       (decision
         (cl-tpg:cage2-controller-resolve-ranking controller ranking)))
  (check-controller
   (and (= (cl-tpg:cage2-controller-decision-rank decision) 0)
        (= (cl-tpg:cage2-controller-decision-option decision) 2)
        (= (cl-tpg:cage2-controller-decision-concrete-action decision) 54))
   "fixed order resolves Defender Decoy option 2 to action 54")
  (check-controller
   (and (zerop (cl-tpg::cage2-controller-decoy-mask controller))
        (zerop (cl-tpg::cage2-controller-step controller)))
   "proposal query has no controller side effects")
  (cl-tpg:cage2-controller-commit-decision controller decision)
  (check-controller
   (and (cl-tpg::cage2-controller-decoy-used-p controller 1 2)
        (= (cl-tpg::cage2-controller-step controller) 1))
   "commit records exactly the executed Decoy")
  (let ((failed nil)
        (before (cl-tpg::cage2-controller-decoy-mask controller)))
    (handler-case
        (cl-tpg:cage2-controller-commit-decision controller decision 999)
      (error () (setf failed t)))
    (check-controller
     (and failed
          (= before (cl-tpg::cage2-controller-decoy-mask controller))
          (= (cl-tpg::cage2-controller-step controller) 1))
     "mismatched actual action is rejected without state drift")))

;; The fixed execution profile is explicit and does not depend on which
;; teacher supplies proposals.
(let* ((model
         (cl-tpg:make-cage2-controller :decoy-order-profile :model))
       (heuristic
         (cl-tpg:make-cage2-controller :decoy-order-profile :heuristic))
       (ranking (list (controller-semantic 5 :decoy))))
  (dolist (controller (list model heuristic))
    (cl-tpg:cage2-controller-commit-decision
     controller
     (cl-tpg:cage2-controller-resolve-ranking controller ranking)))
  (let ((model-next
          (cl-tpg:cage2-controller-resolve-ranking model ranking))
        (heuristic-next
          (cl-tpg:cage2-controller-resolve-ranking heuristic ranking)))
    (check-controller
     (= (cl-tpg:cage2-controller-decision-option model-next) 0)
     "model profile keeps its versioned second Op_Server0 option")
    (check-controller
     (= (cl-tpg:cage2-controller-decision-option heuristic-next) 6)
     "heuristic profile keeps its versioned second Op_Server0 option")))

;; Exhausted Decoy advances through the existing ranked fallback rule; Restore
;; is skipped below rank zero and Monitor remains the final safe fallback.
(let* ((controller
         (cl-tpg:make-cage2-controller :decoy-order-profile :model))
       (decoy (controller-semantic 1 :decoy)))
  (loop repeat 8
        do (cl-tpg:cage2-controller-commit-decision
            controller
            (cl-tpg:cage2-controller-resolve-ranking
             controller (list decoy))))
  (check-controller
   (null (cl-tpg::cage2-controller-first-available-decoy controller 1))
   "eight committed options exhaust one host")
  (let ((next
          (cl-tpg:cage2-controller-resolve-ranking
           controller
           (list decoy
                 (controller-semantic 8 :restore)
                 (controller-semantic 8 :analyse)))))
    (check-controller
     (and (= (cl-tpg:cage2-controller-decision-rank next) 2)
          (= (cl-tpg:cage2-controller-decision-concrete-action next) 12))
     "exhausted Decoy skips fallback Restore and selects next Analyse"))
  (let ((fallback
          (cl-tpg:cage2-controller-resolve-ranking
           controller
           (list decoy (controller-semantic 8 :restore)))))
    (check-controller
     (and (cl-tpg:cage2-controller-decision-fallback-p fallback)
          (null (cl-tpg:cage2-controller-decision-rank fallback))
          (= (cl-tpg:cage2-controller-decision-concrete-action fallback) 1))
     "unusable ranking safely falls back to Monitor"))
  (let ((restore
          (cl-tpg:cage2-controller-resolve-ranking
           controller (list (controller-semantic 1 :restore)))))
    (cl-tpg:cage2-controller-commit-decision controller restore)
    (check-controller
     (zerop (logand #xff (cl-tpg::cage2-controller-decoy-mask controller)))
     "rank-zero Restore clears only its target Decoys")))

;; A Semantic-36 terminal decodes directly into a controller proposal.
(let* ((controller
         (cl-tpg:make-cage2-controller :decoy-order-profile :heuristic))
       (registers
         (make-array cl-tpg::+num-registers+
                     :element-type 'double-float
                     :initial-element 0.0d0))
       (semantic
         (cl-tpg::make-semantic-action-from-terminal
          (cl-tpg::make-semantic-36-action :index 35)
          registers))
       (decision
         (cl-tpg:cage2-controller-resolve-ranking
          controller (list semantic))))
  (check-controller
   (and (= (cl-tpg:semantic-action-target semantic) 5)
        (eq (cl-tpg:semantic-action-response semantic) :decoy)
        (= (cl-tpg:cage2-controller-decision-option decision) 2)
        (= (cl-tpg:cage2-controller-decision-concrete-action decision) 61))
   "Semantic-36 Op_Server0 Decoy resolves through the Lisp controller"))

;; Exhaustive mapping sanity: every host exposes all four response categories,
;; every fixed Decoy permutation emits eight distinct concrete actions, and the
;; ninth Decoy request becomes Monitor.
(dolist (profile '(:model :heuristic))
  (loop for target from 1 below cl-tpg:+num-semantic-targets+
        do (let* ((controller
                    (cl-tpg:make-cage2-controller
                     :decoy-order-profile profile))
                  (agreement (cl-tpg::cage2-controller-agreement controller))
                  (offset
                    (aref (cl-tpg::action-agreement-host-offsets agreement)
                          target)))
             (dolist (entry
                       (list
                        (list :analyse
                              (+ (cl-tpg::action-agreement-analyse-base agreement)
                                 offset))
                        (list :remove
                              (+ (cl-tpg::action-agreement-remove-base agreement)
                                 offset))
                        (list :restore
                              (+ (cl-tpg::action-agreement-restore-base agreement)
                                 offset))))
               (let ((decision
                       (cl-tpg:cage2-controller-resolve-ranking
                        controller
                        (list (controller-semantic target (first entry))))))
                 (check-controller
                  (= (cl-tpg:cage2-controller-decision-concrete-action decision)
                     (second entry))
                  "host response maps through agreement base plus offset")))
             (let ((seen-options nil)
                   (seen-actions nil)
                   (ranking (list (controller-semantic target :decoy))))
               (loop repeat 8
                     for decision =
                       (cl-tpg:cage2-controller-resolve-ranking
                        controller ranking)
                     do (push (cl-tpg:cage2-controller-decision-option decision)
                              seen-options)
                        (push
                         (cl-tpg:cage2-controller-decision-concrete-action
                          decision)
                         seen-actions)
                        (cl-tpg:cage2-controller-commit-decision
                         controller decision))
               (check-controller
                (and (= (length (remove-duplicates seen-options)) 8)
                     (= (length (remove-duplicates seen-actions)) 8))
                "fixed Decoy order emits eight distinct options and actions")
               (let ((ninth
                       (cl-tpg:cage2-controller-resolve-ranking
                        controller ranking)))
                 (check-controller
                  (and (cl-tpg:cage2-controller-decision-fallback-p ninth)
                       (= (cl-tpg:cage2-controller-decision-concrete-action ninth)
                          (cl-tpg::action-agreement-monitor-action agreement)))
                  "ninth Decoy request safely falls back to Monitor"))))))

(format t "Lisp Controller checks passed: ~D.~%" *controller-checks*)
