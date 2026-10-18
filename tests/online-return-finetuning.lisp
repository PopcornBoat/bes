;;; Focused teacher-free return-selection checks. Load :CL-TPG first.
(in-package :cl-user)

(defvar *online-return-checks* 0)

(defun check-online-return (condition description)
  (incf *online-return-checks*)
  (unless condition (error "Online-return check failed: ~A" description)))

(cl-tpg::initialize-official-guided-seed-streams 153)
(let* ((training (cl-tpg::official-guided-take-seeds :training 5))
       (racing (cl-tpg::official-guided-take-seeds :racing 5))
       (promotion (cl-tpg::official-guided-take-seeds :promotion 1000))
       (reference (cl-tpg::official-guided-take-reference-seeds 2))
       (all (append training racing promotion reference)))
  (check-online-return (= (length all) (length (remove-duplicates all)))
                       "training, racing, promotion and monitoring seeds are disjoint")
  (check-online-return
   (equal cl-tpg::+online-return-promotion-stages+ '(30 50 100 1000))
   "fresh cumulative promotion schedule is frozen"))

(let* ((a (list :a)) (b (list :b)) (c (list :c)) (d (list :d))
       (scores (list (cons a 10.0d0) (cons b 9.0d0)
                     (cons c 8.0d0) (cons d 1.0d0)))
       (cl-tpg::*online-return-case-returns* (make-hash-table :test #'eq)))
  (setf (gethash a cl-tpg::*online-return-case-returns*) '(10.0d0 0.0d0)
        (gethash b cl-tpg::*online-return-case-returns*) '(9.0d0 0.0d0)
        (gethash c cl-tpg::*online-return-case-returns*) '(8.0d0 0.0d0)
        (gethash d cl-tpg::*online-return-case-returns*) '(0.0d0 100.0d0))
  (let ((removed (cl-tpg::online-return-diverse-unselected scores scores 2)))
    (check-online-return
     (and (= (length removed) 2)
          (not (member d removed :key #'car :test #'eq))
          (not (member a removed :key #'car :test #'eq)))
     "official per-seed specialist and aggregate champion both survive")))

(let* ((cl-tpg::*online-return-finetuning-enabled* t)
       (cl-tpg::*checkpoint-directory*
         (format nil "~Aonline-return-test-~D/"
                 (namestring (uiop:temporary-directory))
                 (get-universal-time)))
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*num-actions* 36)
       (cl-tpg::*current-search-mode* :online)
       (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0")
       (cl-tpg::*current-search-seed* 153)
       (cl-tpg::*online-return-incumbent-version* 1)
       (cl-tpg::*online-return-submission-count* 3))
  (unwind-protect
       (progn
         (cl-tpg::online-return-persist-runtime)
         (let ((expected
                 (cl-tpg::official-guided-take-seeds :training 3)))
           (cl-tpg::initialize-official-guided-seed-streams 153)
           (cl-tpg::restore-official-guided-seed-streams
            (getf (cl-tpg::read-readable-object
                   (cl-tpg::online-return-state-path)) :seed-streams))
           (check-online-return
            (equal expected (cl-tpg::official-guided-take-seeds :training 3))
            "durable stream cursor exactly reproduces the next episode block")))
    (when (probe-file (cl-tpg::online-return-state-path))
      (delete-file (cl-tpg::online-return-state-path)))))

(let* ((source
         "/home/hardison/bes/validated-checkpoints/bline-v14/bline-62-36-v14.lisp")
       (request-path
         (format nil "~Aonline-return-worker-~D-request.lisp"
                 (namestring (uiop:temporary-directory))
                 (get-universal-time)))
       (result-path
         (format nil "~Aonline-return-worker-~D-result.lisp"
                 (namestring (uiop:temporary-directory))
                 (get-universal-time)))
       (original (symbol-function 'cl-gym:rollout))
       (calls 0))
  (unwind-protect
       (progn
         (cl-tpg::write-readable-object-atomically
          (list :worker-mode :online-return
                :candidate-path source :incumbent-path source
                :result-path result-path
                :candidate-generation 1 :incumbent-version 1
                :gym-environment-name "Cage2-b_line-100-v0"
                :num-observations 62 :num-actions 36
                :decoy-order-mode :fixed :cage2-opening-mode :fixed
                :teacher-backend :heuristic
                :racing-seeds '(1 2 3 4 5)
                :promotion-seeds (loop for i from 100 to 1099 collect i)
                :promotion-stages '(30 50 100 1000)
                :reference-seeds '(2000 2001 2002))
          request-path)
         (setf (symbol-function 'cl-gym:rollout)
               (lambda (&rest ignored)
                 (declare (ignore ignored))
                 (if (oddp (incf calls)) 1.0d0 0.0d0)))
         (cl-tpg::run-official-guided-candidate-evaluation request-path)
         (let* ((result (cl-tpg::read-readable-object result-path))
                (record (getf result :evaluation-record)))
           (check-online-return
            (and (eq (getf result :status) :complete)
                 (getf result :accepted)
                 (eq (getf record :stage) :promotion-stage-4)
                 (eq (getf record :protocol)
                     cl-tpg::+online-return-finetuning-protocol+)
                 (= (getf record :episode-count) 1000)
                 (= (length (getf record :horizon-records)) 3)
                 (= (getf (find 100 (getf record :horizon-records)
                                 :key (lambda (item) (getf item :horizon)))
                           :official-mean)
                    1.0d0))
            "teacher-free worker reaches final paired multi-horizon promotion")))
    (setf (symbol-function 'cl-gym:rollout) original)
    (dolist (path (list request-path result-path))
      (when (probe-file path) (delete-file path)))))

(format t "~D online-return checks passed.~%" *online-return-checks*)
