(in-package :cl-tpg)

(defun native-instruction (destination opcode type1 value1 type2 value2)
  (%make-instruction :dest destination :op opcode
                     :src1-type type1 :src1-val (coerce value1 'double-float)
                     :src2-type type2 :src2-val (coerce value2 'double-float)
                     :arity 2))

(defun native-program (instructions)
  (make-program :instructions (make-array (length instructions) :initial-contents instructions
                                         :adjustable t :fill-pointer t)))

(defun native-constant-bid (value)
  (native-program (list (native-instruction 0 :add :const value :const 0))))

(defun native-reference (program child)
  (add-reference child)
  (make-learner :program program :action (make-action :type :reference :action child)))

(defun native-ranked-terminal (ranking)
  (assert (= 8 (length ranking) (length (remove-duplicates ranking :test #'equal))))
  (make-team :type :internal
             :learners
             (loop for (target response) in ranking for rank from 0
                   do (assert (and (find target *semantic-36-targets*) (<= 0 response 3)))
                   collect
                   (make-learner :program (native-constant-bid (- 8 rank))
                                 :action (make-action :type :atomic
                                                      :action (make-target-response-36-action
                                                               :target target :response response))))))

(defun native-exact-predicate (observation)
  (native-program
   (cons (native-instruction 0 :add :const 1 :const 0)
         (loop for char across observation for i from 0
               append
                 (list (native-instruction 1 :eq :obs i :const (digit-char-p char))
                       (native-instruction 0 :mul :reg 0 :reg 1))))))

(defun native-binary-choice (predicate match other)
  ;; An exact EQ-based predicate emits 0 or 1. The complement wins at 0.
  (make-team :type :internal
             :learners (list (native-reference predicate match)
                             (native-reference (native-constant-bid 0.5d0) other))))

(defun native-balanced-split (rows)
  (let* ((total (length rows))
         (best-balance 0)
         (best-index nil)
         (best-value nil))
    (dotimes (index 62)
      (let ((counts (make-array 3 :initial-element 0)))
        (dolist (row rows)
          (incf (aref counts (digit-char-p (char (car row) index)))))
        (dotimes (value 3)
          (let ((balance (min (aref counts value) (- total (aref counts value)))))
            (when (> balance best-balance)
              (setf best-balance balance best-index index best-value value))))))
    (assert best-index)
    (values best-index best-value)))

(defun native-compile-decision-tree (rows fallback)
  (let ((terminals (make-hash-table :test #'equal)))
    (labels ((emit (choices)
               (if (endp (rest choices))
                   (destructuring-bind (obs . ranking) (first choices)
                     (let ((terminal (or (gethash ranking terminals)
                                         (setf (gethash ranking terminals)
                                               (native-ranked-terminal ranking)))))
                       (native-binary-choice (native-exact-predicate obs) terminal fallback)))
                   (multiple-value-bind (index value) (native-balanced-split choices)
                     (let ((yes nil) (no nil))
                       (dolist (row choices)
                         (if (= value (digit-char-p (char (car row) index)))
                             (push row yes)
                             (push row no)))
                       (native-binary-choice
                        (native-program (list (native-instruction 0 :eq :obs index :const value)))
                        (emit yes) (emit no)))))))
      (let ((root (emit rows)))
        (setf (team-type root) :root)
        (values root (hash-table-count terminals))))))

(defun native-graph-shape (root)
  "Prove acyclic traversal, calculate maximum path length, and count fixed categories."
  (let ((depths (make-hash-table :test #'eq))
        (at-path (make-hash-table :test #'eq))
        (categories (make-hash-table :test #'equal)))
    (labels ((visit (team)
               (assert (not (gethash team at-path)) () "Cycle in ~A" (team-id team))
               (or (gethash team depths)
                   (let ((depth 1))
                     (assert (team-learners team))
                     (setf (gethash team at-path) t)
                     (dolist (learner (team-learners team))
                       (let* ((action (learner-action learner))
                              (payload (action-action action)))
                         (ecase (action-type action)
                           (:reference (setf depth (max depth (1+ (visit payload)))))
                           (:atomic (when (target-response-36-action-p payload)
                                      (setf (gethash (semantic-action-category-pair
                                                      (make-semantic-action-from-terminal payload nil))
                                                     categories) t))))))
                     (remhash team at-path)
                     (setf (gethash team depths) depth)))))
      (let ((depth (visit root)))
        (assert (<= depth +max-team-traversal-depth+))
        (values depth (hash-table-count categories))))))

(defun native-observation (string)
  (map '(simple-array double-float (*))
       (lambda (char) (coerce (digit-char-p char) 'double-float)) string))

(defun native-ranking (team input)
  (mapcar #'semantic-action-category-pair (execute-team-semantic-ranked team input)))
