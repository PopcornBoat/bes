;;; Focused regression checks for the pure Lisp B-line heuristic teacher.

(in-package :cl-user)

(defvar *heuristic-checks* 0)

(defun check-heuristic (condition description)
  (incf *heuristic-checks*)
  (unless condition
    (error "Lisp heuristic check failed: ~A" description)))

(defun heuristic-pairs (ranking)
  (mapcar #'cl-tpg::semantic-action-category-pair ranking))

(defun blank-raw-observation ()
  (make-array cl-tpg::+cage2-raw-observation-size+
              :element-type 'double-float
              :initial-element 0.0d0))

;;; A blank state follows the exact unique target order of the original Decoy
;;; schedule, then enters the deterministic Analyse/Remove fallback.
(let* ((controller
         (cl-tpg:make-cage2-controller :decoy-order-profile :heuristic))
       (observation
         (cl-tpg:cage2-controller-observe
          controller (blank-raw-observation)))
       (ranking
         (cl-tpg:cage2-bline-heuristic-ranking controller observation)))
  (check-heuristic
   (equal (heuristic-pairs ranking)
          '((8 3) (2 3) (3 3) (4 3) (5 3) (9 3) (10 3) (2 0)))
   "blank-state ranking preserves heuristic Decoy and fallback priority")
  (check-heuristic
   (and (zerop (cl-tpg::cage2-controller-decoy-mask controller))
        (zerop (cl-tpg::cage2-controller-step controller)))
   "heuristic query has no Controller side effects")
  (check-heuristic
   (every (lambda (pair)
            (and (find (first pair) cl-tpg::*semantic-36-targets* :test #'=)
                 (<= 0 (second pair) 3)))
          (heuristic-pairs ranking))
   "heuristic emits only direct Semantic-36 categories"))

;;; User2 has exactly two actions in the original global Decoy schedule.  Once
;;; both execute, the heuristic must not expose other controller-order options
;;; that the original teacher never used.
(let* ((controller
         (cl-tpg:make-cage2-controller :decoy-order-profile :heuristic))
       (observation
         (cl-tpg:cage2-controller-observe
          controller (blank-raw-observation))))
  (loop repeat 2
        do
    (let* ((ranking
             (cl-tpg:cage2-bline-heuristic-ranking controller observation))
           (decision
             (cl-tpg:cage2-controller-resolve-ranking controller ranking)))
      (check-heuristic
       (= (cl-tpg:semantic-action-target
           (cl-tpg:cage2-controller-decision-semantic-action decision))
          8)
       "User2 is selected while a scheduled option remains")
      (cl-tpg:cage2-controller-commit-decision controller decision)))
  (check-heuristic
   (not (member '(8 3)
                (heuristic-pairs
                 (cl-tpg:cage2-bline-heuristic-ranking
                  controller observation))
                :test #'equal))
   "exhausting scheduled User2 options advances to another semantic target"))

;;; Scan/host inspection preserves the original priority: Op_Server0 Analyse
;;; first, then Restore on a later compromised observation after it was scanned.
(let* ((controller
         (cl-tpg:make-cage2-controller :decoy-order-profile :heuristic))
       (raw (blank-raw-observation)))
  (setf (aref raw 28) 1.0d0)
  (let ((observation (cl-tpg:cage2-controller-observe controller raw)))
    (check-heuristic
     (equal (first (heuristic-pairs
                    (cl-tpg:cage2-bline-heuristic-ranking
                     controller observation)))
            '(5 0))
     "Op_Server0 scan pattern produces highest-priority Analyse"))
  (fill raw 0.0d0)
  (setf (aref raw 31) 1.0d0)
  (let ((observation (cl-tpg:cage2-controller-observe controller raw)))
    (check-heuristic
     (equal (first (heuristic-pairs
                    (cl-tpg:cage2-bline-heuristic-ranking
                     controller observation)))
            '(5 2))
     "previously scanned compromised Op_Server0 produces Restore")))

;;; The teacher-specific option schedule must not silently run under another
;;; controller profile.
(let* ((controller
         (cl-tpg:make-cage2-controller :decoy-order-profile :model))
       (observation
         (cl-tpg:cage2-controller-observe
          controller (blank-raw-observation)))
       (signaled nil))
  (handler-case
      (cl-tpg:cage2-bline-heuristic-ranking controller observation)
    (error () (setf signaled t)))
  (check-heuristic signaled
                   "wrong Decoy-order profile is rejected explicitly"))

;;; Meander blank states expose the unique target order of its exact 18-action
;;; Decoy schedule.  Proposal queries remain pure.
(let* ((controller
         (cl-tpg:make-cage2-controller
          :decoy-order-profile :meander-heuristic))
       (observation
         (cl-tpg:cage2-controller-observe
          controller (blank-raw-observation)))
       (ranking
         (cl-tpg:cage2-meander-heuristic-ranking controller observation)))
  (check-heuristic
   (equal (heuristic-pairs ranking)
          '((8 3) (2 3) (4 3) (3 3) (7 3) (9 3) (10 3) (1 3)))
   "Meander blank-state ranking preserves global Decoy target priority")
  (check-heuristic
   (and (zerop (cl-tpg::cage2-controller-decoy-mask controller))
        (zerop (cl-tpg::cage2-controller-step controller)))
   "Meander heuristic query has no Controller side effects"))

;;; Resolve and commit all exact Meander Decoys.  The resulting concrete action
;;; sequence must equal BlueMeanderHeuristic.py byte-for-byte.
(let* ((controller
         (cl-tpg:make-cage2-controller
          :decoy-order-profile :meander-heuristic))
       (observation
         (cl-tpg:cage2-controller-observe
          controller (blank-raw-observation)))
       (concrete-actions nil))
  (loop repeat 18
        do (let* ((ranking
                    (cl-tpg:cage2-meander-heuristic-ranking
                     controller observation))
                  (decision
                    (cl-tpg:cage2-controller-resolve-ranking
                     controller ranking)))
             (push
              (cl-tpg:cage2-controller-decision-concrete-action decision)
              concrete-actions)
             (cl-tpg:cage2-controller-commit-decision
              controller decision)))
  (check-heuristic
   (equal (nreverse concrete-actions)
          '(51 55 116 44 43 29 107 37 130 115 76 131 120 38 91 102 90 28))
   "Meander Controller reproduces the exact Python Decoy schedule")
  (let* ((ranking
           (cl-tpg:cage2-meander-heuristic-ranking controller observation))
         (decision
           (cl-tpg:cage2-controller-resolve-ranking controller ranking)))
    (check-heuristic
     (= (cl-tpg:cage2-controller-decision-concrete-action decision) 2)
     "exhausted Meander Decoys use deterministic Defender Analyse fallback")))

;;; Preserve both original host loops and their distinct Analyse patterns.
(let* ((controller
         (cl-tpg:make-cage2-controller
          :decoy-order-profile :meander-heuristic))
       (raw (blank-raw-observation)))
  (setf (aref raw 4) 1.0d0)
  (check-heuristic
   (equal
    (first
     (heuristic-pairs
      (cl-tpg:cage2-meander-heuristic-ranking
       controller (cl-tpg:cage2-controller-observe controller raw))))
    '(2 0))
   "Meander primary-loop 1000 pattern produces Enterprise0 Analyse")
  (fill raw 0.0d0)
  (setf (aref raw 2) 1.0d0)
  (check-heuristic
   (equal
    (first
     (heuristic-pairs
      (cl-tpg:cage2-meander-heuristic-ranking
       controller (cl-tpg:cage2-controller-observe controller raw))))
    '(1 0))
   "Meander secondary-loop 0010 pattern produces Defender Analyse")
  (fill raw 0.0d0)
  (setf (aref raw 7) 1.0d0)
  (check-heuristic
   (equal
    (first
     (heuristic-pairs
      (cl-tpg:cage2-meander-heuristic-ranking
       controller (cl-tpg:cage2-controller-observe controller raw))))
    '(2 2))
   "Meander primary-loop compromise pattern produces Enterprise0 Restore"))

(format t "Lisp B-line/Meander heuristic checks passed (~D checks).~%"
        *heuristic-checks*)
