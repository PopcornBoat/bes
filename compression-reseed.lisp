(in-package :cl-tpg)

(defun reset-compression-reseed-state ()
  "Reset run-local compression bookkeeping without touching any policy graph."
  (setf *compression-reseed-last-event-generation* nil
        *compression-reseed-last-improvement-generation* 1
        *compression-reseed-last-incumbent-version*
          *official-guided-incumbent-version*
        *compression-reseed-event-count* 0
        *compression-reseed-last-record* nil))

(defun compression-reseed-state-copy ()
  "Return serialization-safe compression provenance for checkpoint metadata."
  (list :protocol +compression-reseed-protocol+
        :enabled (not (null *compression-reseed-enabled*))
        :force-next-event (not (null *compression-reseed-force-next-event*))
        :event-count *compression-reseed-event-count*
        :last-event-generation *compression-reseed-last-event-generation*
        :last-improvement-generation
          *compression-reseed-last-improvement-generation*
        :last-incumbent-version *compression-reseed-last-incumbent-version*
        :last-record (copy-tree *compression-reseed-last-record*)))

(defun compression-reseed-active-p ()
  "Return true only for the guarded stateless Semantic-36 treatment."
  (and *compression-reseed-enabled*
       (official-guided-mode-p)
       (eq *instruction-mutation-mode* :field-local)
       *effective-aware-mutation-enabled*
       (not *recurrent-policy-enabled*)
       (member *terminal-action-format*
               '(:target-response-36 :flat-36) :test #'eq)
       *best-team*))

(defun prune-program-to-effective-code
       (program &key (output-registers (list +bid-register+)))
  "Destructively retain only PROGRAM instructions in the backward slice.

The caller must enforce stateless execution. The returned plist records the
size change; instruction objects are copied so no removed vector storage or
checkpoint graph is shared with the compact program."
  (let* ((analysis
           (analyze-program-effective-code
            program :output-registers output-registers))
         (instructions (program-instructions program))
         (indices (getf analysis :effective-indices))
         (before (length instructions))
         (retained
           (mapcar (lambda (index)
                     (copy-instruction (aref instructions index)))
                   indices)))
    (setf (program-instructions program)
          (make-array (length retained)
                      :fill-pointer t
                      :adjustable t
                      :initial-contents retained))
    (list :before before
          :after (length retained)
          :removed (- before (length retained)))))

(defun prune-team-to-effective-code
       (root-team &key (output-registers (list +bid-register+)))
  "Prune every learner program in ROOT-TEAM's closure and return totals."
  (when *recurrent-policy-enabled*
    (error "R0-only intron elimination is unsafe for recurrent policies."))
  (let ((programs 0)
        (before 0)
        (after 0))
    (dolist (graph-team (closure root-team))
      (dolist (learner (team-learners graph-team))
        (let ((record
                (prune-program-to-effective-code
                 (learner-program learner)
                 :output-registers output-registers)))
          (incf programs)
          (incf before (getf record :before))
          (incf after (getf record :after)))))
    (list :programs programs
          :before before
          :after after
          :removed (- before after))))

(defun compression-ranking-signature (team probes)
  "Return exact ranked semantic outputs for TEAM on PROBES."
  (mapcar
   (lambda (probe)
     (behavioral-ranking-pairs team (getf probe :observation)))
   probes))

(defun compression-behavior-equivalent-p (original compressed probes)
  "Require exact Top-k semantic-ranking identity on the versioned archive."
  (and probes
       (equal (compression-ranking-signature original probes)
              (compression-ranking-signature compressed probes))))

(defun install-independent-team-closure (root-team)
  "Register ROOT-TEAM and its independent internal closure in *TEAMS*."
  (setf (team-type root-team) :root
        (team-references root-team) 0)
  (dolist (graph-team (closure root-team))
    (pushnew graph-team *teams* :test #'eq))
  root-team)

(defun compression-track-incumbent-change ()
  "Track official incumbent changes without changing promotion code."
  (unless (= *compression-reseed-last-incumbent-version*
             *official-guided-incumbent-version*)
    (setf *compression-reseed-last-incumbent-version*
            *official-guided-incumbent-version*
          *compression-reseed-last-improvement-generation* *generation*)
    t))

(defun compression-reseed-cheap-eligible-p ()
  "Apply generation, plateau, cooldown, and archive gates before graph analysis."
  (and (compression-reseed-active-p)
       *behavioral-probe-archive*
       (or *compression-reseed-force-next-event*
           (let* ((last-event *compression-reseed-last-event-generation*)
                  (anchor (or last-event 0))
                  (event-age (- *generation* anchor)))
             (and
              (>= *generation* *compression-reseed-min-generation*)
              (plusp event-age)
              (zerop (mod event-age
                          *compression-reseed-check-interval*))
              (>= (- *generation*
                     *compression-reseed-last-improvement-generation*)
                  *compression-reseed-plateau-generations*)
              (or (null last-event)
                  (>= event-age
                      *compression-reseed-cooldown-generations*)))))))

(defun compression-reseed-injection-size ()
  "Return the bounded number of roots this event may add."
  (let* ((desired
           (max 1
                (floor (* *population-size*
                          *compression-reseed-population-fraction*))))
         (available (max 0 (- *population-size* (length (root-teams))))))
    (min desired available)))

(defun maybe-install-compression-reseed-parent ()
  "Possibly install a compact incumbent clone and return it plus variant count.

This function never mutates *BEST-TEAM*. It deep-copies the complete graph,
prunes the copy, requires exact archive behavior, and inserts only the compact
copy. The caller creates the requested variants through the ordinary mutation
and locality-control path."
  (compression-track-incumbent-change)
  (unless (compression-reseed-cheap-eligible-p)
    (return-from maybe-install-compression-reseed-parent (values nil 0)))
  ;; A manual request bypasses only the scheduling gates and is consumed once.
  ;; All graph-safety and behavior-equivalence checks below remain mandatory.
  (let ((forced-p *compression-reseed-force-next-event*))
    (setf *compression-reseed-force-next-event* nil)
    (when forced-p
      (emit-message
       (format nil
               "Generation ~D forced compression attempt started; safety gates remain enabled."
               *generation*))))
  (let* ((analysis (analyze-team-effective-code *best-team*))
         (instructions (getf analysis :instruction-count))
         (introns (getf analysis :intron-count))
         (intron-ratio
           (if (plusp instructions)
               (/ introns (coerce instructions 'double-float))
               0.0d0)))
    (when (< intron-ratio *compression-reseed-min-intron-ratio*)
      (emit-message
       (format nil
               "Generation ~D compression skipped: intron-ratio=~,4F threshold=~,4F."
               *generation* intron-ratio
               *compression-reseed-min-intron-ratio*))
      (return-from maybe-install-compression-reseed-parent (values nil 0)))
    (let* ((compressed (deep-copy-team-via-serialization *best-team*))
           (prune-record (prune-team-to-effective-code compressed))
           (equivalent-p
             (compression-behavior-equivalent-p
              *best-team* compressed *behavioral-probe-archive*))
           (injection-size (compression-reseed-injection-size)))
      (unless equivalent-p
        (emit-error
         (format nil
                 "Generation ~D compression rejected: probe rankings changed; protected incumbent is untouched."
                 *generation*))
        (return-from maybe-install-compression-reseed-parent (values nil 0)))
      (when (zerop injection-size)
        (return-from maybe-install-compression-reseed-parent (values nil 0)))
      (install-independent-team-closure compressed)
      (incf *compression-reseed-event-count*)
      (setf *compression-reseed-last-event-generation* *generation*
            *compression-reseed-last-record*
              (list :protocol +compression-reseed-protocol+
                    :generation *generation*
                    :incumbent-version *official-guided-incumbent-version*
                    :intron-ratio intron-ratio
                    :programs (getf prune-record :programs)
                    :instructions-before (getf prune-record :before)
                    :instructions-after (getf prune-record :after)
                    :instructions-removed (getf prune-record :removed)
                    :injection-size injection-size
                    :variant-count (1- injection-size)
                    :probe-count (length *behavioral-probe-archive*)
                    :behavior-equivalent t))
      (emit-message
       (format nil
               "Generation ~D compression-and-reseed: incumbent-version=~D intron-ratio=~,4F instructions=~D->~D removed=~D probes=~D compact-root=1 variants=~D. Protected incumbent unchanged."
               *generation*
               *official-guided-incumbent-version*
               intron-ratio
               (getf prune-record :before)
               (getf prune-record :after)
               (getf prune-record :removed)
               (length *behavioral-probe-archive*)
               (1- injection-size)))
      (values compressed (1- injection-size)))))
