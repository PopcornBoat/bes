(in-package :cl-tpg)

(defun seed-or-random-seed (seed)
  "The start-search TCP packet will either contain :random or an integer seed.
   If an integer is provided, return it as is. If it is :random, return a random integer."
  (if (eq seed :random)
      (random 9999999999)
      seed))

(defun make-initial-population ()
  "Set the population to an initial set of random candidate solutions."
  (setf *teams* (loop repeat *population-size*
			   collect (make-team))))

(defun accuracy (team dataset)
  (let ((predictions (execute-team-on-dataset team dataset))
	(actuals (actions dataset)))
    (/ (loop for actual across actuals
	  for predicted in predictions
	     count (= actual predicted))
       (length actuals))))

(defun semantic-response-index (response)
  "Return the dataset integer for a decoded semantic RESPONSE, or NIL."
  (case response
    (:analyse 0)
    (:remove 1)
    (:restore 2)
    (:decoy 3)
    (otherwise nil)))

(defun semantic-action-label-matches-p
       (prediction label &optional decoy-mask option-orders)
  "Compare PREDICTION with a canonical (target response option) LABEL.

GLOBAL requires only the target. Host non-Decoy labels require target and
response. A new factored Decoy is resolved through the policy-owned order (or
the agreement default) and the row's DECOY-MASK; a legacy prediction with an
explicit option retains its old comparison. This mirrors the online bridge
contract."
  (destructuring-bind (target response option) label
    (and (= (semantic-action-target prediction) target)
         (or (= target +global-target+)
             (let ((predicted-response
                     (semantic-response-index
                      (semantic-action-response prediction))))
               (and predicted-response
                    (= predicted-response response)
                    (or (/= response 3)
                        (let ((predicted-option
                                (or (semantic-action-option prediction)
                                    (first-available-decoy-option
                                     target decoy-mask option-orders))))
                          (and (integerp predicted-option)
                               (= predicted-option option))))))))))

(defun semantic-label-category-pair (label)
  "Collapse a legacy dataset triple to its ranked target/response label."
  (destructuring-bind (target response option) label
    (declare (ignore option))
    (if (= target +global-target+)
        (list +global-target+ 0)
        (list target response))))

(defun resolve-semantic-ranking (predictions decoy-mask option-orders)
  "Return the first executable target/response pair from PREDICTIONS.

Decoy availability is evaluated from the row mask. If the first choice is an
exhausted Decoy, later candidates are tried without another TPG call. Restore
is intentionally skipped only while falling back, matching the fixed teacher's
next-best rule. Exhausting the ranking safely returns GLOBAL Monitor."
  (loop for prediction in predictions
        for rank fixnum from 0
        for pair = (semantic-action-category-pair prediction)
        for target = (first pair)
        for response = (second pair)
        do (cond
             ((= target +global-target+)
              (return pair))
             ((= response 3)
              (when (integerp
                     (first-available-decoy-option
                      target decoy-mask option-orders))
                (return pair)))
             ((and (> rank 0) (= response 2))
              nil)
             (t
              (return pair)))
        finally (return (list +global-target+ 0))))

(defun semantic-ranking-ndcg (predictions teacher-ranking)
  "Return NDCG for PREDICTIONS under the teacher's frequency-derived order."
  (let* ((teacher-count (length teacher-ranking))
         (relevance (make-hash-table :test #'equal))
         (dcg 0.0d0)
         (ideal 0.0d0))
    (loop for pair in teacher-ranking
          for rank fixnum from 0
          do (setf (gethash pair relevance) (- teacher-count rank))
             (incf ideal
                   (/ (coerce (- teacher-count rank) 'double-float)
                      (log (+ rank 2.0d0) 2.0d0))))
    (loop for prediction in predictions
          for rank fixnum from 0
          for value = (gethash (semantic-action-category-pair prediction)
                               relevance
                               0)
          when (> value 0)
            do (incf dcg
                     (/ (coerce value 'double-float)
                        (log (+ rank 2.0d0) 2.0d0))))
    (if (zerop ideal) 0.0d0 (/ dcg ideal))))

(defun semantic-accuracy (team dataset &optional indices)
  "Return strict hierarchical semantic accuracy for TEAM on DATASET.

When INDICES is supplied, evaluate only those rows. Sampling remains outside
this function so an entire population can share exactly the same batch."
  (let ((correct 0)
        (count 0)
        (observations (observations dataset))
        (labels (actions dataset))
        (decoy-masks (dataset-decoy-masks dataset)))
    (labels ((score-row (index)
               ;; Reference scoring can cover tens of thousands of rows. Check
               ;; periodically so a stop request does not wait for the complete
               ;; held-out dataset to finish.
               (when (and *search-active*
                          (zerop (logand count 255)))
                 (abort-search-if-requested))
                (when (semantic-action-label-matches-p
                       (execute-team-semantic
                        team
                        (policy-observation (aref observations index)))
                      (aref labels index)
                      (aref decoy-masks index)
                      (effective-team-option-orders team))
                 (incf correct))
               (incf count)))
      (if indices
          (loop for index across indices do (score-row index))
          (dotimes (index (dataset-size dataset))
            (score-row index))))
    (if (zerop count)
        0.0d0
        (/ (coerce correct 'double-float)
           (coerce count 'double-float)))))

(defun semantic-ranked-fitness (team dataset &optional indices)
  "Score executable top-choice behavior plus teacher ranking agreement.

The v2 label intentionally ignores concrete Decoy options. Each row contributes
80% when the first usable predicted target/response equals the demonstrated
action and 20% NDCG against that observation's frequency-ranked alternatives."
  (let ((score 0.0d0)
        (count 0)
        (observations (observations dataset))
        (labels (actions dataset))
        (rankings (dataset-semantic-rankings dataset))
        (decoy-masks (dataset-decoy-masks dataset))
        (option-orders (effective-team-option-orders team)))
    (labels ((score-row (index)
               (when (and *search-active*
                          (zerop (logand count 255)))
                 (abort-search-if-requested))
               (let* ((teacher-ranking (aref rankings index))
                      (prediction-limit
                        (min +semantic-ranking-limit+
                             (max 1 (length teacher-ranking))))
                      (predictions
                        (execute-team-semantic-ranked
                         team
                         (policy-observation (aref observations index))
                         prediction-limit))
                      (resolved
                        (resolve-semantic-ranking
                         predictions
                         (aref decoy-masks index)
                         option-orders))
                      (expected
                        (semantic-label-category-pair
                         (aref labels index))))
                 (when (equal resolved expected)
                   (incf score +ranked-behavior-fitness-weight+))
                 (incf score
                       (* +ranked-order-fitness-weight+
                          (semantic-ranking-ndcg
                           predictions teacher-ranking))))
               (incf count)))
      (if indices
          (loop for index across indices do (score-row index))
          (dotimes (index (dataset-size dataset))
            (score-row index))))
    (if (zerop count)
        0.0d0
        (/ score (coerce count 'double-float)))))

(defun semantic-dataset-fitness (team dataset &optional indices)
  "Dispatch semantic fitness according to the dataset protocol generation."
  (ecase (dataset-action-format dataset)
    (:semantic
     (semantic-accuracy team dataset indices))
    (:semantic-ranked
     (semantic-ranked-fitness team dataset indices))))

(defun make-uniform-dataset-indices (dataset)
  "Return an unbalanced uniform sample without replacement, or NIL for all rows."
  (let ((size (dataset-size dataset)))
    (unless (> size 0)
      (error "Cannot sample an empty semantic dataset."))
    (unless (and (integerp *batch-size*) (> *batch-size* 0))
      (error "*BATCH-SIZE* must be a positive integer."))
    (when (< *batch-size* size)
      (let ((chosen (make-hash-table :test #'eql))
            (indices (make-array *batch-size* :element-type 'fixnum)))
        (loop until (= (hash-table-count chosen) *batch-size*)
              do (setf (gethash (random size) chosen) t))
        (let ((position 0))
          (maphash (lambda (index ignored)
                     (declare (ignore ignored))
                     (setf (aref indices position) index)
                     (incf position))
                   chosen))
        (sort indices #'<)))))

(defun semantic-offline-training-fitness (team)
  "Evaluate TEAM on the uniform row batch shared by this generation."
  (unless *offline-training-dataset*
    (error "Semantic offline training dataset is not configured."))
  (unless *offline-fitness-batch-indices*
    (setf *offline-fitness-batch-indices*
          (or (make-uniform-dataset-indices *offline-training-dataset*)
              :all)))
  (semantic-dataset-fitness
   team
   *offline-training-dataset*
   (unless (eq *offline-fitness-batch-indices* :all)
     *offline-fitness-batch-indices*)))

(defun semantic-offline-reference-fitness (team)
  "Evaluate TEAM on the complete fixed held-out semantic dataset."
  (unless *offline-reference-dataset*
    (error "Semantic offline reference dataset is not configured."))
  (semantic-dataset-fitness team *offline-reference-dataset*))

(defun semantic-validation-dataset-path (training-path)
  "Infer the sibling validation path from a semantic training dataset path."
  (let* ((path (pathname training-path))
         (name (pathname-name path))
         (suffix "_train")
         (validation-name
           (if (and (>= (length name) (length suffix))
                    (string= suffix
                             (subseq name (- (length name)
                                             (length suffix)))))
               (concatenate 'string
                            (subseq name 0 (- (length name) (length suffix)))
                            "_val")
               (concatenate 'string name "_val"))))
    (make-pathname :name validation-name :defaults path)))

(defun dataset-file-fingerprint (dataset)
  "Return a portable name/byte-size identity for DATASET's source file."
  (let ((path (pathname (dataset-source-path dataset))))
    (list :name (file-namestring path)
          :bytes (with-open-file
                     (stream path
                             :direction :input
                             :element-type '(unsigned-byte 8))
                   (file-length stream)))))

(defun arithmetic-mean (values)
  "Return the arithmetic mean of VALUES as a double-float."
  (if (null values)
      0.0d0
      (let ((sum
        (coerce
         (reduce #'+
                 values
                 :initial-value 0.0d0)
         'double-float)))

        (/ sum
           (coerce (length values)
                   'double-float)))))

(defun numeric-median (values)
  "Return the median of VALUES as a double-float."
  (if (null values)
      0.0d0
      (let* ((sorted (sort (copy-list values) #'<))
             (n (length sorted))
             (middle (floor n 2)))
        (if (oddp n)
            (coerce (nth middle sorted)
                    'double-float)
            (/ (coerce (+ (nth (1- middle) sorted)
                          (nth middle sorted))
                       'double-float)
               2.0d0)))))

(defun abort-search-if-requested ()
  "Leave the current search promptly after a stop request.

The non-local exit is caught by RUN-SEARCH or RUN-SEARCH-FROM-BEST-TEAM.  It is
not an error and therefore is not converted into a bad-team fitness result."
  (unless *running*
    (throw 'search-stop-requested nil)))

(defun make-online-fitness-episode-seeds
       (&optional root-seed (episode-count *online-fitness-episodes*))
  "Return one seed per online-fitness episode.

With ROOT-SEED, derive a reproducible seed bank without consuming the search
random state. Without it, consume the search random state so each generation
receives a new batch."
  (unless (and (integerp episode-count) (> episode-count 0))
    (error "Episode count must be a positive integer, got ~S." episode-count))

  (let ((*random-state*
          (if root-seed
              (sb-ext:seed-random-state root-seed)
              *random-state*)))
    (loop repeat episode-count
          collect (random 9999999))))

(defun online-fitness-episodes-for-generation (generation)
  "Return the active online training episode count for GENERATION.

Requesting five episodes enables the reproducible 5 -> 10 -> 20 curriculum.
Any other launch value remains fixed for controlled comparison runs."
  (if (= *configured-online-fitness-episodes* 5)
      (loop with result = 5
            for (start . episodes) in +online-fitness-episode-schedule+
            when (>= generation start) do (setf result episodes)
            finally (return result))
      *configured-online-fitness-episodes*))

(defun update-online-fitness-stage ()
  "Apply and report the episode stage used by this online CAGE2 generation."
  (when (and (eq *current-search-mode* :online)
             (cl-gym:cage2-environment-p *current-gym-environment-name*))
    (let ((episodes (online-fitness-episodes-for-generation *generation*)))
      (unless (= episodes *online-fitness-episodes*)
        (setf *online-fitness-episodes* episodes)
        (emit-message
         (format nil
                 "Online fitness stage changed: generation=~D episodes=~D."
                 *generation*
                 episodes))))))

(defun cage2-fitness-on-seeds (team gym-environment-name episode-seeds)
  "Evaluate TEAM on the exact CAGE2 EPISODE-SEEDS and return mean reward."
  (arithmetic-mean
   (loop for episode-seed in episode-seeds
         do (abort-search-if-requested)
         collect
         (cl-gym:rollout team gym-environment-name episode-seed))))

(defun cage2-reference-scores (team gym-environment-name)
  "Return TEAM rewards on the protected fixed 100-episode seed bank."
  (let ((seeds
          (make-online-fitness-episode-seeds
           +cage2-evaluation-seed+
           +cage2-online-reference-episodes+)))
    (loop for episode-seed in seeds
          do (abort-search-if-requested)
          collect (cl-gym:rollout team gym-environment-name episode-seed))))

(defun cage2-reference-fitness (team gym-environment-name)
  "Evaluate TEAM on the protected fixed CAGE2 reference bank."
  (arithmetic-mean (cage2-reference-scores team gym-environment-name)))

(defun sample-standard-error (values)
  "Return the sample standard error of numeric VALUES."
  (if (< (length values) 2)
      0.0d0
      (let* ((mean (arithmetic-mean values))
             (n (length values))
             (sum-of-squares
               (loop for value in values
                     for delta = (- (coerce value 'double-float) mean)
                     sum (* delta delta) into total
                     finally (return (coerce total 'double-float))))
             (variance
               (/ sum-of-squares (coerce (1- n) 'double-float))))
        (/ (sqrt variance) (sqrt (coerce n 'double-float))))))

(defun online-reference-promotion-p (candidate-scores incumbent-scores)
  "Require a positive paired one-standard-error improvement over INCUMBENT."
  (if (null incumbent-scores)
      t
      (let* ((differences (mapcar #'- candidate-scores incumbent-scores))
             (mean-difference (arithmetic-mean differences))
             (margin
               (* +cage2-online-promotion-standard-errors+
                  (sample-standard-error differences))))
        (values (> mean-difference margin) mean-difference margin))))

(defun online-candidate-screen-worthy-p (candidate-scores incumbent-scores)
  "Return true unless the first-stage paired sample already shows futility.

The screen is deliberately permissive: it continues to the complete reference
bank whenever the paired mean plus one standard error is positive. The final
promotion still requires the stricter positive one-standard-error improvement."
  (let* ((differences (mapcar #'- candidate-scores incumbent-scores))
         (mean-difference (arithmetic-mean differences))
         (uncertainty
           (* +online-candidate-screen-standard-errors+
              (sample-standard-error differences))))
    (values (> (+ mean-difference uncertainty) 0.0d0)
            mean-difference
            uncertainty)))

(defun read-readable-object (path)
  "Read one printed Common Lisp object from PATH using standard syntax."
  (with-open-file (stream path :direction :input)
    (with-standard-io-syntax
      (read stream))))

(defun write-readable-object-atomically (object path)
  "Write OBJECT beside PATH and atomically publish the completed file."
  (let* ((destination (pathname path))
         (temporary
           (make-pathname
            :name (format nil ".~A-~D"
                          (or (pathname-name destination) "result")
                          (get-universal-time))
            :type "tmp"
            :defaults destination)))
    (ensure-directories-exist destination)
    (unwind-protect
         (progn
           (with-open-file (stream temporary
                                   :direction :output
                                   :if-exists :supersede
                                   :if-does-not-exist :create)
             (with-standard-io-syntax
               (let ((*print-circle* t)
                     (*print-readably* t)
                     (*print-pretty* nil))
                 (write object :stream stream))))
           (uiop:rename-file-overwriting-target temporary destination))
      (when (probe-file temporary)
        (delete-file temporary)))
    destination))

(defun online-candidate-evaluation-enabled-p ()
  "Return true when CAGE2 online search has a replayable incumbent bank."
  (and (eq *current-search-mode* :online)
       *current-gym-environment-name*
       (cl-gym:cage2-environment-p *current-gym-environment-name*)
       *checkpoint-directory*
       *best-fitness*
       (= (length *online-best-reference-scores*)
          +cage2-online-reference-episodes+)))

(defun reset-online-candidate-evaluation-state ()
  "Discard local staged-evaluator state before a fresh or resumed search."
  (when (and *online-candidate-process*
             (ignore-errors
               (uiop:process-alive-p *online-candidate-process*)))
    (ignore-errors
      (uiop:terminate-process *online-candidate-process*)))
  (setf *online-candidate-process* nil
        *online-candidate-job* nil
        *online-candidate-next-submit-generation*
          (+ *generation* +online-candidate-evaluation-interval+)
        *online-staged-best-team* nil
        *online-staged-best-fitness* nil
        *online-staged-best-generation* nil))

(defun online-candidate-directory ()
  "Return the private staged-evaluation directory for this checkpoint run."
  (checkpoint-path *checkpoint-directory* ".online-candidates/"))

(defun online-candidate-path (generation kind type)
  "Return one unique artifact path for GENERATION, KIND, and pathname TYPE."
  (merge-pathnames
   (make-pathname
    :name (format nil "generation-~D-~A" generation kind)
    :type type)
   (uiop:ensure-directory-pathname (online-candidate-directory))))

(defun write-online-candidate-checkpoint (team training-fitness generation path)
  "Write frozen TEAM to the evaluator's private candidate checkpoint PATH."
  (write-best-team-checkpoint
   team
   training-fitness
   path
   :generation generation
   :gym-environment-name *current-gym-environment-name*
   :online-fitness-episodes *online-fitness-episodes*
   :search-seed *current-search-seed*
   :fitness-evaluation-protocol +cage2-online-fitness-protocol+
   :dataset-name *current-dataset-name*
   :dataset-fingerprint *current-dataset-fingerprint*
   :action-agreement-signature (action-agreement-signature)
   :online-reference-episodes +cage2-online-reference-episodes+
   :mixed-training-lineage *mixed-training-lineage*
   :hamming-space-enabled *hamming-space-enabled*
   :hamming-dataset-fingerprint *current-hamming-dataset-fingerprint*
   :num-observations *num-observations*
   :decoy-order-mode *decoy-order-mode*
   :cage2-opening-mode *cage2-opening-mode*
   :recurrent-policy-enabled *recurrent-policy-enabled*))

(defun note-online-generation-candidate (team fitness)
  "Retain the strongest training winner seen in the current submission window."
  (when (or (null *online-staged-best-fitness*)
            (> fitness *online-staged-best-fitness*))
    (setf *online-staged-best-team*
            (deep-copy-team-via-serialization team)
          *online-staged-best-fitness* fitness
          *online-staged-best-generation* *generation*)))

(defun launch-online-candidate-evaluation ()
  "Publish the accumulated candidate and start its independent SBCL worker."
  (let* ((generation *online-staged-best-generation*)
         (training-fitness *online-staged-best-fitness*)
         (candidate-path
           (online-candidate-path generation "candidate" "lisp"))
         (request-path
           (online-candidate-path generation "request" "lisp"))
         (result-path
           (online-candidate-path generation "result" "lisp"))
         (log-path
           (online-candidate-path generation "worker" "log"))
         (worker-script
           (merge-pathnames
            "scripts/run-online-candidate-evaluation.lisp"
            (asdf:system-source-directory :cl-tpg))))
    (unless (and generation *online-staged-best-team*)
      (error "Cannot submit an empty online candidate window."))
    (write-online-candidate-checkpoint
     *online-staged-best-team* training-fitness generation candidate-path)
    (write-readable-object-atomically
     (list :version 1
           :candidate-path (namestring candidate-path)
           :result-path (namestring result-path)
           :candidate-generation generation
           :candidate-training-fitness training-fitness
           :incumbent-fitness *best-fitness*
           :incumbent-scores (copy-list *online-best-reference-scores*)
           :gym-environment-name *current-gym-environment-name*
           :num-observations *num-observations*
           :num-actions *num-actions*
           :decoy-order-mode *decoy-order-mode*
           :cage2-opening-mode *cage2-opening-mode*
           :recurrent-policy-enabled *recurrent-policy-enabled*
           :hamming-space-enabled *hamming-space-enabled*
           :hamming-dataset-name *hamming-dataset-name*
           :reference-episodes +cage2-online-reference-episodes+
           :screen-episodes +online-candidate-screen-episodes+)
     request-path)
    (setf *online-candidate-process*
            (uiop:launch-program
             (list "sbcl"
                   "--dynamic-space-size" "4096"
                   "--noinform" "--non-interactive"
                   "--load" (namestring worker-script)
                   "--end-toplevel-options"
                   (namestring request-path))
             :input nil
             :output log-path
             :error-output :output
             :if-output-exists :supersede
             :ignore-error-status t)
          *online-candidate-job*
            (list :generation generation
                  :training-fitness training-fitness
                  :candidate-path candidate-path
                  :request-path request-path
                  :result-path result-path
                  :log-path log-path
                  :incumbent-fitness *best-fitness*)
          *online-candidate-next-submit-generation*
            (+ *generation* +online-candidate-evaluation-interval+)
          *online-staged-best-team* nil
          *online-staged-best-fitness* nil
          *online-staged-best-generation* nil)
    (emit-message
     (format nil
             "Generation ~D submitted to independent online evaluator: training-fitness=~A screen=~D reference=~D."
             generation training-fitness
             +online-candidate-screen-episodes+
             +cage2-online-reference-episodes+))))

(defun staged-incumbent-current-p (result)
  "Reject a worker result if the in-memory incumbent changed meanwhile."
  (fitness-values-equivalent-p
   (getf result :incumbent-fitness)
   *best-fitness*))

(defun consume-online-candidate-result (result)
  "Apply one completed worker RESULT on the main search thread."
  (let ((generation (getf result :candidate-generation))
        (candidate-path (getf *online-candidate-job* :candidate-path)))
    (cond
      ((eq (getf result :status) :error)
       (emit-message
        (format nil
                "Independent evaluator failed for generation ~D: ~A"
                generation (getf result :message))))
      ((not (staged-incumbent-current-p result))
       (emit-message
        (format nil
                "Independent evaluator discarded stale generation ~D result: evaluated-incumbent=~A current-incumbent=~A."
                generation (getf result :incumbent-fitness) *best-fitness*)))
      ((not (getf result :accepted))
       (emit-message
        (format nil
                "Independent evaluator rejected generation ~D at ~A: candidate=~A incumbent=~A paired-delta=~,4F margin=~,4F."
                generation
                (getf result :stage)
                (getf result :candidate-fitness)
                (getf result :incumbent-fitness)
                (getf result :paired-delta)
                (getf result :margin))))
      (t
       (let ((candidate-team (load-best-team candidate-path)))
         (ensure-team-observation-compatible
          candidate-team *num-observations*)
         (setf *best-team* candidate-team
               *best-fitness* (getf result :candidate-fitness)
               *online-best-reference-scores*
                 (copy-list (getf result :candidate-scores)))
         (emit-message
          (format nil
                  "NEW GLOBAL BEST: generation=~D independent-reference-fitness=~A training-fitness=~A paired-delta=~,4F required-margin=~,4F."
                  generation
                  *best-fitness*
                  (getf result :candidate-training-fitness)
                  (getf result :paired-delta)
                  (getf result :margin)))
         ;; Record the generation that produced the accepted graph, not the
         ;; later generation at which the main thread noticed the result.
         (let ((*generation* generation))
           (save-best-team)))))))

(defun poll-online-candidate-evaluation ()
  "Consume a completed staged evaluator result without blocking evolution."
  (when *online-candidate-job*
    (let ((result-path (getf *online-candidate-job* :result-path)))
      (cond
        ((probe-file result-path)
         (handler-case
             (consume-online-candidate-result
              (read-readable-object result-path))
           (error (condition)
             (emit-message
              (format nil
                      "Could not consume independent evaluator result: ~A"
                      condition))))
         (setf *online-candidate-process* nil
               *online-candidate-job* nil))
        ((and *online-candidate-process*
              (not (ignore-errors
                     (uiop:process-alive-p
                      *online-candidate-process*))))
         (emit-message
          (format nil
                  "Independent evaluator exited without a result; see ~A"
                  (namestring
                   (getf *online-candidate-job* :log-path))))
         (setf *online-candidate-process* nil
               *online-candidate-job* nil))))))

(defun maybe-launch-online-candidate-evaluation ()
  "Submit the accumulated window when its deadline arrives and no worker runs."
  (when (and (online-candidate-evaluation-enabled-p)
             (null *online-candidate-job*)
             *online-staged-best-team*
             (>= *generation*
                 *online-candidate-next-submit-generation*))
    (launch-online-candidate-evaluation)))

(defun run-online-candidate-evaluation (request-path)
  "Worker entry point for a staged online candidate evaluation REQUEST-PATH."
  (let* ((request (read-readable-object request-path))
         (result-path (pathname (getf request :result-path)))
         (started (get-universal-time)))
    (labels ((publish (result)
               (write-readable-object-atomically
                (append result
                        (list :elapsed-seconds
                              (- (get-universal-time) started)))
                result-path)))
      (handler-case
          (let* ((*running* t)
                 (*search-active* nil)
                 (*current-search-mode* :online)
                 (*current-gym-environment-name*
                   (getf request :gym-environment-name))
                 (*num-observations* (getf request :num-observations))
                 (*num-actions* (getf request :num-actions))
                 (*decoy-order-mode* (getf request :decoy-order-mode))
                 (*cage2-opening-mode* (getf request :cage2-opening-mode))
                 (*recurrent-policy-enabled*
                   (not (null (getf request :recurrent-policy-enabled))))
                 (*hamming-space-enabled*
                   (getf request :hamming-space-enabled))
                 (*hamming-dataset-name*
                   (getf request :hamming-dataset-name))
                 (*factored-actions-enabled* t)
                 (reference-count (getf request :reference-episodes))
                 (screen-count (getf request :screen-episodes))
                 (incumbent-scores (getf request :incumbent-scores))
                 (team (load-best-team (getf request :candidate-path)))
                 (seeds
                   (make-online-fitness-episode-seeds
                    +cage2-evaluation-seed+ reference-count)))
            (unless (= reference-count (length incumbent-scores))
              (error "Incumbent score count ~D does not match reference count ~D."
                     (length incumbent-scores) reference-count))
            (unless (<= 1 screen-count reference-count)
              (error "Invalid staged screen size ~S for ~D references."
                     screen-count reference-count))
            (configure-hamming-observation-space)
            (ensure-team-observation-compatible team *num-observations*)
            (let* ((screen-scores
                     (loop for seed in seeds
                           repeat screen-count
                           collect
                           (cl-gym:rollout
                            team *current-gym-environment-name* seed)))
                   (incumbent-screen
                     (subseq incumbent-scores 0 screen-count)))
              (multiple-value-bind
                    (continue-p screen-delta screen-uncertainty)
                  (online-candidate-screen-worthy-p
                   screen-scores incumbent-screen)
                (if (not continue-p)
                    (publish
                     (list :status :complete
                           :accepted nil
                           :stage :screen
                           :candidate-generation
                             (getf request :candidate-generation)
                           :candidate-training-fitness
                             (getf request :candidate-training-fitness)
                           :candidate-fitness
                             (arithmetic-mean screen-scores)
                           :incumbent-fitness
                             (getf request :incumbent-fitness)
                           :paired-delta screen-delta
                           :margin screen-uncertainty
                           :evaluated-episodes screen-count))
                    (let* ((remaining-scores
                             (loop for seed in (nthcdr screen-count seeds)
                                   collect
                                   (cl-gym:rollout
                                    team
                                    *current-gym-environment-name*
                                    seed)))
                           (candidate-scores
                             (append screen-scores remaining-scores)))
                      (multiple-value-bind (accepted delta margin)
                          (online-reference-promotion-p
                           candidate-scores incumbent-scores)
                        (publish
                         (list :status :complete
                               :accepted accepted
                               :stage :reference
                               :candidate-generation
                                 (getf request :candidate-generation)
                               :candidate-training-fitness
                                 (getf request :candidate-training-fitness)
                               :candidate-fitness
                                 (arithmetic-mean candidate-scores)
                               :candidate-scores candidate-scores
                               :incumbent-fitness
                                 (getf request :incumbent-fitness)
                               :paired-delta delta
                               :margin margin
                               :screen-delta screen-delta
                               :screen-uncertainty screen-uncertainty
                               :evaluated-episodes reference-count))))))))
        (error (condition)
          (publish
           (list :status :error
                 :accepted nil
                 :candidate-generation
                   (getf request :candidate-generation)
                 :incumbent-fitness
                   (getf request :incumbent-fitness)
                 :message (princ-to-string condition)))))))
  t)

(defun online-fitness (team gym-environment-name)
  "Evaluate TEAM over *ONLINE-FITNESS-EPISODES* complete episodes.

Within one CAGE2 population evaluation, every candidate uses the same episode
seed list. EVALUATE clears the list before each generation, so later
generations receive new episodes instead of repeatedly training on the seed-153
reference batch."
  (unless (and (integerp *online-fitness-episodes*)
               (> *online-fitness-episodes* 0))
    (error "*ONLINE-FITNESS-EPISODES* must be a positive integer."))

  (if (cl-gym:cage2-environment-p gym-environment-name)
      (cage2-fitness-on-seeds
       team
       gym-environment-name
       (or *online-fitness-episode-seeds*
           (setf *online-fitness-episode-seeds*
                 (make-online-fitness-episode-seeds))))
      (arithmetic-mean
       (loop repeat *online-fitness-episodes*
             do (abort-search-if-requested)
             collect
             (cl-gym:rollout team
                             gym-environment-name
                             (random 9999999))))))
            	  
(defun make-fitness-function (&key gym-environment-name dataset-name)
  (cond
    (gym-environment-name
     (setf *factored-actions-enabled*
             (not (null (cl-gym:cage2-environment-p gym-environment-name)))
           *offline-training-dataset* nil
           *offline-reference-dataset* nil
           *teacher-training-dataset* nil
           *teacher-reference-dataset* nil
           *offline-fitness-batch-indices* nil
           *teacher-dagger-replay-rows* nil
           *teacher-dagger-random-state* nil
           *current-dataset-fingerprint* nil)
     (configure-hamming-observation-space)
     (setf *fitness-fn*
           (lambda (team)
             (online-fitness team gym-environment-name))))

    (dataset-name
     (let ((dataset (load-dataset dataset-name)))
       (setf *teacher-training-dataset* nil
             *teacher-reference-dataset* nil
             *teacher-dagger-replay-rows* nil
             *teacher-dagger-random-state* nil)
       (setf *factored-actions-enabled*
             (not (null (semantic-dataset-p dataset))))
       (if (semantic-dataset-p dataset)
           (let* ((reference-path
                    (semantic-validation-dataset-path
                     (dataset-source-path dataset)))
                  (reference-file (probe-file reference-path)))
             (unless reference-file
               (error "Semantic validation dataset not found: ~A"
                      (namestring reference-path)))
             (let ((reference-dataset (load-dataset reference-file)))
               (unless (eq (dataset-action-format reference-dataset)
                           (dataset-action-format dataset))
                 (error "Semantic validation path contains a legacy dataset: ~A"
                        (namestring reference-file)))
                (setf *offline-training-dataset* dataset
                     *offline-reference-dataset* reference-dataset
                     *offline-fitness-batch-indices* nil
                     *current-dataset-fingerprint*
                       (list :training (dataset-file-fingerprint dataset)
                             :reference
                             (dataset-file-fingerprint reference-dataset))
                      *fitness-fn* #'semantic-offline-training-fitness)))
           (progn
             (setf *offline-training-dataset* nil
                   *offline-reference-dataset* nil
                   *offline-fitness-batch-indices* nil
                   *current-dataset-fingerprint* nil)
              (setf *fitness-fn*
                    (lambda (team)
                      (accuracy team dataset)))))
       (configure-hamming-observation-space
        (and (semantic-dataset-p dataset)
             dataset))))

    (t
     (error "Neither GYM-ENVIRONMENT-NAME nor DATASET-NAME was supplied."))))

(defun configure-fitness-function (mode gym-environment-name dataset-name)
  "Configure *FITNESS-FN* according to MODE."
  (ecase mode
    (:online
     (make-fitness-function :gym-environment-name gym-environment-name))
    (:offline
     (make-fitness-function :dataset-name dataset-name))
    (:teacher-forcing
     (configure-teacher-forcing-fitness gym-environment-name))))

(defun safe-evaluate-team (team)
  (cons team
        (handler-case
            (funcall *fitness-fn* team)

          (floating-point-overflow (e) :bad)
          (floating-point-invalid-operation (e) :bad)
          (division-by-zero (e) :bad)

          (error (e)
            (format t "~&[safe-evaluate-team] ERROR: ~A~%" e)
            #+sbcl (sb-debug:print-backtrace :stream *standard-output*)
            :bad))))
            
(defun evaluate ()
  "Returns a list of (team . fitness), skipping and deleting bad teams."
  (update-online-fitness-stage)
  ;; The first CAGE2 team lazily creates a seed list after this reset. Every
  ;; root team reads that same list; the next population evaluation gets a new
  ;; list generated from the search random state.
  (setf *online-fitness-episode-seeds* nil
        *offline-fitness-batch-indices* nil)
  (when (eq *current-search-mode* :teacher-forcing)
    (setf *teacher-training-dataset* nil)
    (prepare-teacher-training-dataset))
  (let* ((results
           (mapcar (lambda (team)
                     (abort-search-if-requested)
                     (safe-evaluate-team team))
                   (root-teams)))
         (bad-teams (loop for (team . fitness) in results
                          when (eq fitness :bad)
                            collect team))
         (good-results (remove :bad results :key #'cdr)))
    ;; Do mutation/deletion serially.
    (dolist (team bad-teams)
      (delete-team team))
    good-results))

(defun current-reference-evaluation (team training-fitness)
  "Return TEAM's comparable historical score for the active fitness protocol."
  (let ((reference-kind
          (cond
            ((eq *current-search-mode* :teacher-forcing)
             :teacher-forcing)
            ((and *current-gym-environment-name*
                  (cl-gym:cage2-environment-p
                   *current-gym-environment-name*))
             :cage2)
            (*offline-reference-dataset* :offline)
            (t nil))))
    (if (null reference-kind)
        training-fitness
        (let ((started (get-internal-real-time)))
          (emit-message
           (format nil
                   "Generation ~D ~A reference evaluation started."
                   *generation* reference-kind))
          (multiple-value-bind (result detail)
              (ecase reference-kind
                (:teacher-forcing
                 (values (teacher-forcing-reference-fitness team) nil))
                (:cage2
                 (let ((scores
                         (cage2-reference-scores
                          team
                          *current-gym-environment-name*)))
                   (values (arithmetic-mean scores) scores)))
                (:offline
                 (values (semantic-offline-reference-fitness team) nil)))
            (emit-message
             (format nil
                     "Generation ~D ~A reference evaluation finished in ~,2F seconds."
                     *generation*
                     reference-kind
                     (/ (- (get-internal-real-time) started)
                        (coerce internal-time-units-per-second
                                'double-float))))
            (values result detail))))))

(defun current-reference-fitness (team training-fitness)
  "Return only the scalar part of CURRENT-REFERENCE-EVALUATION."
  (nth-value 0 (current-reference-evaluation team training-fitness)))

(defun complexity-key-less-p (left right)
  "Return true when lexicographic complexity key LEFT is smaller than RIGHT."
  (loop for left-value in left
        for right-value in right
        when (< left-value right-value) do (return t)
        when (> left-value right-value) do (return nil)
        finally (return nil)))

(defun select (scores)
  "Remove GAP percent of the population by removing the worst teams.

Maintain a frozen deep copy of the historical best team. Whenever a new
global best is discovered, immediately deep-copy the complete TPG graph
through serialization/deserialization and save it to disk."

  (unless scores
    (error "Cannot select from an empty score list."))

  (let* ((complexities (make-hash-table :test #'eq))
         (sorted
           (progn
             (dolist (entry scores)
               (setf (gethash (car entry) complexities)
                     (policy-complexity-key (car entry))))
             (stable-sort
              (copy-list scores)
              (lambda (left right)
                (let ((left-fitness (cdr left))
                      (right-fitness (cdr right)))
                  (if (= left-fitness right-fitness)
                      (complexity-key-less-p
                       (gethash (car left) complexities)
                       (gethash (car right) complexities))
                      (> left-fitness right-fitness)))))))

         (fitness-values
           (mapcar #'cdr sorted))

         (n-remove
           (floor (* *gap* (length sorted))))

         (worst-entries
           (if (> n-remove 0)
               (last sorted n-remove)
               nil))

         (best-entry
           (first sorted))

         (generation-best
           (cdr best-entry))

         (generation-best-team
           (car best-entry))

         (historical-candidate-fitness nil)

         (historical-candidate-detail nil)

         (population-mean
           (arithmetic-mean fitness-values))

         (population-median
           (numeric-median fitness-values))

         (population-worst
           (reduce #'min
                   fitness-values
                   :initial-value
                   most-positive-double-float))
         (staged-online-p
           (online-candidate-evaluation-enabled-p)))

    (when staged-online-p
      (poll-online-candidate-evaluation)
      (note-online-generation-candidate
       generation-best-team generation-best)
      (maybe-launch-online-candidate-evaluation))

    (unless staged-online-p
      (multiple-value-setq
          (historical-candidate-fitness historical-candidate-detail)
        (current-reference-evaluation
         generation-best-team
         generation-best))

      ;; Non-online modes retain synchronous reference selection. The first
      ;; generation of a fresh online run also establishes its incumbent here;
      ;; later online candidates go through the independent staged worker.
      (multiple-value-bind (promotion-p mean-difference promotion-margin)
          (if (and (eq *current-search-mode* :online)
                   (cl-gym:cage2-environment-p
                    *current-gym-environment-name*)
                   *best-fitness*)
              (online-reference-promotion-p
               historical-candidate-detail
               *online-best-reference-scores*)
              (values (or (null *best-fitness*)
                          (> historical-candidate-fitness *best-fitness*))
                      nil
                      nil))
        (when (and *best-fitness*
                   (> historical-candidate-fitness *best-fitness*)
                   (not promotion-p))
          (emit-message
           (format nil
                   "Online best promotion rejected as noise: candidate=~A incumbent=~A paired-delta=~,4F required-margin=~,4F."
                   historical-candidate-fitness
                   *best-fitness*
                   mean-difference
                   promotion-margin)))

        (when promotion-p

          (let ((frozen-best-team
                  (deep-copy-team-via-serialization
                   generation-best-team)))

            (setf *best-fitness* historical-candidate-fitness
                  *best-team* frozen-best-team
                  *online-best-reference-scores*
                    (and historical-candidate-detail
                         (copy-list historical-candidate-detail)))

            (emit-message
             (format nil
                     "NEW GLOBAL BEST: generation=~A reference-fitness=~A training-fitness=~A. "
                     *generation*
                     *best-fitness*
                     generation-best))

            ;; Save immediately, before reproduce/mutation/deletion.
            (when *checkpoint-directory*
              (save-best-team))))))

    ;; ------------------------------------------------------------
    ;; Telemetry
    ;; ------------------------------------------------------------

    (multiple-value-bind
          (team-count learner-count instruction-count
           max-team-size max-program-size)
        (teams-complexity *teams*)
      (emit-fitness-scores
       (telemetry-island-id)
       generation-best
       *best-fitness*
       population-mean
       population-median
       population-worst
       *generation*
       :online-fitness-episodes *online-fitness-episodes*
       :team-count team-count
       :learner-count learner-count
       :instruction-count instruction-count
       :max-team-size max-team-size
       :max-program-size max-program-size
       :elapsed-seconds
         (and *search-start-time*
              (- (get-universal-time) *search-start-time*))))

    ;; ------------------------------------------------------------
    ;; Selection
    ;; ------------------------------------------------------------

    (dolist (entry worst-entries)
      (delete-team (car entry)))))

(defun should-send-migrants-p ()
  "Returns T periodically when the generation matches the migration interval."
  (and (> *generation* 0)
       (= (mod *generation* *migration-interval*) 0)))

(defun send-migrants (evaluation-scores)
  "Periodically send the best individual from this island to another island."
  (let* ((island-id (who-am-i))
	 (neighbours (get-neighbour-ids island-id)))
    (when neighbours
      (let ((random-neighbour (random-choice neighbours))
	    (best-individual (car (alexandria:extremum evaluation-scores #'> :key #'cdr))))
	(send-migrant-over-socket random-neighbour best-individual)))))

(defun receive-migrants ()
  "Replaces the worst individuals unless the migration buffer
   exceeds the population size (albeit unlikely) in which case
   it simply adds them all to the population."

  ;; Internal teams are added unconditionally
  (loop for internal-team = (pop-internal-team)
	while internal-team
	do (push internal-team *teams*))

  ;; Root teams compete for the 'worst' slots.
  (loop for root-team = (pop-root-team)
	while root-team
	do (push root-team *teams*)))

(defun reproduce ()
  (loop while (< (length (root-teams)) *population-size*)
	do (mutate-team (clone-team (random-choice (root-teams))))))

(defun evolve ()
  "Evolve the population for a single generation."
  (abort-search-if-requested)
  (receive-migrants)

  (let ((evaluation-scores (evaluate)))

    ;; Do not select, checkpoint, migrate, or reproduce a partially evaluated
    ;; generation after the user has requested that the search stop.
    (abort-search-if-requested)

    (when (should-send-migrants-p)
      (send-migrants evaluation-scores))

    (select evaluation-scores)
    
    (reproduce)))

(defun run-search (mode gym-environment-name dataset-name seed)
  "Search the solution space with a tangled program graph."
  (let* ((seed (seed-or-random-seed seed))
         (captured-state (sb-ext:seed-random-state seed)))
    (setf *random-state* captured-state
          *current-search-mode* mode
          *current-gym-environment-name* gym-environment-name
          *current-search-seed* seed
          *current-dataset-name* (and (eq mode :offline) dataset-name)
          *mixed-training-lineage* nil
          *online-best-reference-scores* nil
          *search-start-time* (get-universal-time))

    (catch 'search-stop-requested
      (setf *teams* nil)
      (setf *generation* 1)
      (reset-online-candidate-evaluation-state)
      (setf *best-team* nil)
      (setf *best-fitness* nil)

      (configure-fitness-function mode gym-environment-name dataset-name)
      (make-initial-population)

      (loop while *running*
            do (evolve)
            do (incf *generation*)))))

(defun inject-loaded-best-team-into-population (loaded-best-team)
  "Replace the first root team in a freshly initialized population with LOADED-BEST-TEAM."
  (unless loaded-best-team
    (error "Cannot inject best team: LOADED-BEST-TEAM is NIL."))

  ;; Ensure the loaded team is a root candidate before computing closure.
  (setf (team-type loaded-best-team) :root
        (team-references loaded-best-team) 0)

  (let* ((loaded-closure (closure loaded-best-team))
         (random-roots (root-teams)))

    (unless random-roots
      (error "Cannot inject best team: no root teams exist in the current population."))

    ;; Fresh population contains only random root teams. Drop the first one and
    ;; prepend the loaded best team's full closure.
    (setf *teams*
          (append loaded-closure
                  (rest random-roots)))

    loaded-best-team))
					     
(defun checkpoint-fitness-comparable-p
       (fitness metadata gym-environment-name)
  "Return true when saved FITNESS can be retained for this resumed search.

Known environment or fitness-episode metadata must match.  Missing provenance
is accepted for legacy non-CAGE2 checkpoints. CAGE2 requires its reproducible
seed protocol. Semantic offline checkpoints require the current protocol and
the same train/reference file fingerprint."
  (and (numberp fitness)
       (let ((saved-environment
               (getf metadata :gym-environment-name))
             (saved-episodes
               (getf metadata :online-fitness-episodes))
             (saved-protocol
               (getf metadata :fitness-evaluation-protocol))
             (saved-online-reference-episodes
               (getf metadata :online-reference-episodes))
             (saved-dataset-fingerprint
               (getf metadata :dataset-fingerprint))
              (saved-agreement-signature
                (getf metadata :action-agreement-signature))
              (saved-hamming-enabled
                (not (null (getf metadata :hamming-space-enabled))))
              (saved-hamming-fingerprint
                (getf metadata :hamming-dataset-fingerprint))
              (saved-num-observations
                (getf metadata :num-observations))
              (saved-decoy-order-mode
                (getf metadata :decoy-order-mode))
              (saved-opening-mode
                ;; Checkpoints before v11 used TPG from step 0.
                (or (getf metadata :cage2-opening-mode) :policy))
              (saved-recurrent-enabled
                ;; Checkpoints before v13 always cleared registers per bid.
                (not (null (getf metadata :recurrent-policy-enabled)))))
          (and (or (null saved-environment)
                   (equal saved-environment gym-environment-name))
               (or (null saved-num-observations)
                   (= saved-num-observations *num-observations*))
               (or (null saved-decoy-order-mode)
                   (eq saved-decoy-order-mode *decoy-order-mode*))
               (or (not (cl-gym:cage2-environment-p gym-environment-name))
                   (eq saved-opening-mode *cage2-opening-mode*))
               (eq saved-recurrent-enabled
                   (not (null *recurrent-policy-enabled*)))
               (eq saved-hamming-enabled
                   (not (null *hamming-space-enabled*)))
               (or (not *hamming-space-enabled*)
                   (equal saved-hamming-fingerprint
                          *current-hamming-dataset-fingerprint*))
               (cond
                ((eq *current-search-mode* :teacher-forcing)
                 (and (or (null saved-episodes)
                          (= saved-episodes *online-fitness-episodes*))
                      (eq saved-protocol
                          (teacher-forcing-fitness-protocol))
                      (equal saved-agreement-signature
                             (action-agreement-signature))))
                ((cl-gym:cage2-environment-p gym-environment-name)
                 (and (eq saved-protocol
                          +cage2-online-fitness-protocol+)
                      (= (or saved-online-reference-episodes 0)
                         +cage2-online-reference-episodes+)
                      (equal saved-agreement-signature
                             (action-agreement-signature))))
                (*offline-reference-dataset*
                 (and (eq saved-protocol
                          +semantic-offline-fitness-protocol+)
                      (equal saved-dataset-fingerprint
                             *current-dataset-fingerprint*)
                      (equal saved-agreement-signature
                             (action-agreement-signature))))
                (t
                 t))))))

(defun fitness-values-equivalent-p (left right)
  "Return true when two replayed fitness values agree to floating-point noise."
  (and (numberp left)
       (numberp right)
       (<= (abs (- (coerce left 'double-float)
                   (coerce right 'double-float)))
           1.0d-9)))

(defun initialize-best-from-current-population
       (loaded-best-team &optional saved-best-fitness)
  "Evaluate the warm-start population and initialize historical-best state.

Generation scores use a new shared training batch. Historical-best comparisons
use the active fixed CAGE2 seed bank or held-out semantic dataset, so a resumed
checkpoint remains replayable while training continues on changing batches."
  (let* ((scores (evaluate))
         (best-entry (and scores
                          (first (sort (copy-list scores) #'> :key #'cdr))))
         (loaded-entry (assoc loaded-best-team scores :test #'eq)))
    (unless best-entry
      (error "Warm-start evaluation failed: no valid teams after evaluation."))

    (unless loaded-entry
      (error "Warm-start evaluation did not include the loaded best team."))

    (let* ((generation-best-team (car best-entry))
           (generation-best-fitness (cdr best-entry))
           (loaded-current-fitness (cdr loaded-entry))
           (loaded-reference-fitness nil)
           (loaded-reference-detail nil)
           (generation-reference-fitness nil)
           (generation-reference-detail nil))
      (multiple-value-setq
          (loaded-reference-fitness loaded-reference-detail)
        (current-reference-evaluation
         loaded-best-team
         loaded-current-fitness))
      (if (eq generation-best-team loaded-best-team)
          (setf generation-reference-fitness loaded-reference-fitness
                generation-reference-detail loaded-reference-detail)
          (multiple-value-setq
              (generation-reference-fitness generation-reference-detail)
            (current-reference-evaluation
             generation-best-team
             generation-best-fitness)))
      (when (and (numberp saved-best-fitness)
                 (not (fitness-values-equivalent-p
                       saved-best-fitness
                       loaded-reference-fitness)))
        (error
         "Warm-start checkpoint reference fitness did not replay: saved=~A current=~A. Refusing to hide a policy/evaluation mismatch."
         saved-best-fitness
         loaded-reference-fitness))

      (let* ((loaded-baseline
               (or saved-best-fitness loaded-reference-fitness))
             (generation-won-p
               (if (and (eq *current-search-mode* :online)
                        (cl-gym:cage2-environment-p
                         *current-gym-environment-name*))
                   (online-reference-promotion-p
                    generation-reference-detail
                    loaded-reference-detail)
                   (> generation-reference-fitness loaded-baseline)))
             (chosen-team
               (if generation-won-p
                   generation-best-team
                   loaded-best-team))
             (chosen-fitness
               (if generation-won-p
                   generation-reference-fitness
                   loaded-baseline)))
        (setf *best-team*
                (deep-copy-team-via-serialization chosen-team)
              *best-fitness* chosen-fitness
              *online-best-reference-scores*
                (copy-list
                 (if generation-won-p
                     generation-reference-detail
                     loaded-reference-detail)))

        (emit-message
         (format nil
                 "Warm-start reference comparison: retained=~A saved=~A loaded-reference=~A generation-training=~A generation-reference=~A"
                 (if generation-won-p :generation-best :loaded-best)
                 saved-best-fitness
                 loaded-reference-fitness
                 generation-best-fitness
                 generation-reference-fitness))

        ;; Rewrite legacy/old-protocol checkpoints immediately with the current
        ;; replayable reference score, or save a better generation candidate.
        (when *checkpoint-directory*
          (save-best-team))))

    scores))

(defun run-search-from-best-team
       (mode gym-environment-name dataset-name seed best-team-path)
  "Warm-start search from a saved best team.

This does not restore the old population. Each island creates a fresh random
population, loads its own saved best team, replaces the first root team with it,
evaluates the resulting population once, initializes *BEST-TEAM*, then continues
normal evolution."
  (let* ((seed (seed-or-random-seed seed))
         (captured-state (sb-ext:seed-random-state seed)))
    (setf *random-state* captured-state
          *current-search-mode* mode
          *current-gym-environment-name* gym-environment-name
          *current-search-seed* seed
          *current-dataset-name* (and (eq mode :offline) dataset-name)
          *mixed-training-lineage* nil
          *online-best-reference-scores* nil
          *search-start-time* (get-universal-time))

    (catch 'search-stop-requested
      ;; Fresh island-local state.
      (setf *teams* nil)
      (setf *generation* 1)
      (reset-online-candidate-evaluation-state)
      (setf *best-team* nil)
      (setf *best-fitness* nil)

      ;; Configure the action contract before creating random learners.
      (configure-fitness-function mode gym-environment-name dataset-name)

      ;; Build fresh random population for this island.
      (make-initial-population)

      ;; Load and inject this island's best team.  Versioned checkpoints retain
      ;; their historical score when the environment and episode count match.
      (multiple-value-bind
            (loaded-best-team saved-best-fitness checkpoint-metadata)
          (load-best-team best-team-path)
        (ensure-team-observation-compatible
         loaded-best-team *num-observations*)
        (inject-loaded-best-team-into-population loaded-best-team)
        (emit-policy-limit-warning loaded-best-team)

        (setf *mixed-training-lineage*
              (and (eq mode :online)
                   (or (getf checkpoint-metadata
                             :mixed-training-lineage)
                       (getf checkpoint-metadata :dataset-name)
                       (member
                        (getf checkpoint-metadata
                              :fitness-evaluation-protocol)
                        (list +teacher-forcing-teacher-protocol+
                              +teacher-forcing-dagger-protocol+)
                        :test #'eq))))

        (let ((comparable-fitness
                (and (checkpoint-fitness-comparable-p
                      saved-best-fitness
                      checkpoint-metadata
                      gym-environment-name)
                     saved-best-fitness)))
          (when (and saved-best-fitness (null comparable-fitness))
            (emit-message
             (format nil
                     "Warm-start: saved fitness ~A is not comparable with env=~A episodes=~A; re-baselining."
                     saved-best-fitness
                     gym-environment-name
                     *online-fitness-episodes*)))

          ;; Evaluate all roots once and initialize the historical-best floor.
          (initialize-best-from-current-population
           loaded-best-team
           comparable-fitness)))

      ;; Continue normal BES/TPG evolution.
      (loop while *running*
            do (evolve)
            do (incf *generation*)))))


(defun validate-best-team-online (best-team-path gym-environment-name)
  "Load BEST-TEAM-PATH and validate it in GYM-ENVIRONMENT-NAME."
  (let* ((cage2-p (cl-gym:cage2-environment-p gym-environment-name))
         (*random-state*
           (if cage2-p
               (sb-ext:seed-random-state +cage2-evaluation-seed+)
               *random-state*)))
    (let* ((team (load-best-team best-team-path))
           (score (cl-gym:cl-gym-validate-team
                   team
                   gym-environment-name
                   (random 9999999))))
      (emit-message
       (format nil
               "Validation finished. Env=~A BestTeam=~A Score=~A"
               gym-environment-name
               best-team-path
               score))
      score)))
