;;; Focused checks for peer nomination without Gym or a training run.
(in-package :cl-user)

(defvar *peer-election-checks* 0)

(defun check-peer-election (condition description)
  (incf *peer-election-checks*)
  (unless condition
    (error "Peer-election check failed: ~A" description)))

(defun peer-test-instruction (register value)
  (cl-tpg::%make-instruction
   :dest register :op :add :arity 2
   :src1-type :const :src1-val value
   :src2-type :const :src2-val 0.0d0))

(defun peer-test-learner (action bid selector confidence)
  (cl-tpg::make-learner
   :action (cl-tpg::make-action :type :atomic :action action)
   :program
   (cl-tpg::make-program
    :instructions
    (make-array 3 :fill-pointer t :adjustable t
                :initial-contents
                (list (peer-test-instruction 0 bid)
                      (peer-test-instruction 1 selector)
                      (peer-test-instruction 2 confidence))))))

(let ((cl-tpg::*teams* nil)
      (cl-tpg::*max-num-learners* 32)
      (cl-tpg::*init-program-size* 3)
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*num-actions* 36))
(let* ((observation (make-array 1 :element-type 'double-float
                                :initial-element 0.0d0))
       (a (peer-test-learner 0 99.0d0 1.0d0 0.0d0))
       (b (peer-test-learner 1 3.0d0 1.0d0 0.0d0))
       (c (peer-test-learner 2 1.0d0 1.0d0 0.0d0))
       (d (peer-test-learner 3 2.0d0 1.0d0 0.0d0))
       (team (cl-tpg::make-team :learners (list a b c d))))
  ;; A -> B, B -> C, C -> A, D -> C. C wins despite the lowest bid.
  (setf (cl-tpg::learner-peer-nominees a)
        (list (cl-tpg::learner-peer-seat b) (cl-tpg::learner-peer-seat c))
        (cl-tpg::learner-peer-nominees b)
        (list (cl-tpg::learner-peer-seat c) (cl-tpg::learner-peer-seat a))
        (cl-tpg::learner-peer-nominees c)
        (list (cl-tpg::learner-peer-seat a) (cl-tpg::learner-peer-seat b))
        (cl-tpg::learner-peer-nominees d)
        (list (cl-tpg::learner-peer-seat c) (cl-tpg::learner-peer-seat a)))
  (let ((cl-tpg::*team-selection-mode* :bid))
    (check-peer-election
     (eq (nth-value 0 (cl-tpg::execute-team-to-terminal team observation)) a)
     "legacy strict maximum bid still wins"))
  (let ((cl-tpg::*team-selection-mode* :peer-election))
    (multiple-value-bind (winner registers)
        (cl-tpg::execute-team-to-terminal team observation)
      (check-peer-election (eq winner c) "incoming votes select C")
      (check-peer-election (= (aref registers 0) 1.0d0)
                           "terminal learner registers are retained"))
    (check-peer-election
     (eq (first (first (cl-tpg::team-ordered-evaluations team observation))) c)
     "ranked traversal has the same first winner")
    (check-peer-election
     (= (cl-tpg::semantic-action-target
         (first (cl-tpg::execute-team-semantic-ranked
                 team observation 4)))
        2)
     "semantic ranked policy begins with the elected terminal")
    (check-peer-election
     (equal (cl-tpg::policy-effective-output-registers) '(1 2))
     "effective-aware mutation sees election registers")
    (check-peer-election
     (equal (getf (cl-tpg::analyze-program-effective-code
                   (cl-tpg::learner-program c))
                  :effective-indices)
            '(1 2))
     "nomination and support writes are not classified as introns")
    (check-peer-election
     (search "-peer-election.lisp" (cl-tpg::best-team-checkpoint-filename))
     "election checkpoints use a separate filename")
    (let ((metadata (cl-tpg::make-best-team-checkpoint-data team 0.0d0)))
      (check-peer-election
       (eq (getf metadata :team-selection-mode) :peer-election)
       "checkpoint records the election contract"))
    (let* ((copy (cl-tpg::clone-team team))
           (round-trip (cl-tpg::deserialize-team
                        (cl-tpg::serialize-team team)
                        (make-hash-table :test #'equal))))
      (dolist (other (list copy round-trip))
        (check-peer-election
         (= (cl-tpg::execute-team other observation) 2)
         "clone and serialization retain election behavior")
        (check-peer-election
         (equal (mapcar #'cl-tpg::learner-peer-nominees
                        (cl-tpg::team-learners other))
                (mapcar #'cl-tpg::learner-peer-nominees
                        (cl-tpg::team-learners team)))
         "clone and serialization retain nominations")))
    (let* ((child-learner (peer-test-learner 7 0.0d0 0.0d0 0.0d0))
           (child (cl-tpg::make-team :learners (list child-learner))))
      (setf (cl-tpg::learner-action c)
            (cl-tpg::make-action :type :reference :action child))
      (cl-tpg::add-reference child)
      (multiple-value-bind (winner registers)
          (cl-tpg::execute-team-to-terminal team observation)
        (check-peer-election (eq winner child-learner)
                             "elected team reference recurses")
        (check-peer-election (= (aref registers 0) 0.0d0)
                             "intermediate voter registers are discarded")))
    (cl-tpg::delete-learner team)
    (check-peer-election
     (every (lambda (learner)
              (every (lambda (seat)
                       (and (/= seat (cl-tpg::learner-peer-seat learner))
                            (find seat (cl-tpg::team-learners team)
                                  :key #'cl-tpg::learner-peer-seat)))
                     (cl-tpg::learner-peer-nominees learner)))
            (cl-tpg::team-learners team))
     "deletion repairs peer seats without self votes")))

(let* ((observation (make-array 1 :element-type 'double-float
                                :initial-element 0.0d0))
       (a (peer-test-learner 4 1.0d0 -1.0d0 -20.0d0))
       (b (peer-test-learner 5 9.0d0 1.0d0 20.0d0))
       (cl-tpg::*team-selection-mode* :peer-election)
       (team (cl-tpg::make-team :learners (list a b))))
  ;; Both receive one vote; A's vote carries little confidence, B's much more.
  (check-peer-election
   (eq (first (first (cl-tpg::team-ordered-evaluations team observation))) a)
   "two-peer vote tie uses voter confidence, not self bid")
  (check-peer-election
   (every (lambda (voter)
            (every (lambda (seat)
                     (/= seat (cl-tpg::learner-peer-seat voter)))
                   (cl-tpg::learner-peer-nominees voter)))
          (cl-tpg::team-learners team))
   "two-peer nominations never vote for self")
  (cl-tpg::add-learner team)
  (let ((new-seat (cl-tpg::learner-peer-seat
                   (first (cl-tpg::team-learners team)))))
    (check-peer-election
     (some (lambda (voter)
             (and (/= (cl-tpg::learner-peer-seat voter) new-seat)
                  (member new-seat
                          (cl-tpg::learner-peer-nominees voter))))
           (cl-tpg::team-learners team))
     "learner addition connects an incoming vote"))
  (cl-tpg::mutate-peer-nomination team)
  (check-peer-election
   (every (lambda (voter)
            (every (lambda (seat)
                     (/= seat (cl-tpg::learner-peer-seat voter)))
                   (cl-tpg::learner-peer-nominees voter)))
          (cl-tpg::team-learners team))
   "nomination mutation preserves no-self-vote invariant"))
)

(format t "Peer-election checks passed (~D).~%" *peer-election-checks*)
