;;; Focused checks for Phase 5C validation seed recovery.

(in-package :cl-user)

(defvar *phase5c-diagnostic-checks* 0)

(defun check-phase5c-diagnostic (condition description)
  (incf *phase5c-diagnostic-checks*)
  (unless condition
    (error "Phase 5C diagnostic check failed: ~A" description)))

#+sbcl
(let* ((root 153)
       (state (sb-ext:seed-random-state root))
       (expected (loop repeat 6 collect (random 9999999 state)))
       (results
         (list
          (list :label "b_line-30" :scores '(0.0d0 0.0d0))
          (list :label "b_line-50" :scores '(0.0d0 0.0d0))
          (list :label "b_line-100" :scores '(-10.0d0 -101.0d0))))
       (failures
         (cl-tpg::phase5c-validation-failures
          results "b_line-100" -100.0d0 root)))
  (check-phase5c-diagnostic
   (= (length failures) 1)
   "only a return below the declared threshold is selected")
  (check-phase5c-diagnostic
   (and (= (getf (first failures) :episode) 2)
        (= (getf (first failures) :seed) (sixth expected))
        (= (getf (first failures) :recorded-return) -101.0d0))
   "earlier validation blocks consume their exact seed draws"))

(check-phase5c-diagnostic
 (not (cl-tpg::phase5c-correction-p nil t nil))
 "normal replay never substitutes the teacher")
(check-phase5c-diagnostic
 (cl-tpg::phase5c-correction-p :first-disagreement t nil)
 "one-shot correction fires on the first disagreement")
(check-phase5c-diagnostic
 (not (cl-tpg::phase5c-correction-p :first-disagreement t 8))
 "one-shot correction does not fire after the first disagreement")
(check-phase5c-diagnostic
 (cl-tpg::phase5c-correction-p :all-disagreements t 8)
 "persistent correction fires on later disagreements")

(format t "~&Phase 5C diagnostic checks passed: ~D~%"
        *phase5c-diagnostic-checks*)
