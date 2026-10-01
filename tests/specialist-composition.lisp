;;; Focused non-simulator checks for specialist composition specialist composition.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *targeted-composition-checks* 0)

(defun check-targeted-composition (condition description)
  (incf *targeted-composition-checks*)
  (unless condition
    (error "specialist composition composition check failed: ~A" description)))

(defun targeted-composition-bid-program (value)
  (cl-tpg::make-program
   :instructions
   (make-array
    1 :adjustable t :fill-pointer t
    :initial-contents
    (list
     (cl-tpg::%make-instruction
      :dest 0 :op :add
      :src1-type :const :src1-val (coerce value 'double-float)
      :src2-type :const :src2-val 0.0d0 :arity 2)))))

(defun targeted-composition-terminal (bid pair)
  (cl-tpg::make-learner
   :program (targeted-composition-bid-program bid)
   :action
   (cl-tpg::make-action
    :type :atomic
    :action
    (cl-tpg::make-target-response-36-action
     :target (first pair) :response (second pair)))))

(defun install-targeted-composition-score (team key score)
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash key table) score
          (gethash team cl-tpg::*grouped-team-group-scores*) table)))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*targeted-specialist-composition-enabled* t)
      (cl-tpg::*targeted-routing-repair-enabled* nil)
      (cl-tpg::*targeted-disagreement-audit-enabled* t)
      (cl-tpg::*grouped-selection-enabled* t)
      (cl-tpg::*semantic-locality-control-enabled* t)
      (cl-tpg::*behavioral-locality-enabled* t)
      (cl-tpg::*terminal-action-format* :target-response-36))
  (check-targeted-composition
   (cl-tpg::targeted-specialist-composition-active-p)
   "composition activates only under the isolated frozen contract"))

;; Scheduling resumes exactly and does not consume the evolution RNG.
(let ((cl-tpg::*random-state* (sb-ext:seed-random-state 42)))
  (cl-tpg::initialize-targeted-specialist-composition-state 153)
  (cl-tpg::targeted-specialist-composition-random-below 1000)
  (let* ((state (cl-tpg::targeted-specialist-composition-state-copy))
         (expected
           (cl-tpg::targeted-specialist-composition-random-below 100000)))
    (cl-tpg::initialize-targeted-specialist-composition-state 999)
    (cl-tpg::restore-targeted-specialist-composition-state state)
    (check-targeted-composition
     (= (cl-tpg::targeted-specialist-composition-random-below 100000)
        expected)
     "composition RNG checkpoint/restore replays the exact next draw")))

(let* ((observation
         (make-array 1 :element-type 'double-float :initial-element 0.0d0))
       (teacher-pair '(2 3))
       ;; Eight distinct higher bidders keep TEACHER-PAIR outside Top-8 even
       ;; though the parent genotype contains its direct terminal.
       (parent
         (cl-tpg::%make-team
          :id "parent"
          :learners
          (append
           (loop for bid from 20 downto 13
                 for pair in '((3 0) (4 0) (5 0) (7 0)
                               (8 0) (9 0) (10 0) (3 1))
                 collect (targeted-composition-terminal bid pair))
           (list (targeted-composition-terminal 1 teacher-pair)))))
       (donor
         (cl-tpg::%make-team
          :id "donor"
          :learners
          (list (targeted-composition-terminal 30 teacher-pair)
                (targeted-composition-terminal 1 '(3 0)))))
       (key '(:teacher-pair 2 3))
       (issue
         '(:case :case-b1-reachable-support
           :phase :steps-10-29
           :teacher-pair (2 3)
           :predicted-pair (3 0)
           :occurrences 3
           :episode-count 3
           :systematic-p t))
       (contexts
         (loop repeat 3
               collect
               (list :observation observation
                     :teacher-pair teacher-pair
                     :parent-ranking
                       (cl-tpg::behavioral-ranking-pairs parent observation)
                     :parent-rank cl-tpg::+semantic-ranking-limit+)))
       (cl-tpg::*teams* (list parent donor))
       (cl-tpg::*num-observations* 1)
       (cl-tpg::*factored-actions-enabled* t)
       (cl-tpg::*terminal-action-format* :target-response-36)
       (cl-tpg::*grouped-case-groups*
         (list (list :key key :indices #(0 1 2))))
       (cl-tpg::*grouped-team-group-scores* (make-hash-table :test #'eq))
       (cl-tpg::*grouped-group-epsilons* (make-hash-table :test #'equal))
       (cl-tpg::*max-num-learners* 20))
  (install-targeted-composition-score parent key 0.1d0)
  (install-targeted-composition-score donor key 1.0d0)
  (setf (gethash key cl-tpg::*grouped-group-epsilons*) 0.0d0)
  (cl-tpg::initialize-targeted-specialist-composition-state 2026)
  (let ((source
          (cl-tpg::targeted-select-specialist-source
           (list parent donor) parent issue contexts)))
    (check-targeted-composition
     (and (eq (getf source :source-type) :live-team-reference)
          (eq (getf source :team) donor)
          (= (getf source :exact-rate) 1.0d0))
     "a current group elite that wins the issue rows becomes the donor")
    (let* ((child (cl-tpg::clone-team parent))
           (before-references (cl-tpg::team-references donor)))
      (let ((cl-tpg::*active-mutation-events* nil))
        (check-targeted-composition
         (cl-tpg::targeted-add-specialist-learner
          child source teacher-pair 1)
         "composition adds a gateway learner to a cloned root")
        (check-targeted-composition
         (and (= (cl-tpg::team-references donor)
                 (1+ before-references))
              (eq (cl-tpg::team-type donor) :internal)
              (eq (cl-tpg::action-type
                   (cl-tpg::learner-action
                    (first (cl-tpg::team-learners child))))
                  :reference))
         "accepted graph construction uses a counted team reference")
        (let ((comparison
                (cl-tpg::targeted-target-group-comparison child contexts)))
          (check-targeted-composition
           (and (= (getf comparison :top1-gains) 3)
                (zerop (getf comparison :top1-losses))
                (cl-tpg::targeted-target-comparison-improves-p comparison))
           "the composed specialist repairs the selected Case-B1 group")))
      ;; Rejected candidates must undo both cloned references and the donor
      ;; edge; otherwise a trial would silently alter the live root pool.
      (cl-tpg::discard-semantic-locality-candidate child)
      (check-targeted-composition
       (and (= (cl-tpg::team-references donor) before-references)
            (eq (cl-tpg::team-type donor) :root))
       "discarding a candidate restores donor reference/type state")))
  ;; Without another qualified live root, the fallback is an explicit direct
  ;; terminal specialist; it does not expose controller decoy state to TPG.
  (let ((source
          (cl-tpg::targeted-select-specialist-source
           (list parent) parent issue contexts)))
    (check-targeted-composition
     (eq (getf source :source-type) :direct-terminal-fallback)
     "missing live donor selects the recorded direct-terminal fallback")))

;; Checkpoints and filenames isolate specialist composition from the protected A/4a files.
(let* ((team (cl-tpg::%make-team :id "checkpoint" :learners nil))
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*targeted-routing-repair-enabled* nil)
       (cl-tpg::*targeted-specialist-composition-enabled* t)
       (cl-tpg::*checkpoint-directory* nil))
  (cl-tpg::initialize-targeted-specialist-composition-state 2026)
  (let ((data (cl-tpg::make-best-team-checkpoint-data team 0.5d0)))
    (check-targeted-composition
     (and (= (getf data :checkpoint-version)
             cl-tpg::+best-team-checkpoint-version+)
          (equal (getf data :targeted-specialist-composition-state)
                 (cl-tpg::targeted-specialist-composition-state-copy)))
     "the current checkpoint persists the independent composition stream")
    (check-targeted-composition
     (search "official-guided-specialist-composition"
             (cl-tpg::best-team-checkpoint-filename))
     "specialist composition cannot overwrite the targeted routing repair or grouped selection filename")))

(format t "specialist composition specialist composition checks passed (~D checks).~%"
        *targeted-composition-checks*)
