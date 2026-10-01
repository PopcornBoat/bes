;;; Focused construction and protocol checks for the compiled heuristic TPG.

(in-package :cl-user)

(load (asdf:system-relative-pathname
       "cl-tpg" "oracles/compiled-bline-heuristic.lisp"))

(let* ((cl-tpg::*num-observations* cl-tpg::+cage2-scan-observation-size+)
       (cl-tpg::*num-actions* cl-tpg::+num-semantic-36-actions+)
       (cl-tpg::*factored-actions-enabled* t)
       (cl-tpg::*terminal-action-format* :target-response-36)
       (team (cl-tpg::make-compiled-bline-heuristic-team))
       (observation
         (make-array cl-tpg::+cage2-scan-observation-size+
                     :element-type 'double-float
                     :initial-element 0.0d0))
       (ranking
         (cl-tpg:execute-team-semantic-ranked team observation))
       (controller
         (cl-tpg:make-cage2-controller :decoy-order-profile :heuristic))
       (actual nil))
  (assert (= (length (cl-tpg::team-learners team)) 29))
  (assert (= (cl-tpg:semantic-action-target (first ranking)) 8))
  (assert (eq (cl-tpg:semantic-action-response (first ranking)) :decoy))
  (loop repeat (length cl-tpg::+cage2-heuristic-decoy-schedule+)
        for decision =
          (cl-tpg:cage2-controller-resolve-ranking controller ranking)
        do (push
            (list
             (cl-tpg:semantic-action-target
              (cl-tpg:cage2-controller-decision-semantic-action decision))
             (cl-tpg:cage2-controller-decision-option decision))
            actual)
           (cl-tpg:cage2-controller-commit-decision controller decision))
  (assert (equal (nreverse actual)
                 cl-tpg::+cage2-heuristic-decoy-schedule+))
  (let* ((serialized (cl-tpg::serialize-team team))
         (loaded
           (cl-tpg::deserialize-team serialized (make-hash-table :test #'equal))))
    (assert
     (equal
      (mapcar #'cl-tpg::semantic-action-category-pair ranking)
      (mapcar #'cl-tpg::semantic-action-category-pair
              (cl-tpg:execute-team-semantic-ranked loaded observation)))))
  (multiple-value-bind (checkpoint-team checkpoint-fitness checkpoint-metadata)
      (cl-tpg::load-best-team
       (asdf:system-relative-pathname
        "cl-tpg"
        "oracles/checkpoints/bline-62-36-compiled-heuristic.lisp"))
    (assert (= checkpoint-fitness 0.0d0))
    (assert (= (length (cl-tpg::team-learners checkpoint-team)) 29))
    (assert (= (getf checkpoint-metadata :num-observations) 62))
    (assert (eq (getf checkpoint-metadata :terminal-action-format)
                :target-response-36))
    (assert
     (equal
      (mapcar #'cl-tpg::semantic-action-category-pair ranking)
      (mapcar
       #'cl-tpg::semantic-action-category-pair
       (cl-tpg:execute-team-semantic-ranked checkpoint-team observation))))))

(format t "Compiled B-line heuristic TPG checks passed.~%")
