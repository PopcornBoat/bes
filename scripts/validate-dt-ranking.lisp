;;; Compare policy ordering in official CAGE2 and the learned ensemble.
;;; CAGE2_RANKING_CHECKPOINTS is a colon-free semicolon-delimited path list.

(require :asdf)
(asdf:load-system :cl-tpg)

(in-package :cl-tpg)

(defun ranking-indices (scores)
  "Return zero-based descending ranks, assigning tied scores their mean rank."
  (let* ((result (make-array (length scores)))
         (ordered
           (stable-sort
            (loop for score in scores
                  for index from 0
                  collect (cons score index))
            #'> :key #'car)))
    (loop with rank = 0
          while ordered
          for score = (caar ordered)
          for tied = (loop while (and ordered (= (caar ordered) score))
                           collect (pop ordered))
          for mean-rank = (+ rank (/ (1- (length tied)) 2.0d0))
          do (dolist (entry tied)
               (setf (aref result (cdr entry)) mean-rank))
             (incf rank (length tied)))
    (coerce result 'list)))

(defun pearson-correlation (left right)
  "Return the Pearson correlation of equal-length numeric lists."
  (let* ((left-mean (arithmetic-mean left))
         (right-mean (arithmetic-mean right))
         (numerator
           (loop for x in left
                 for y in right
                 sum (* (- x left-mean) (- y right-mean))))
         (left-scale
           (sqrt (loop for x in left sum (expt (- x left-mean) 2))))
         (right-scale
           (sqrt (loop for y in right sum (expt (- y right-mean) 2)))))
    (if (zerop (* left-scale right-scale))
        0.0d0
        (/ numerator (* left-scale right-scale)))))

(let* ((checkpoint-text
         (or (uiop:getenv "CAGE2_RANKING_CHECKPOINTS")
             (error "CAGE2_RANKING_CHECKPOINTS is not set.")))
       (checkpoint-paths
         (uiop:split-string checkpoint-text :separator '(#\;)))
       (official-episodes
         (parse-integer (or (uiop:getenv "CAGE2_RANKING_OFFICIAL_EPISODES")
                            "100")))
       (twin-episodes
         (parse-integer (or (uiop:getenv "CAGE2_RANKING_TWIN_EPISODES")
                            "10")))
       (official-seeds
         (make-online-fitness-episode-seeds
          +cage2-evaluation-seed+ official-episodes))
       (twin-seeds
         (make-online-fitness-episode-seeds
          +cage2-evaluation-seed+ twin-episodes))
       (official-scores nil)
       (twin-scores nil))
  (unless (>= (length checkpoint-paths) 3)
    (error "Ranking gate needs at least three checkpoints."))
  (setf *num-observations* 62
        *num-actions* 11
        *decoy-order-mode* :fixed
        *cage2-opening-mode* :fixed
        *factored-actions-enabled* t
        *hamming-space-enabled* nil
        *running* t)
  (dolist (path checkpoint-paths)
    (let* ((team (load-best-team path))
           (official
             (cage2-fitness-on-seeds
              team "Cage2-b_line-100-v0" official-seeds))
           (twin
             (nth-value
              0
              (digital-twin-fitness-on-seeds
               team "Cage2Twin-b_line-100-v0" twin-seeds))))
      (push official official-scores)
      (push twin twin-scores)
      (format t "RANKING policy=~A official=~,4F twin-lcb=~,4F~%"
              path official twin)))
  (setf official-scores (nreverse official-scores)
        twin-scores (nreverse twin-scores))
  (let* ((official-ranks (ranking-indices official-scores))
         (twin-ranks (ranking-indices twin-scores))
         (spearman (pearson-correlation official-ranks twin-ranks))
         (official-best (position (reduce #'max official-scores)
                                  official-scores))
         (official-best-twin-rank (nth official-best twin-ranks))
         (passed (and (>= (+ spearman 1.0d-9) 0.6d0)
                      (<= official-best-twin-rank 1.0d0))))
    (format t
            "RANKING-GATE spearman=~,4F official-best-twin-rank=~D result=~A~%"
            spearman official-best-twin-rank (if passed "PASS" "FAIL"))
    (unless passed
      (error "Digital-twin ranking gate failed."))))
