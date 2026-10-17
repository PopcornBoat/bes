(in-package :cl-user)

(defvar *paired-robustness-checks* 0)

(defun check-paired-robustness (condition description)
  (incf *paired-robustness-checks*)
  (unless condition
    (error "Paired robustness check failed: ~A" description)))

(check-paired-robustness
 (= (cl-tpg::robustness-validate-seed-plan
     '(92011 93011 94011 95011 96011 97011 98011 99011)
     '(30 50 100) 100)
    2400)
 "all 2400 opponent/horizon/root episode seeds are distinct")

(let* ((seed (cl-tpg::robustness-validation-seed 92011 100 0))
       (incumbent
         (list :protocol cl-tpg::+paired-robustness-validation-protocol+
               :red-agent "meander" :horizon 100 :root 92011 :episode 0
               :seed seed :policy :incumbent :return -25.0d0))
       (challenger
         (list :protocol cl-tpg::+paired-robustness-validation-protocol+
               :red-agent "meander" :horizon 100 :root 92011 :episode 0
               :seed seed :policy :challenger :return -23.0d0))
       (records (list incumbent challenger))
       (summary
         (cl-tpg::paired-robustness-summary
          records nil '(92011) '(100) 1 "meander"))
       (delta
         (getf (first (getf summary :aggregate-paired)) :statistics)))
  (check-paired-robustness
   (cl-tpg::paired-robustness-validate-records
    records '(92011) '(100) 1 "meander")
   "matching opponent and seed plan are accepted")
  (check-paired-robustness
   (and (getf summary :complete-p)
        (= (getf summary :completed-records) 2)
        (= (getf delta :mean) 2.0d0)
        (= (getf delta :wins) 1))
   "paired report uses challenger minus incumbent on identical seeds")
  (check-paired-robustness
   (= (hash-table-count
       (cl-tpg::paired-robustness-record-index records))
      2)
   "journal indexing keeps both policies")
  (let ((rejected nil))
    (handler-case
        (cl-tpg::paired-robustness-validate-records
         records '(92011) '(100) 1 "b_line")
      (error () (setf rejected t)))
    (check-paired-robustness rejected
                             "resume rejects a different opponent"))
  (let ((rejected nil))
    (handler-case
        (cl-tpg::paired-robustness-record-index
         (list incumbent incumbent))
      (error () (setf rejected t)))
    (check-paired-robustness rejected
                             "resume rejects duplicate journal entries")))

(format t "Paired robustness checks passed (~D checks).~%"
        *paired-robustness-checks*)
