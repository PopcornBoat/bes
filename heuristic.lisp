(in-package :cl-tpg)

(defparameter +bline-heuristic-host-rules+
  '((7 5 4 ((0 0 0 1) (1 1 0 1) (0 0 1 1) (1 1 1 1)))
    (2 3 2 ((0 0 0 1) (1 1 0 1) (0 0 1 1) (1 1 1 1)))
    (3 4 3 ((0 0 0 1) (0 0 1 1) (1 1 1 1)))
    (1 2 1 ((0 0 0 1) (0 0 1 1) (1 1 1 1))))
  "Priority-ordered BlueBLineHeuristicSimple inspection rules.

Each entry is (RAW-HOST-OFFSET TARGET SCAN-INDEX RESTORE-PATTERNS).  The raw
offset retains the official 13-host observation layout, while TARGET uses the
shared nine-host Semantic-36 namespace.")

(defparameter +bline-heuristic-decoy-schedule+
  '((8 1) (8 6) (2 2) (3 1) (4 1) (2 6) (2 7)
    (5 2) (5 6) (5 0) (9 7) (9 4) (5 7) (10 7))
  "Exact (TARGET OPTION) order of BlueBLineHeuristicSimple's Decoy list.

Repeated targets are intentional: after one option is committed, the next
query may still propose the same semantic (TARGET, DECOY) category while the
Controller resolves it to the next listed concrete option.")

(defparameter +bline-heuristic-fallback-ranking+
  '((2 0) (3 0) (4 0) (5 0)
    (2 1) (3 1) (4 1) (5 1)
    (7 0) (8 0) (9 0) (10 0)
    (1 0) (1 1) (7 1) (8 1) (9 1) (10 1))
  "Deterministic replacement for the original heuristic's random fallback.")

(defun bline-heuristic-observation-pattern (observation raw-host-offset)
  "Return the four-value raw host pattern at RAW-HOST-OFFSET."
  (let ((start (* raw-host-offset 4)))
    (loop for index from start below (+ start 4)
          collect (round (elt observation index)))))

(defun bline-heuristic-append-category (target response seen ranking)
  "Append one unique Semantic-36 category, returning the new RANKING."
  (let ((pair (list target response)))
    (if (gethash pair seen)
        ranking
        (progn
          (setf (gethash pair seen) t)
          (nconc ranking
                 (list
                  (make-semantic-action
                   :target target
                   :response (aref *semantic-response-types* response)
                   :option nil)))))))

(defun bline-heuristic-scheduled-decoy-available-p
       (controller target option)
  "Return true when one exact heuristic-scheduled Decoy remains available."
  (not (cage2-controller-decoy-used-p controller target option)))

(defun cage2-bline-heuristic-ranking (controller observation)
  "Return the pure ranked Semantic-36 proposal for one B-line state.

OBSERVATION is the 62-value result of CAGE2-CONTROLLER-OBSERVE.  The query
reads the Controller's canonical scan/Decoy state but never changes it.  Only
CAGE2-CONTROLLER-COMMIT-DECISION may advance episode state after the selected
concrete action really executes.  The result contains direct target/response
categories; concrete Decoy selection remains exclusively in the Controller."
  (unless (cage2-controller-p controller)
    (error "B-line Lisp heuristic requires a CAGE2 controller, got ~S."
           controller))
  (unless (eq (cage2-controller-decoy-order-profile controller) :heuristic)
    (error "B-line Lisp heuristic requires the :HEURISTIC Decoy profile."))
  (unless (and (typep observation 'sequence)
               (= (length observation) +cage2-scan-observation-size+))
    (error "B-line Lisp heuristic expected ~D observations, got ~S."
           +cage2-scan-observation-size+
           (and (typep observation 'sequence) (length observation))))
  (let ((seen (make-hash-table :test #'equal))
        (ranking nil))
    ;; Preserve the two-loop priority of the original Python heuristic.
    (dolist (rule +bline-heuristic-host-rules+)
      (destructuring-bind
            (raw-host-offset target scan-index restore-patterns)
          rule
        (let ((pattern
                (bline-heuristic-observation-pattern
                 observation raw-host-offset))
              (scan-value
                (round
                 (aref (cage2-controller-scan-state controller)
                       scan-index))))
          (when (equal pattern '(1 0 0 0))
            (setf ranking
                  (bline-heuristic-append-category
                   target 0 seen ranking)))
          (when (and (member scan-value '(1 2))
                     (member pattern restore-patterns :test #'equal))
            (setf ranking
                  (bline-heuristic-append-category
                   target 2 seen ranking))))))
    ;; Availability is read from canonical Controller state.  Repeated
    ;; concrete options collapse to one target/Decoy semantic proposal.
    (dolist (entry +bline-heuristic-decoy-schedule+)
      (destructuring-bind (target option) entry
        (when (bline-heuristic-scheduled-decoy-available-p
               controller target option)
          (setf ranking
                (bline-heuristic-append-category
                 target 3 seen ranking)))))
    (dolist (pair +bline-heuristic-fallback-ranking+)
      (setf ranking
            (bline-heuristic-append-category
             (first pair) (second pair) seen ranking)))
    (subseq ranking 0 (min +semantic-ranking-limit+ (length ranking)))))
