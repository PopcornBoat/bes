(in-package :cl-user)

(defvar *controller-checks* 0)

(defun check-controller (condition description)
  (incf *controller-checks*)
  (unless condition
    (error "Controller check failed: ~A" description)))

;; Each Decoy host is checked in proposal order, then in its local option order.
(let ((controller (cl-tpg::make-cage2-controller :decoy-order-profile :model)))
  (setf (cl-tpg::cage2-controller-decoy-schedule controller)
        (list '(3 0) '(5 2) '(5 7)))
  (flet ((resolve (pairs)
           (cl-tpg::cage2-controller-resolve-pair-ranking controller pairs)))
    (let ((ranked '((5 3) (2 0) (3 3)))
          (mask (cl-tpg::cage2-controller-decoy-mask controller)))
      (dolist (option '(2 7))
        (let ((decision (resolve ranked)))
          (check-controller
           (and (= option (cl-tpg::cage2-controller-decision-option decision))
                (= 0 (cl-tpg::cage2-controller-decision-rank decision)))
           "ranked Decoy uses Op_Server0 first despite its later schedule entries")
          (when (= option 2)
            (check-controller (= mask (cl-tpg::cage2-controller-decoy-mask controller))
                              "proposal resolution is pure"))
          (cl-tpg::cage2-controller-commit-decision controller decision)))
      (let ((decision (resolve ranked)))
        (check-controller (= 2 (cl-tpg::cage2-controller-decision-rank decision))
                          "next ranked Decoy host precedes intervening Analyse")
        (cl-tpg::cage2-controller-commit-decision controller decision))
      (check-controller (= 1 (cl-tpg::cage2-controller-decision-rank (resolve ranked)))
                        "fully exhausted Decoys fall back to Analyse"))
    (cl-tpg::cage2-controller-reset controller)
    (check-controller (= 0 (cl-tpg::cage2-controller-decision-rank
                             (resolve '((2 0) (5 3)))))
                      "a Top-1 Analyse still wins")
    (check-controller (= 0 (cl-tpg::cage2-controller-decision-rank
                             (resolve '((2 2) (5 3)))))
                      "a Top-1 Restore still wins")
    (check-controller (= 2 (cl-tpg::cage2-controller-decision-rank
                             (resolve '((6 3) (5 2) (2 0)))))
                      "fallback Restore remains ineligible")))


(format t "Lisp Controller checks passed: ~D.~%" *controller-checks*)
