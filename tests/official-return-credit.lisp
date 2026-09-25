;;; Focused non-simulator checks for Phase-5A paired official return credit.

(in-package :cl-user)

(defvar *official-return-credit-checks* 0)

(defun check-official-return-credit (condition description)
  (incf *official-return-credit-checks*)
  (unless condition
    (error "Official return-credit check failed: ~A" description)))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*semantic-locality-control-enabled* t)
      (cl-tpg::*phase4-selection-enabled* t)
      (cl-tpg::*official-return-credit-enabled* t)
      (cl-tpg::*phase4b-routing-repair-enabled* nil)
      (cl-tpg::*phase4b-specialist-composition-enabled* nil)
      (cl-tpg::*phase4b-combined-repair-enabled* nil))
  (check-official-return-credit
   (cl-tpg::official-return-credit-active-p)
   "the isolated Phase-5A feature gate is active")
  (let ((cl-tpg::*phase4b-routing-repair-enabled* t))
    (check-official-return-credit
     (not (cl-tpg::official-return-credit-active-p))
     "Phase-4b proposal operators cannot be mixed into Phase 5A")))

(let ((cl-tpg::*current-search-seed* 153))
  (cl-tpg::initialize-official-guided-seed-streams 153)
  (let* ((state (cl-tpg::official-guided-seed-state-copy))
         (credit (cl-tpg::official-guided-take-seeds :credit 5)))
    (check-official-return-credit
     (and (= (getf state :version) 2)
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
     (and (= (getf cl-tpg::*official-guided-seed-streams* :version) 2)
          (= (getf (getf cl-tpg::*official-guided-seed-streams* :racing)
                   :cursor)
             3)
          (= (getf (getf cl-tpg::*official-guided-seed-streams* :credit)
                   :cursor)
             0))
     "legacy four-stream checkpoints gain credit without moving old cursors")))

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
              (format nil "phase5a-anchor-~D.lisp" token)
              #p"/tmp/"))
       (team (cl-tpg::%make-team :id "detached-anchor" :learners nil))
       (cl-tpg::*teams* nil)
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*official-return-credit-approved-count* 0))
  (unwind-protect
       (progn
         (cl-tpg::write-best-team-checkpoint team 0.0d0 path)
         (let ((anchor (cl-tpg::install-official-return-credit-anchor path)))
           (check-official-return-credit
            (and (eq (cl-tpg::team-type anchor) :root)
                 (member anchor cl-tpg::*teams* :test #'eq)
                 (= cl-tpg::*official-return-credit-approved-count* 1))
            "approved anchors are independent live roots, not incumbents")))
    (when (probe-file path)
      (delete-file path))))

(let ((cl-tpg::*current-search-mode* :official-guided)
      (cl-tpg::*official-return-credit-enabled* t)
      (cl-tpg::*num-observations* 62)
      (cl-tpg::*num-actions* 36)
      (cl-tpg::*decoy-order-mode* :fixed)
      (cl-tpg::*teacher-backend* :heuristic)
      (cl-tpg::*cage2-opening-mode* :fixed)
      (cl-tpg::*hamming-space-enabled* nil)
      (cl-tpg::*recurrent-policy-enabled* nil)
      (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0"))
  (check-official-return-credit
   (search "official-guided-return-credit"
           (cl-tpg::best-team-checkpoint-filename))
   "Phase-5A checkpoints have an isolated filename"))

(format t "~D official return-credit checks passed.~%"
        *official-return-credit-checks*)
