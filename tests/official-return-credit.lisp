;;; Focused non-simulator checks for return-credit lineage paired official lineage credit.

(in-package :cl-user)

(defvar *official-return-credit-checks* 0)

(defun check-official-return-credit (condition description)
  (incf *official-return-credit-checks*)
  (unless condition
    (error "Official return-credit check failed: ~A" description)))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*semantic-locality-control-enabled* t)
      (cl-tpg::*grouped-selection-enabled* t)
      (cl-tpg::*official-return-credit-enabled* t)
      (cl-tpg::*rare-failure-targeted-return-credit-enabled* nil)
      (cl-tpg::*targeted-routing-repair-enabled* nil)
      (cl-tpg::*targeted-specialist-composition-enabled* nil)
      (cl-tpg::*targeted-combined-repair-enabled* nil))
  (check-official-return-credit
   (cl-tpg::official-return-credit-active-p)
   "the isolated return-credit lineage feature gate is active")
  (let ((cl-tpg::*targeted-routing-repair-enabled* t))
    (check-official-return-credit
     (not (cl-tpg::official-return-credit-active-p))
     "targeted repair proposal operators cannot be mixed into return-credit lineage")))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*semantic-locality-control-enabled* t)
      (cl-tpg::*grouped-selection-enabled* t)
      (cl-tpg::*official-return-credit-enabled* t)
      (cl-tpg::*rare-failure-targeted-return-credit-enabled* t)
      (cl-tpg::*targeted-routing-repair-enabled* t)
      (cl-tpg::*targeted-specialist-composition-enabled* t)
      (cl-tpg::*targeted-combined-repair-enabled* t))
  (check-official-return-credit
   (cl-tpg::official-return-credit-active-p)
   "rare-failure diagnostics explicitly gates combined targeted proposals through return credit"))

(let ((cl-tpg::*current-search-seed* 153))
  (cl-tpg::initialize-official-guided-seed-streams 153)
  (let* ((state (cl-tpg::official-guided-seed-state-copy))
         (credit (cl-tpg::official-guided-take-seeds :credit 5)))
    (check-official-return-credit
     (and (= (getf state :version) 3)
          (= (length credit) 5)
          (every (lambda (seed)
                   (= (ash seed (- cl-tpg::+official-guided-seed-payload-bits+))
                      5))
                 credit))
     "credit seeds occupy an independent deterministic namespace")
    (cl-tpg::restore-official-guided-seed-streams state)
    (check-official-return-credit
     (equal credit (cl-tpg::official-guided-take-seeds :credit 5))
     "credit stream resumes from its exact persisted cursor")))

(let ((cl-tpg::*current-search-seed* 153))
  (let ((legacy
          (list :version 1
                :training (list :roots '(1) :cursor 2)
                :racing (list :roots '(2) :cursor 3)
                :promotion (list :roots '(3) :cursor 4)
                :reference (list :roots '(153 42 2026) :cursor 5))))
    (cl-tpg::restore-official-guided-seed-streams legacy)
    (check-official-return-credit
     (and (= (getf cl-tpg::*official-guided-seed-streams* :version) 3)
          (= (getf (getf cl-tpg::*official-guided-seed-streams* :racing)
                   :cursor)
             3)
          (= (getf (getf cl-tpg::*official-guided-seed-streams* :credit)
                   :cursor)
             0)
          (= (getf (getf cl-tpg::*official-guided-seed-streams* :lineage)
                   :cursor)
             0))
     "legacy four-stream checkpoints gain credit and lineage streams without moving old cursors")))

(multiple-value-bind (approved delta margin)
    (cl-tpg::official-return-credit-approve-p
     '(5.0d0 5.0d0 5.0d0 5.0d0 5.0d0)
     '(1.0d0 1.0d0 1.0d0 1.0d0 1.0d0))
  (check-official-return-credit
   (and approved (= delta 4.0d0) (zerop margin))
   "stable positive paired evidence is approved"))

(multiple-value-bind (continue-p delta margin)
    (cl-tpg::official-return-credit-continue-p
     '(0.0d0 0.0d0 0.0d0 0.0d0 0.0d0)
     '(5.0d0 5.0d0 5.0d0 5.0d0 5.0d0))
  (declare (ignore delta margin))
  (check-official-return-credit
   (not continue-p)
   "clearly harmful children stop at the reject-only first stage"))

(let* ((original (symbol-function 'cl-tpg::official-guided-paired-rollouts))
       (calls nil))
  (unwind-protect
       (progn
         (setf (symbol-function 'cl-tpg::official-guided-paired-rollouts)
               (lambda (child parent environment seeds)
                 (declare (ignore child parent environment))
                 (push (copy-list seeds) calls)
                 (values (make-list (length seeds) :initial-element 2.0d0)
                         (make-list (length seeds) :initial-element 1.0d0))))
         (let ((record
                 (cl-tpg::run-official-return-credit-evaluation
                  :child :parent "mock" (loop for seed from 1 to 20 collect seed)
                  '(5 20) '(:top1-hamming 0.01d0))))
           (check-official-return-credit
            (and (getf record :accepted)
                 (eq (getf record :stage) :return-credit-stage-2)
                 (= (getf record :episode-count) 20)
                 (equal (mapcar #'length (nreverse calls)) '(5 15)))
            "sequential credit uses a 5-pair screen then 20 cumulative pairs")))
    (setf (symbol-function 'cl-tpg::official-guided-paired-rollouts) original)))

(let* ((token (get-universal-time))
       (path (merge-pathnames
              (format nil "return-credit-lineage-anchor-~D.lisp" token)
              #p"/tmp/"))
       (team (cl-tpg::%make-team :id "detached-anchor" :learners nil))
       (cl-tpg::*teams* nil)
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*official-return-credit-enabled* t)
       (cl-tpg::*official-return-credit-approved-count* 0)
       (cl-tpg::*official-return-credit-active-lineages* nil)
       (cl-tpg::*official-return-credit-team-lineages*
         (make-hash-table :test #'eq))
       (cl-tpg::*official-return-credit-next-lineage-id* 0))
  (unwind-protect
       (progn
         (cl-tpg::write-best-team-checkpoint team 0.0d0 path)
         (multiple-value-bind (anchor lineage-id evicted)
             (cl-tpg::install-official-return-credit-anchor
              path :generation 17
              :evaluation '(:paired-mean 2.0d0 :margin 1.0d0))
           (check-official-return-credit
            (and (eq (cl-tpg::team-type anchor) :root)
                 (member anchor cl-tpg::*teams* :test #'eq)
                 (= cl-tpg::*official-return-credit-approved-count* 1)
                 (null evicted)
                 (equal lineage-id
                        (cl-tpg::official-return-credit-lineage-for-team
                         anchor))
                 (= (getf (first
                            cl-tpg::*official-return-credit-active-lineages*)
                          :remaining-selection-cycles)
                    cl-tpg::+official-return-credit-protection-generations+))
            "approved anchors establish bounded independent live lineages")
           (let ((child (cl-tpg::%make-team :id "lineage-child"
                                            :learners nil)))
             (cl-tpg::official-return-credit-note-descendant anchor child)
             (check-official-return-credit
              (equal lineage-id
                     (cl-tpg::official-return-credit-lineage-for-team child))
              "children inherit their parent's active credit lineage"))
           (loop repeat cl-tpg::+official-return-credit-protection-generations+
                 do
             (cl-tpg::official-return-credit-note-selection (list anchor)))
           (check-official-return-credit
            (null cl-tpg::*official-return-credit-active-lineages*)
            "lineage protection expires after its frozen selection budget")
           (cl-tpg::install-official-return-credit-anchor
            path :generation 18
            :evaluation '(:paired-mean 3.0d0 :margin 1.0d0))
           (let ((state (cl-tpg::official-return-credit-state-copy)))
             (setf cl-tpg::*teams* nil
                   cl-tpg::*official-return-credit-active-lineages* nil
                   cl-tpg::*official-return-credit-team-lineages*
                     (make-hash-table :test #'eq))
             (cl-tpg::restore-official-return-credit-state state)
             (let* ((restored
                      (first
                       cl-tpg::*official-return-credit-active-lineages*))
                    (restored-team (getf restored :team)))
               (check-official-return-credit
                (and (= (getf state :version) 2)
                     restored-team
                     (member restored-team cl-tpg::*teams* :test #'eq)
                     (equal (getf restored :lineage-id)
                            (cl-tpg::official-return-credit-lineage-for-team
                             restored-team)))
                "runtime state restores an independently serialized active anchor")))))
    (when (probe-file path)
      (delete-file path))))

(let* ((parent (cl-tpg::%make-team :id "priority-parent" :learners nil))
       (neutral (cl-tpg::%make-team :id "priority-neutral" :learners nil))
       (changed (cl-tpg::%make-team :id "priority-changed" :learners nil))
       (lineage-child
         (cl-tpg::%make-team :id "priority-lineage" :learners nil))
       (cl-tpg::*behavioral-team-parents* (make-hash-table :test #'eq))
       (cl-tpg::*behavioral-team-lineage* (make-hash-table :test #'eq))
       (cl-tpg::*official-return-credit-team-lineages*
         (make-hash-table :test #'eq))
       (cl-tpg::*official-return-credit-active-lineages*
         (list (list :lineage-id "L1" :remaining-selection-cycles 3))))
  (dolist (child (list neutral changed lineage-child))
    (setf (gethash child cl-tpg::*behavioral-team-parents*) parent))
  (setf (gethash neutral cl-tpg::*behavioral-team-lineage*)
          '(:top1-hamming 0.0d0 :ranking-distance-mean 0.0d0)
        (gethash changed cl-tpg::*behavioral-team-lineage*)
          '(:top1-hamming 0.1d0 :ranking-distance-mean 0.02d0)
        (gethash lineage-child cl-tpg::*behavioral-team-lineage*)
          '(:top1-hamming 0.1d0 :ranking-distance-mean 0.02d0)
        (gethash lineage-child
                 cl-tpg::*official-return-credit-team-lineages*) "L1")
  (check-official-return-credit
   (and (= (cl-tpg::official-return-credit-candidate-priority neutral) 1)
        (= (cl-tpg::official-return-credit-candidate-priority changed) 3)
        (= (cl-tpg::official-return-credit-candidate-priority lineage-child) 4)
        (eq (car (cl-tpg::official-return-credit-candidate-entry
                  (list (cons neutral 9.0d0)
                        (cons changed 5.0d0)
                        (cons lineage-child 1.0d0))))
            lineage-child))
   "candidate admission prefers changed active-lineage descendants over imitation score"))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*official-return-credit-enabled* t)
      (cl-tpg::*rare-failure-targeted-return-credit-enabled* nil)
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*num-actions* 36)
      (cl-tpg::*decoy-order-mode* :fixed)
      (cl-tpg::*teacher-backend* :heuristic)
      (cl-tpg::*cage2-opening-mode* :fixed)
      (cl-tpg::*hamming-space-enabled* nil)
      (cl-tpg::*recurrent-policy-enabled* nil)
      (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0"))
  (check-official-return-credit
   (search "official-guided-return-credit-lineage"
           (cl-tpg::best-team-checkpoint-filename))
   "return-credit lineage checkpoints have an isolated filename"))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*official-return-credit-enabled* t)
      (cl-tpg::*rare-failure-targeted-return-credit-enabled* t)
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*num-actions* 36)
      (cl-tpg::*decoy-order-mode* :fixed)
      (cl-tpg::*teacher-backend* :heuristic)
      (cl-tpg::*cage2-opening-mode* :fixed)
      (cl-tpg::*hamming-space-enabled* nil)
      (cl-tpg::*recurrent-policy-enabled* nil)
      (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0"))
  (check-official-return-credit
   (search "official-guided-targeted-return-credit"
           (cl-tpg::best-team-checkpoint-filename))
   "rare-failure diagnostics checkpoints cannot overwrite return-credit lineage or grouped selection files"))

(format t "~D official return-credit checks passed.~%"
        *official-return-credit-checks*)
