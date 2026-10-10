;;; Focused non-simulator checks for plateau-triggered diversity pulses.
;;; Load :CL-TPG before loading this file.

(in-package :cl-user)

(defvar *population-diversity-pulse-checks* 0)

(defun check-population-diversity-pulse (condition description)
  (incf *population-diversity-pulse-checks*)
  (unless condition
    (error "Population diversity pulse check failed: ~A" description)))

(defun population-diversity-pulse-read-request ()
  (with-open-file
      (stream
        (asdf:system-relative-pathname
         "cl-tpg" "experiments/population-diversity-pulse.sexp")
        :direction :input)
    (read stream)))

(let ((request (population-diversity-pulse-read-request)))
  (check-population-diversity-pulse
   (and (eq (getf request :population-diversity-pulse-enabled) :enabled)
        (eq (getf request :coordinated-repair-bundles-enabled) :disabled)
        (eq (getf request :compression-reseed-enabled) :disabled))
   "the experiment isolates diversity pulses from other population injections")
  (check-population-diversity-pulse
   (cl-tpg::valid-search-parameters-p
    (getf request :mode) (getf request :gym-environment-name)
    (getf request :dataset-name) (getf request :num-observations)
    (getf request :num-actions) (getf request :population-size)
    (getf request :init-num-learners) (getf request :max-num-learners)
    (getf request :p-add) (getf request :p-del) (getf request :p-mut)
    (getf request :p-act) (getf request :p-swap) (getf request :gap)
    (getf request :init-program-size) (getf request :max-program-size)
    (getf request :p-add-instr) (getf request :p-del-instr)
    (getf request :p-swap-instrs) (getf request :p-mut-constant)
    (getf request :p-mut-constant-sign) (getf request :migration-interval)
    (getf request :batch-size) (getf request :seed)
    nil :none (getf request :decoy-order-mode)
    (getf request :cage2-opening-mode) nil
    (getf request :teacher-forcing-rollout-mode)
    (getf request :teacher-backend) (getf request :instruction-set-profile)
    (getf request :instruction-mutation-mode) t nil nil
    (getf request :read-only-register-profile) nil nil nil nil t)
   "the population-diversity request is server-valid"))

(let* ((cl-tpg::*population-diversity-pulse-enabled* t)
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*terminal-action-format* :target-response-36)
       (cl-tpg::*recurrent-policy-enabled* nil)
       (cl-tpg::*population-size* 4)
       (cl-tpg::*population-diversity-pulse-cohort-fraction* 1.0d0)
       (cl-tpg::*population-diversity-pulse-plateau-generations* 4)
       (cl-tpg::*population-diversity-pulse-cooldown-generations* 4)
       (cl-tpg::*current-search-seed* 153)
       (cl-tpg::*generation* 5)
       (cl-tpg::*official-guided-incumbent-version* 1)
       (cl-tpg::*num-actions* 36)
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*init-num-learners* 1)
       (cl-tpg::*init-program-size* 1)
       (cl-tpg::*max-program-size* 4)
       (cl-tpg::*instruction-set-profile* :reduced-eq)
       (cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
       (cl-tpg::*checkpoint-directory* nil)
       (cl-tpg::*teams* nil)
       (cl-tpg::*best-team* nil)
       (cl-tpg::*random-state* (sb-ext:seed-random-state 9876)))
  (cl-tpg::make-initial-population)
  (setf cl-tpg::*best-team*
        (cl-tpg::deep-copy-team-via-serialization
         (first (cl-tpg::root-teams))))
  (cl-tpg::reset-population-diversity-pulse-state)
  (let* ((roots-before (length (cl-tpg::root-teams)))
         (expected-next-random
           (let ((state (make-random-state cl-tpg::*random-state*)))
             (random 1000000 state)))
         (best-before cl-tpg::*best-team*)
         (record (cl-tpg::maybe-install-population-diversity-pulse)))
    (check-population-diversity-pulse
     (and record
          (= (getf record :cohort-size) 4)
          (= (getf record :incumbent-copies) 1)
          (= (getf record :fresh-random-roots) 3)
          (= (length (cl-tpg::root-teams)) (+ roots-before 4)))
     "a due pulse temporarily adds one complete warm-start-sized cohort")
    (check-population-diversity-pulse
     (eq best-before cl-tpg::*best-team*)
     "installing the cohort does not replace or mutate the protected incumbent")
    (check-population-diversity-pulse
     (= expected-next-random (random 1000000 cl-tpg::*random-state*))
     "event-local cohort creation does not consume ordinary evolution RNG")
    (check-population-diversity-pulse
     (null (cl-tpg::maybe-install-population-diversity-pulse))
     "the cooldown prevents an immediate second pulse"))
  (incf cl-tpg::*official-guided-incumbent-version*)
  (incf cl-tpg::*generation*)
  (check-population-diversity-pulse
   (and (cl-tpg::population-diversity-pulse-track-incumbent-change)
        (= cl-tpg::*population-diversity-pulse-last-improvement-generation*
           cl-tpg::*generation*))
   "official promotion resets the plateau clock"))

(let* ((cl-tpg::*population-diversity-pulse-enabled* t)
       (cl-tpg::*current-search-mode* :official-guided)
       (cl-tpg::*current-gym-environment-name* "Cage2-b_line-100-v0")
       (cl-tpg::*num-observations* 62)
       (cl-tpg::*num-actions* 36)
       (cl-tpg::*instruction-set-profile* :reduced-eq)
       (cl-tpg::*read-only-register-profile* :cage2-categorical-v1)
       (cl-tpg::*decoy-order-mode* :fixed)
       (cl-tpg::*teacher-backend* :heuristic)
       (cl-tpg::*cage2-opening-mode* :fixed)
       (cl-tpg::*hamming-space-enabled* nil)
       (cl-tpg::*recurrent-policy-enabled* nil)
       (team (cl-tpg::%make-team :learners nil))
       (data (cl-tpg::make-best-team-checkpoint-data team 0.0d0)))
  (check-population-diversity-pulse
   (and (getf data :population-diversity-pulse-enabled)
        (eq (getf data :population-diversity-pulse-protocol)
            cl-tpg::+population-diversity-pulse-protocol+)
        (getf data :population-diversity-pulse-state))
   "checkpoint metadata records pulse protocol and schedule provenance")
  (check-population-diversity-pulse
   (search "population-diversity-pulse"
           (cl-tpg::best-team-checkpoint-filename))
   "checkpoint filenames isolate pulse experiments"))

(format t "~D population diversity pulse checks passed.~%"
        *population-diversity-pulse-checks*)
