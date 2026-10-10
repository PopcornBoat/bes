(in-package :cl-tpg)

(defun compiled-heuristic-donor-active-p ()
  "Return true only for the maintained stateless official-guided contract."
  (and *compiled-heuristic-donor-seeding-enabled*
       (official-guided-mode-p)
       (not *recurrent-policy-enabled*)
       (eq *terminal-action-format* :target-response-36)
       (stringp *compiled-heuristic-donor-checkpoint*)))

(defun compiled-heuristic-donor-count (root-count)
  "Return the number of ROOT-COUNT slots assigned to donor descendants."
  (unless (and (realp *compiled-heuristic-donor-fraction*)
               (> *compiled-heuristic-donor-fraction* 0)
               (< *compiled-heuristic-donor-fraction* 1))
    (error "Compiled-donor fraction must be in (0,1), got ~S."
           *compiled-heuristic-donor-fraction*))
  (min (max 0 (1- root-count))
       (max 1 (round (* root-count *compiled-heuristic-donor-fraction*)))))

(defun load-compiled-heuristic-donor ()
  "Load and validate the donor without changing the active warm-start context."
  (unless (probe-file *compiled-heuristic-donor-checkpoint*)
    (error "Compiled heuristic donor checkpoint does not exist: ~A"
           *compiled-heuristic-donor-checkpoint*))
  (let ((saved-team *loaded-best-team*)
        (saved-fitness *loaded-best-fitness*)
        (saved-metadata *loaded-checkpoint-metadata*))
    (unwind-protect
         (multiple-value-bind (team fitness metadata)
             (load-best-team *compiled-heuristic-donor-checkpoint*)
           (declare (ignore fitness))
           ;; Instruction profiles constrain future instruction creation, not
           ;; execution.  The compiled checkpoint predates that metadata and
           ;; uses no ROR sources, so require only the action contract and any
           ;; actually required ROR bank to match.
           (multiple-value-bind
                 (terminal-format instruction-profile ror-profile)
               (checkpoint-execution-profile
                metadata "Compiled heuristic donor")
             (declare (ignore instruction-profile))
             (unless (eq terminal-format *terminal-action-format*)
               (error "Compiled donor action format ~S differs from active format ~S."
                      terminal-format *terminal-action-format*))
             (unless (or (eq ror-profile :disabled)
                         (eq ror-profile *read-only-register-profile*))
               (error "Compiled donor ROR profile ~S differs from active profile ~S."
                      ror-profile *read-only-register-profile*)))
           (ensure-team-observation-compatible team *num-observations*)
           team)
      (setf *loaded-best-team* saved-team
            *loaded-best-fitness* saved-fitness
            *loaded-checkpoint-metadata* saved-metadata))))

(defun compiled-donor-mutation-record (donor variant events)
  "Measure VARIANT against DONOR on the current versioned probe archive."
  (compare-behavioral-signatures
   (behavioral-policy-signature donor)
   (behavioral-policy-signature variant)
   events donor variant))

(defun discard-compiled-donor-variant (variant)
  "Remove cached data for a rejected, not-yet-installed VARIANT."
  (when *behavioral-signature-cache*
    (remhash variant *behavioral-signature-cache*))
  nil)

(defun make-compiled-heuristic-donor-variant (donor)
  "Create one mandatory, bounded, behaviorally changed DONOR descendant.

The compiled policy itself is never registered in *TEAMS*. Each attempt starts
from a fresh serialization copy and performs a real program mutation. Probe-
neutral edits are rejected, so the exact compiled policy cannot win merely by
being inserted. Ordinary reproduction may later alter learners, terminals and
graph edges after the accepted descendant joins the population."
  (loop repeat +compiled-heuristic-donor-max-attempts+
        for variant = (deep-copy-team-via-serialization donor)
        do (let ((*active-mutation-events* nil)
                 ;; The maintained live profile keeps continuous locality
                 ;; diagnostics off. Enable event capture only while building
                 ;; this one bounded donor cohort.
                 (*behavioral-locality-enabled* t))
             ;; A direct learner-program mutation avoids attaching the isolated
             ;; donor to the live TPG graph during cohort construction.
             (mutate-learner variant)
             (let* ((events (nreverse *active-mutation-events*))
                    (record
                      (compiled-donor-mutation-record donor variant events))
                    (distance (getf record :top1-hamming 0.0d0)))
               (if (and (plusp distance)
                        (<= distance
                            *compiled-heuristic-donor-max-top1-hamming*))
                   (progn
                     (setf (getf record :donor-protocol)
                             +compiled-heuristic-donor-protocol+)
                     (return (values variant record)))
                   (discard-compiled-donor-variant variant))))
        finally
           (error "Could not create a behaviorally changed compiled-donor descendant in ~D attempts."
                  +compiled-heuristic-donor-max-attempts+)))

(defun compiled-donor-replaceable-roots (protected-root)
  "Return roots eligible for replacement, excluding PROTECTED-ROOT."
  (remove protected-root (root-teams) :test #'eq))

(defun install-compiled-heuristic-donor-cohort (protected-root)
  "Replace random warm-start roots with mutated compiled-heuristic descendants.

PROTECTED-ROOT is the evolved warm-start checkpoint and is never removed. The
donor itself is never installed, evaluated, promoted, or saved. Only descendants
with nonzero bounded Top-1 probe distance enter the ordinary population."
  (unless (compiled-heuristic-donor-active-p)
    (return-from install-compiled-heuristic-donor-cohort nil))
  ;; The normal live profile intentionally disables continuous locality work.
  ;; Build one deterministic archive from the already-created DAgger/reference
  ;; datasets solely to prove that no exact oracle behavior enters the cohort.
  (unless *behavioral-probe-archive*
    (unless *teacher-training-dataset*
      (error "Compiled donor seeding requires an evaluated teacher dataset."))
    (let ((*behavioral-locality-enabled* t))
      (update-behavioral-probe-archive *teacher-training-dataset*)))
  (unless *behavioral-probe-archive*
    (error "Compiled donor seeding requires the versioned behavioral probe archive."))
  (let* ((roots-before (length (root-teams)))
         (count (compiled-heuristic-donor-count roots-before))
         (seed
           (official-guided-derived-root
            *current-search-seed* +compiled-heuristic-donor-rng-salt+))
         (random-state (sb-ext:seed-random-state seed))
         (donor (load-compiled-heuristic-donor))
         (variants nil)
         (records nil)
         (replaceable (compiled-donor-replaceable-roots protected-root)))
    (when (< (length replaceable) count)
      (error "Compiled donor requested ~D slots but only ~D roots are replaceable."
             count (length replaceable)))
    ;; Keep cohort creation reproducible without consuming ordinary mutation RNG.
    (let ((*random-state* random-state))
      (loop repeat count
            do (multiple-value-bind (variant record)
                   (make-compiled-heuristic-donor-variant donor)
                 (push variant variants)
                 (push record records))))
    (setf variants (nreverse variants)
          records (nreverse records))
    ;; Choose distinct roots with the same independent stream.
    (let ((*random-state* random-state))
      (loop repeat count
            for victim = (random-choice replaceable)
            do (setf replaceable
                     (delete victim replaceable :test #'eq :count 1))
               (delete-team victim)))
    (dolist (variant variants)
      (install-independent-team-closure variant))
    (unless (= roots-before (length (root-teams)))
      (error "Compiled donor seeding changed root count from ~D to ~D."
             roots-before (length (root-teams))))
    (setf *compiled-heuristic-donor-last-record*
          (list :protocol +compiled-heuristic-donor-protocol+
                :generation *generation*
                :seed seed
                :checkpoint *compiled-heuristic-donor-checkpoint*
                :fraction *compiled-heuristic-donor-fraction*
                :descendants count
                :donor-installed nil
                :exact-donor-descendants 0
                :probe-revision *behavioral-probe-revision*
                :probe-count (length *behavioral-probe-archive*)
                :top1-hamming
                  (mapcar (lambda (record)
                            (getf record :top1-hamming))
                          records)
                :variant-team-ids (mapcar #'team-id variants)))
    (append-behavioral-locality-form
     (append (list :record-type :compiled-heuristic-donor-cohort)
             (copy-tree *compiled-heuristic-donor-last-record*)))
    (emit-message
     (format nil
             "Compiled heuristic donor cohort installed: descendants=~D roots=~D donor-installed=NIL exact-descendants=0 probe-revision=~D top1-distance=[~,4F,~,4F] seed=~D. Protected incumbent unchanged."
             count roots-before *behavioral-probe-revision*
             (reduce #'min records
                     :key (lambda (record) (getf record :top1-hamming)))
             (reduce #'max records
                     :key (lambda (record) (getf record :top1-hamming)))
             seed))
    (copy-tree *compiled-heuristic-donor-last-record*)))
