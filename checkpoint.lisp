(in-package :cl-tpg)

(defvar *loaded-best-team* nil
  "Most recently loaded best team.")

(defvar *loaded-best-fitness* nil
  "Historical fitness stored with the most recently loaded best team.")

(defvar *loaded-checkpoint-metadata* nil
  "Metadata plist from the most recently loaded versioned checkpoint.")

(defconstant +best-team-checkpoint-version+ 31
  "Checkpoint version recording population-diversity pulse provenance.")

(defun checkpoint-path (directory filename)
  "Return pathname for FILENAME under DIRECTORY."
  (merge-pathnames filename
                   (uiop:ensure-directory-pathname directory)))

(defun checkpoint-agent-type ()
  "Infer a short agent type from the active environment or dataset."
  (let* ((source
           (if *current-dataset-name*
               *current-dataset-name*
               *current-gym-environment-name*))
         (name (string-downcase (princ-to-string (or source "agent")))))
    (cond
      ((or (search "b_line" name)
           (search "b-line" name)
           (search "bline" name))
       "bline")
      ((search "meander" name)
       "meander")
      (t
       "agent"))))

(defun checkpoint-training-mode ()
  "Return the active search mode as a filename component."
  (cond
    ((and (eq *current-search-mode* :online) *mixed-training-lineage*)
     "mix")
    ((eq *current-search-mode* :teacher-forcing)
     (if (eq *teacher-forcing-rollout-mode* :dagger)
         "teacher-forcing-dagger"
         "teacher-forcing"))
    ((eq *current-search-mode* :official-online)
     "official-online-specialist")
    ((eq *current-search-mode* :official-guided)
     (cond
       (*grouped-selection-enabled*
        "official-guided-grouped-lexicase")
       (*semantic-locality-control-enabled*
        "official-guided-locality-control")
       (t "official-guided-dagger")))
    (*current-dataset-name* "offline")
    ((and *current-gym-environment-name*
          (not (eq *current-gym-environment-name* :none)))
     "online")
    (t "unknown")))

(defun best-team-checkpoint-filename ()
  "Return the existing stable best-team filename for active configurations."
  (format nil
          "~A-~D-~D-~A-operators-~A~A~A-order-~A-~A-~A-opening-~A-hamming-~A-memory-~A.lisp"
          (checkpoint-agent-type)
          *num-observations*
          *num-actions*
          (checkpoint-training-mode)
          (string-downcase (symbol-name *instruction-set-profile*))
          (if (eq *read-only-register-profile* :disabled)
              ""
              (format nil "-ror-~A"
                      (string-downcase
                       (symbol-name *read-only-register-profile*))))
          (if (and (eq *instruction-mutation-mode* :legacy)
                   (not *effective-aware-mutation-enabled*))
              ""
              (format nil "-mutation-~A-effective-~A-compression-off"
                      (string-downcase
                       (symbol-name *instruction-mutation-mode*))
                      (if *effective-aware-mutation-enabled* "on" "off")))
          (string-downcase (symbol-name *decoy-order-mode*))
          (if (eq *current-search-mode* :official-online)
              "controller"
              "teacher")
          (string-downcase
           (symbol-name
            (if (eq *current-search-mode* :official-online)
                *cage2-controller-decoy-order-profile*
                *teacher-backend*)))
          (string-downcase (symbol-name *cage2-opening-mode*))
          (if *hamming-space-enabled* "on" "off")
          (if *recurrent-policy-enabled* "recurrent" "stateless")))

(defun best-team-checkpoint-path (&optional (directory *checkpoint-directory*))
  "Return the default best-team checkpoint file path."
  (checkpoint-path directory (best-team-checkpoint-filename)))

(defun make-best-team-checkpoint-data
       (team fitness &key generation gym-environment-name
                          online-fitness-episodes search-seed
                           fitness-evaluation-protocol dataset-name
                           dataset-fingerprint action-agreement-signature
                           online-reference-episodes mixed-training-lineage
                           hamming-space-enabled hamming-dataset-fingerprint
                           num-observations decoy-order-mode cage2-opening-mode
                           recurrent-policy-enabled teacher-backend
                           (instruction-set-profile
                             *instruction-set-profile*)
                           (read-only-register-profile
                             *read-only-register-profile*)
                           (instruction-mutation-mode
                             *instruction-mutation-mode*)
                           (effective-aware-mutation-enabled
                             *effective-aware-mutation-enabled*)
                           (terminal-action-format *terminal-action-format*))
  "Serialize TEAM and its historical-fitness context into a checkpoint envelope."
  (unless (valid-instruction-set-profile-p instruction-set-profile)
    (error "Cannot checkpoint unsupported instruction-set profile: ~S."
           instruction-set-profile))
  (unless (valid-read-only-register-profile-p read-only-register-profile)
    (error "Cannot checkpoint unsupported read-only-register profile: ~S."
           read-only-register-profile))
  (unless (valid-instruction-mutation-mode-p instruction-mutation-mode)
    (error "Cannot checkpoint unsupported instruction mutation mode: ~S."
           instruction-mutation-mode))
  `(:checkpoint-version ,+best-team-checkpoint-version+
    :fitness ,fitness
    :generation ,generation
    :gym-environment-name ,gym-environment-name
    :online-fitness-episodes ,online-fitness-episodes
    :search-seed ,search-seed
    :fitness-evaluation-protocol ,fitness-evaluation-protocol
    :dataset-name ,dataset-name
    :dataset-fingerprint ,dataset-fingerprint
    :action-agreement-signature ,action-agreement-signature
    :search-mechanism-profile ,+live-search-profile+
    :cage2-controller-protocol ,+cage2-controller-protocol+
    :cage2-controller-decoy-order-profile
      ,*cage2-controller-decoy-order-profile*
    :online-reference-episodes ,online-reference-episodes
    :mixed-training-lineage ,mixed-training-lineage
    :num-observations ,num-observations
    :instruction-set-profile ,instruction-set-profile
    :read-only-register-profile ,read-only-register-profile
    :read-only-register-values
      ,(and (not (eq read-only-register-profile :disabled))
            (coerce (active-read-only-register-values
                     read-only-register-profile)
                    'list))
    :instruction-mutation-mode ,instruction-mutation-mode
    :effective-aware-mutation-enabled
      ,(not (null effective-aware-mutation-enabled))
    :terminal-action-format ,terminal-action-format
    :decoy-order-mode ,decoy-order-mode
    :cage2-opening-mode ,cage2-opening-mode
    :recurrent-policy-enabled ,recurrent-policy-enabled
    :teacher-backend ,teacher-backend
    :official-guided-seed-streams
      ,(and (official-guided-mode-p)
            (copy-tree *official-guided-seed-streams*))
    :official-guided-incumbent-version
      ,(and (official-guided-mode-p)
            *official-guided-incumbent-version*)
    :official-guided-best-evaluation
      ,(and (official-guided-mode-p)
            (copy-tree *official-guided-best-evaluation*))
    :active-specialist-state
      ,(and (eq *current-search-mode* :official-online)
            (active-specialist-state-copy))
    :grouped-selection-state
      ,(and *grouped-selection-enabled*
            (fboundp 'grouped-selection-state-copy)
            (grouped-selection-state-copy))
    :behavioral-locality-state
      ,(and *behavioral-locality-enabled*
            (fboundp 'behavioral-locality-state-copy)
            (behavioral-locality-state-copy))
    :teacher-dagger-behavior-state
      ,(and (eq *current-search-mode* :official-guided)
            (fboundp 'teacher-dagger-behavior-state-copy)
            (teacher-dagger-behavior-state-copy))
    :hamming-space-enabled ,hamming-space-enabled
    :hamming-dataset-fingerprint ,hamming-dataset-fingerprint
    :team ,(serialize-team team (make-hash-table :test #'equal))))

(defun versioned-best-team-checkpoint-p (data)
  "Return true when DATA is a versioned best-team checkpoint envelope."
  (and (listp data)
       (integerp (getf data :checkpoint-version))
       (getf data :team)))

(defun write-best-team-checkpoint
       (team fitness path &key generation gym-environment-name
                               online-fitness-episodes search-seed
                                fitness-evaluation-protocol dataset-name
                                dataset-fingerprint action-agreement-signature
                                online-reference-episodes mixed-training-lineage
                                hamming-space-enabled hamming-dataset-fingerprint
                                num-observations decoy-order-mode
                                cage2-opening-mode
                                recurrent-policy-enabled teacher-backend
                                (instruction-set-profile
                                  *instruction-set-profile*)
                                (read-only-register-profile
                                  *read-only-register-profile*)
                                (instruction-mutation-mode
                                  *instruction-mutation-mode*)
                                (effective-aware-mutation-enabled
                                  *effective-aware-mutation-enabled*)
                                (terminal-action-format
                                  *terminal-action-format*))
  "Write TEAM, FITNESS, and provenance metadata to PATH."
  (ensure-directories-exist path)

  (with-open-file (out path
                       :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (with-standard-io-syntax
      (let ((*print-circle* t)
            (*print-readably* t)
            (*print-pretty* nil))
        (write
         (make-best-team-checkpoint-data
           team
           fitness
           :generation generation
           :gym-environment-name gym-environment-name
           :online-fitness-episodes online-fitness-episodes
           :search-seed search-seed
           :fitness-evaluation-protocol fitness-evaluation-protocol
           :dataset-name dataset-name
           :dataset-fingerprint dataset-fingerprint
           :action-agreement-signature action-agreement-signature
           :online-reference-episodes online-reference-episodes
           :mixed-training-lineage mixed-training-lineage
           :num-observations num-observations
           :instruction-set-profile instruction-set-profile
           :read-only-register-profile read-only-register-profile
           :instruction-mutation-mode instruction-mutation-mode
           :effective-aware-mutation-enabled
             effective-aware-mutation-enabled
           :terminal-action-format terminal-action-format
           :decoy-order-mode decoy-order-mode
           :cage2-opening-mode cage2-opening-mode
           :recurrent-policy-enabled recurrent-policy-enabled
           :teacher-backend teacher-backend
           :hamming-space-enabled hamming-space-enabled
           :hamming-dataset-fingerprint hamming-dataset-fingerprint)
         :stream out))))

  path)

(defun save-best-team (&optional (path (best-team-checkpoint-path)))
  "Save the frozen *BEST-TEAM* and its historical fitness to PATH."
  (unless *best-team*
    (error "Cannot save best team: *BEST-TEAM* is NIL."))

  (write-best-team-checkpoint
   *best-team*
   *best-fitness*
   path
   :generation *generation*
   :gym-environment-name *current-gym-environment-name*
   :online-fitness-episodes *online-fitness-episodes*
   :search-seed *current-search-seed*
   :dataset-name *current-dataset-name*
    :dataset-fingerprint *current-dataset-fingerprint*
    :online-reference-episodes
      (and (member *current-search-mode* '(:online :official-guided :official-online)
                   :test #'eq)
           +cage2-online-reference-episodes+)
    :mixed-training-lineage *mixed-training-lineage*
    :num-observations *num-observations*
    :instruction-set-profile *instruction-set-profile*
    :read-only-register-profile *read-only-register-profile*
    :instruction-mutation-mode *instruction-mutation-mode*
    :effective-aware-mutation-enabled *effective-aware-mutation-enabled*
    :terminal-action-format *terminal-action-format*
    :decoy-order-mode *decoy-order-mode*
    :cage2-opening-mode *cage2-opening-mode*
    :recurrent-policy-enabled *recurrent-policy-enabled*
    :teacher-backend *teacher-backend*
    :hamming-space-enabled *hamming-space-enabled*
    :hamming-dataset-fingerprint *current-hamming-dataset-fingerprint*
   :action-agreement-signature
     (and *factored-actions-enabled* (action-agreement-signature))
   :fitness-evaluation-protocol
   (cond
     ((eq *current-search-mode* :teacher-forcing)
      (teacher-forcing-fitness-protocol))
     ((official-guided-mode-p)
      (current-official-racing-protocol))
     ((cl-gym:cage2-environment-p *current-gym-environment-name*)
      +cage2-online-fitness-protocol+)
     (*offline-reference-dataset*
      (semantic-offline-fitness-protocol))
     (t nil)))

  (emit-message
   (format nil
           "Best team saved immediately: ~A"
           (namestring path)))

  path)

(defun load-best-team (path)
  "Load a best team from PATH.

Versioned checkpoints return TEAM, FITNESS, and METADATA as three values.
Legacy files containing only serialized team data remain fully supported and
return NIL for FITNESS and METADATA."
  (let* ((data
           (with-open-file (in path :direction :input)
             (with-standard-io-syntax
               (read in))))
         (versioned-p (versioned-best-team-checkpoint-p data))
         (team-data (if versioned-p (getf data :team) data))
         (fitness (and versioned-p (getf data :fitness)))
         (metadata
           (and versioned-p
                (loop for (key value) on data by #'cddr
                      unless (eq key :team)
                        append (list key value))))
         (team
           (deserialize-team
            team-data
            (make-hash-table :test #'equal))))
    (setf *loaded-best-team* team
          *loaded-best-fitness* fitness
          *loaded-checkpoint-metadata* metadata)
    (values team fitness metadata)))

(defun checkpoint-execution-profile (metadata &optional (context "Checkpoint"))
  "Return validated terminal, instruction, and ROR profiles from METADATA.

Legacy checkpoints use the historical defaults.  The ROR bank is checked as
part of the profile because programs containing ROR sources must never be
evaluated under a missing or different constant bank."
  (let* ((terminal-format
           (or (getf metadata :terminal-action-format) :factored))
         (instruction-profile
           (or (getf metadata :instruction-set-profile) :full))
         (ror-profile
           (or (getf metadata :read-only-register-profile) :disabled))
         (saved-ror-values
           (getf metadata :read-only-register-values)))
    (unless (valid-terminal-action-format-p terminal-format)
      (error "~A has unsupported terminal action format: ~S."
             context terminal-format))
    (unless (valid-instruction-set-profile-p instruction-profile)
      (error "~A has unsupported instruction-set profile: ~S."
             context instruction-profile))
    (unless (valid-read-only-register-profile-p ror-profile)
      (error "~A has unsupported read-only-register profile: ~S."
             context ror-profile))
    (when (and saved-ror-values
               (not (equal saved-ror-values
                           (coerce
                            (active-read-only-register-values ror-profile)
                            'list))))
      (error "~A ROR bank does not match profile ~S: ~S."
             context ror-profile saved-ror-values))
    (values terminal-format instruction-profile ror-profile)))

(defun checkpoint-execution-profile-list
       (metadata &optional (context "Checkpoint"))
  "Return CHECKPOINT-EXECUTION-PROFILE as a comparable three-item list."
  (multiple-value-list (checkpoint-execution-profile metadata context)))

(defun ensure-compatible-checkpoint-execution-profile
       (expected metadata context)
  "Require METADATA to use the three-item execution profile EXPECTED."
  (let ((actual (checkpoint-execution-profile-list metadata context)))
    (unless (equal expected actual)
      (error "~A execution profile ~S differs from candidate profile ~S."
             context actual expected))
    actual))

(defun report-checkpoint-controller-protocol (metadata context)
  "Report how checkpoint Controller provenance relates to the active protocol."
  (let ((saved-protocol (getf metadata :cage2-controller-protocol))
        (saved-profile
          (getf metadata :cage2-controller-decoy-order-profile)))
    (cond
      ((null saved-protocol)
       (emit-message
        (format nil
                "~A: checkpoint predates Controller provenance; evaluating under active protocol=~A profile=~A. Historical scores are not assumed comparable."
                context
                +cage2-controller-protocol+
                *cage2-controller-decoy-order-profile*)))
      ((not (eq saved-protocol +cage2-controller-protocol+))
       (emit-message
        (format nil
                "~A: checkpoint Controller protocol changed from ~A/~A to ~A/~A. Historical scores are not comparable until re-evaluated."
                context
                saved-protocol saved-profile
                +cage2-controller-protocol+
                *cage2-controller-decoy-order-profile*)))
      (t
       (emit-message
        (format nil
                "~A: checkpoint Controller protocol=~A profile=~A."
                context saved-protocol saved-profile))))))

(defun upgrade-best-team-checkpoint
       (path fitness &key output-path generation gym-environment-name
                          online-fitness-episodes search-seed
                           fitness-evaluation-protocol dataset-name
                           dataset-fingerprint action-agreement-signature
                           online-reference-episodes mixed-training-lineage
                           hamming-space-enabled hamming-dataset-fingerprint
                           num-observations decoy-order-mode
                           cage2-opening-mode
                           recurrent-policy-enabled teacher-backend
                           instruction-set-profile
                           read-only-register-profile
                           terminal-action-format)
  "Add fitness metadata to a legacy best-team checkpoint.

OUTPUT-PATH defaults to PATH.  Supplying a different path is recommended when
preserving the original legacy file."
  (unless (numberp fitness)
    (error "Checkpoint fitness must be numeric, got ~S." fitness))
  (let ((team (load-best-team path))
        (destination (or output-path path)))
    (write-best-team-checkpoint
     team
     fitness
     destination
     :generation generation
     :gym-environment-name gym-environment-name
     :online-fitness-episodes online-fitness-episodes
     :search-seed search-seed
     :fitness-evaluation-protocol fitness-evaluation-protocol
     :dataset-name dataset-name
     :dataset-fingerprint dataset-fingerprint
     :action-agreement-signature action-agreement-signature
     :online-reference-episodes online-reference-episodes
     :mixed-training-lineage mixed-training-lineage
     :num-observations num-observations
     :instruction-set-profile
       (or instruction-set-profile *instruction-set-profile*)
     :read-only-register-profile
       (or read-only-register-profile *read-only-register-profile*)
     :terminal-action-format
       (or terminal-action-format *terminal-action-format*)
     :decoy-order-mode decoy-order-mode
     :cage2-opening-mode cage2-opening-mode
     :hamming-space-enabled hamming-space-enabled
     :recurrent-policy-enabled recurrent-policy-enabled
     :teacher-backend teacher-backend
     :hamming-dataset-fingerprint hamming-dataset-fingerprint)
    (emit-message
     (format nil
             "Best-team checkpoint metadata written: ~A fitness=~A"
             (namestring (pathname destination))
             fitness))
    destination))

(defun clear-loaded-best-team ()
  "Clear the loaded best team."
  (setf *loaded-best-team* nil
        *loaded-best-fitness* nil
        *loaded-checkpoint-metadata* nil))

(defun deep-copy-team-via-serialization (team)
  "Create a fully independent copy of TEAM using the existing
TPG serialization/deserialization mechanism.

Unlike CLONE-TEAM, this copies the complete referenced team graph
instead of sharing internal referenced teams."
  (let ((serialized
          (serialize-team
           team
           (make-hash-table :test #'equal))))
    (deserialize-team
     serialized
     (make-hash-table :test #'equal))))
