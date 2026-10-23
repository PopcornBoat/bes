;;; One real CAGE2 episode per side and stage, using the same policy on both
;;; sides. A tie must never promote. Load :CL-TPG before this file.
(in-package :cl-user)

(let* ((directory
         #P"/home/hardison/bes-artifacts/runtime/online-feedback-smoke/")
       (source
         "/home/hardison/bes/validated-checkpoints/meander-v8/meander-62-36-v8.lisp")
       (result (merge-pathnames "worker-result.lisp" directory))
       (request
         (list :protocol cl-tpg::+online-feedback-protocol+
               :result-path (namestring result)
               :incumbent-path source
               :incumbent-version 0
               :incumbent-fitness -23.0d0
               :candidates
                 (list (list :path source :generation 1
                             :training-fitness -23.0d0
                             :lane :generation-best))
               :racing-stages '(1)
               :racing-seeds '(910001)
               :promotion-seeds '(910002)
               :gym-environment-name "Cage2-meander-100-v0"
               :num-observations 62 :num-actions 36
               :decoy-order-mode :fixed
               :cage2-opening-mode :fixed
               :recurrent-policy-enabled nil
               :teacher-backend :heuristic
               :hamming-space-enabled nil
               :hamming-dataset-name :none)))
  (ensure-directories-exist result)
  (cl-tpg::run-online-feedback-batch request)
  (let ((response (cl-tpg::read-readable-object result)))
    (unless (and (eq (getf response :status) :complete)
                 (eq (getf response :stage) :promotion)
                 (null (getf response :accepted))
                 (= 0.0d0 (getf response :paired-delta)))
      (error "Online feedback worker smoke failed: ~S" response))
    (format t "Online feedback worker smoke passed: ~S~%" response)))
