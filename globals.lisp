(in-package :cl-tpg)

(defconstant *num-threads* 20
  "The number of CPU cores available for multi-threading.")

(defconstant +num-registers+ 8
  "The number of registers that a program has access to during execution.
   This is declared as a constant for optimization speed.")

(defconstant +bid-register+ 0
  "Register used as a learner's bid during team execution.")

(defconstant +response-register+ 1
  "Register on the final terminal learner used to decode response type.")

(defconstant +decoy-option-register+ 2
  "Register on the final terminal learner used to decode a decoy option.")

(defconstant +num-semantic-targets+ 11
  "Number of targets in the hierarchical CAGE2 policy output.")

(defconstant +num-semantic-responses+ 4
  "Number of host response categories in a factored policy action.")

(defconstant +num-semantic-36-actions+ 36
  "Number of target/response categories in the versioned Semantic-36 head.")

(defparameter *terminal-action-format* :factored
  "Categorical atomic-action representation used when
*FACTORED-ACTIONS-ENABLED* is true. :FACTORED preserves the historical
11-target plus response-gene representation; :TARGET-RESPONSE-36 stores the
nine-host target and four-way response as two direct fields; :FLAT-36 is the
future comparison representation with one catalogue index.")

(defun valid-terminal-action-format-p (format)
  "Return true for a supported categorical terminal-action representation."
  (member format '(:factored :target-response-36 :flat-36) :test #'eq))

(defvar *num-actions*)

(defun cage2-semantic-action-count-p (count)
  "Return true when COUNT selects a supported CAGE2 terminal contract."
  (and (integerp count)
       (member count
               (list +num-semantic-targets+ +num-semantic-36-actions+)
               :test #'=)))

(defun configure-cage2-terminal-action-format (&optional (count *num-actions*))
  "Select the categorical terminal representation implied by COUNT.

Eleven retains checkpoint compatibility with the earlier target/response-gene
head.  Thirty-six selects the direct two-field target/response genotype."
  (setf *terminal-action-format*
        (cond
          ((= count +num-semantic-targets+) :factored)
          ((= count +num-semantic-36-actions+) :target-response-36)
          (t
           (error "Unsupported CAGE2 semantic action count: ~S." count)))))

(defconstant +cage2-controller-protocol+ :cage2-lisp-controller-v1
  "Version tag for the canonical Lisp-side CAGE2 controller semantics.")

(defparameter *cage2-controller-decoy-order-profile* :heuristic
  "Fixed, versioned Decoy order used by the Lisp controller.

This is intentionally independent of *TEACHER-BACKEND*: changing who supplies
a ranked proposal must not silently change how that proposal is executed.")

(defvar *factored-actions-enabled* nil
  "When true, newly created atomic actions contain categorical target and
response fields. Legacy numeric atomic actions remain executable so historical
checkpoints can be loaded and gradually mutated into the new representation.")

(defparameter *decoy-order-mode* :fixed
  "CAGE2 Decoy ordering mode. :FIXED always uses the teacher-derived agreement
order; :EVOLVED uses each root team's serialized, mutable option orders.")

(defparameter *cage2-opening-mode* :fixed
  "CAGE2 episode-opening mode. :FIXED executes the three main-agent probe
actions before consulting TPG; :POLICY lets TPG control the episode from step 0.")

(defparameter *teacher-forcing-rollout-mode* :dagger
  "Teacher-forcing state distribution. :TEACHER imitates only teacher-controlled
trajectories; :DAGGER also labels states visited by the current best TPG policy.")

(defparameter *teacher-backend* :model
  "Local ranked teacher used by teacher forcing and its fixed Decoy profile.
:MODEL preserves the packaged neural teacher; :HEURISTIC uses the deterministic
BlueBLineHeuristicSimple-compatible teacher.")

(defparameter *recurrent-policy-enabled* nil
  "When true, each learner keeps its own register vector for one episode.")

(defvar *policy-episode-registers* nil
  "Dynamically bound EQ hash table of learner to episode-local registers.
A fresh table is bound around every online rollout or recurrent sequence.
NIL deliberately keeps independent-row evaluation and legacy execution
stateless.")

(defconstant +cage2-raw-observation-size+ 52
  "Number of raw values produced by the official CAGE2 ChallengeWrapper.")

(defconstant +cage2-scan-state-size+ 10
  "Number of episode-local host scan-state values appended by the bridge.")

(defconstant +cage2-scan-observation-size+
  (+ +cage2-raw-observation-size+ +cage2-scan-state-size+)
  "CAGE2 observation size after bridge-side scan-state augmentation.")

(defconstant +cage2-decoy-availability-size+ 80
  "Ten selected hosts times eight binary decoy availability values.")

(defconstant +cage2-observation-size+
  (+ +cage2-scan-observation-size+ +cage2-decoy-availability-size+)
  "CAGE2 policy input size including scan and exact decoy availability state.")

(defun valid-cage2-policy-observation-size-p (size)
  "Return true when SIZE selects a supported prefix of the bridge observation."
  (and (integerp size)
       (member size
               (list +cage2-scan-observation-size+
                     +cage2-observation-size+)
               :test #'=)))

(defun valid-decoy-order-mode-p (mode)
  "Return true for a supported CAGE2 Decoy-order experiment mode."
  (member mode '(:fixed :evolved) :test #'eq))

(defun valid-cage2-opening-mode-p (mode)
  "Return true for a supported CAGE2 episode-opening mode."
  (member mode '(:fixed :policy) :test #'eq))

(defun valid-teacher-forcing-rollout-mode-p (mode)
  "Return true for a supported teacher-forcing trajectory source."
  (member mode '(:teacher :dagger) :test #'eq))

(defun valid-teacher-backend-p (backend)
  "Return true for a packaged local teacher implementation."
  (member backend '(:model :heuristic) :test #'eq))

(defconstant +global-target+ 0
  "Target value representing the global Monitor action.")

(defparameter +cage2-fixed-opening-rankings+
  #(((8 3)) ((8 3)) ((2 3)))
  "Main-agent probe sequence used before the opponent policy is observable.

Each entry is a ranked bridge action. Fixed Decoy ordering resolves the two
User2 probes to distinct concrete Decoys. TPG begins acting at step 3.")

(defconstant +cage2-evaluation-seed+ 153
  "Root seed used by reproducible CAGE2 evaluation protocols.")

(defconstant +max-team-traversal-depth+ 128
  "Defensive execution-depth ceiling for malformed or pathological TPGs.")

(defconstant +semantic-ranking-limit+ 8
  "Maximum number of unique target/response candidates sent to CAGE2.")

(defconstant +ranked-behavior-fitness-weight+ 0.8d0
  "Weight of the executable top-choice term in ranked offline fitness.")

(defconstant +ranked-order-fitness-weight+ 0.2d0
  "Weight of the teacher-order NDCG term in ranked offline fitness.")

(defconstant +cage2-online-fitness-protocol+
  :ranked-semantic-next-best-staged-robust-reference-v8
  "Version tag for staged online fitness and robust best-team promotion.")

(defconstant +cage2-online-reference-episodes+ 100
  "Fixed episode count used to protect the online historical best from noise.")

(defconstant +cage2-online-promotion-standard-errors+ 1.0d0
  "Required paired standard-error margin for online best-team promotion.")

(defconstant +official-guided-fitness-protocol+
  :official-guided-dagger-phase1-v1
  "Frozen Phase-1 protocol: ranked imitation, clean mixed DAgger, and
independent official paired challenger evaluation.")

(defconstant +official-guided-racing-episodes+ 5
  "Cheap paired official episodes used to reject a challenger before promotion.")

(defparameter +official-guided-promotion-stages+ '(12 40 100)
  "Cumulative fresh paired episode counts used by staged promotion.")

(defparameter +official-guided-reference-roots+ '(153 42 2026)
  "Fixed roots used only for monitoring, never selection or promotion.")

(defconstant +official-guided-reference-episodes-per-root+ 10
  "Monitoring episodes derived from each fixed reference root.")

(defconstant +official-guided-comparison-standard-errors+ 1.0d0
  "Standard-error boundary used by racing futility and final promotion.")

(defconstant +behavioral-locality-protocol+
  :behavioral-locality-phase2-v1
  "Version tag for observation-only Phase-2 parent/child diagnostics.")

(defconstant +behavioral-probe-section-size+ 16
  "Number of observations retained in each Phase-2 probe archive section.")

(defconstant +behavioral-probe-archive-size+
  (* 4 +behavioral-probe-section-size+)
  "Maximum observations in the versioned Phase-2 probe archive.")

(defconstant +behavioral-locality-sample-episodes+ 12
  "Paired official episodes used by one passive Phase-2 locality sample.")

(defparameter +behavioral-locality-sampling-strata+
  '(:probe-neutral :ranking-only :small-top1 :medium-top1 :large-top1)
  "Deterministic strata used to balance passive official mutation samples.")

(defconstant +semantic-locality-control-protocol+
  :semantic-locality-control-phase3-v2
  "Version tag for adaptive Phase-3 behavioral mutation control.")

(defparameter +semantic-locality-control-compatible-protocols+
  '(:semantic-locality-control-phase3-v1
    :semantic-locality-control-phase3-v2)
  "Control-state protocols that can resume under the Phase-3 v2 code.")

(defconstant +semantic-locality-control-max-attempts+ 8
  "Maximum native mutation attempts used to fill one controlled offspring slot.")

(defparameter +semantic-locality-control-stages+
  '((:name :exploration :until 250
     :local-weight 0.60d0 :bounded-weight 0.25d0 :explore-weight 0.15d0)
    (:name :transition :until 1000
     :local-weight 0.75d0 :bounded-weight 0.20d0 :explore-weight 0.05d0)
    (:name :consolidation :until nil
     :local-weight 0.85d0 :bounded-weight 0.12d0 :explore-weight 0.03d0))
  "Frozen Phase-3 schedule.

LOCAL slots seek ranking-only or at-most-five-percent Top-1 changes. BOUNDED
slots additionally accept at-most-twenty-percent Top-1 changes. EXPLORE slots
accept the first native mutation unchanged, preserving non-local escape moves.")

(defconstant +phase4-selection-protocol+
  :grouped-epsilon-lexicase-phase4a-v1
  "Version tag for the causally isolated Phase-4a survivor selection.")

(defconstant +phase4-minimum-pair-group-size+ 5
  "Minimum rows required to activate one teacher target/response case.")

(defconstant +phase4-selection-numerical-tolerance+ 1.0d-12
  "Floating comparison tolerance; this is not a statistical epsilon floor.")

(defconstant +phase4-selection-rng-salt+ 1900813
  "Independent deterministic salt for the Phase-4a selection stream.")

(defconstant +phase4b-disagreement-audit-protocol+
  :error-directed-variation-audit-v1
  "Version tag for the passive Phase-4b disagreement classification.")

(defconstant +phase4b-systematic-minimum-occurrences+ 3
  "Minimum repeated rows required for one Phase-4b systematic error issue.")

(defconstant +phase4b-systematic-minimum-episodes+ 2
  "Minimum distinct episodes required for one Phase-4b systematic error issue.")

(defconstant +official-guided-seed-payload-bits+ 28
  "Low seed bits reserved for one deterministic stream payload.")

(defconstant +official-guided-seed-payload-mask+
  (1- (ash 1 +official-guided-seed-payload-bits+))
  "Mask separating the official-guided and diagnostic seed namespaces.")

(defconstant +online-candidate-evaluation-interval+ 10
  "Generations accumulated before submitting one online generation-best
candidate to the independent reference evaluator.")

(defconstant +online-candidate-screen-episodes+ 20
  "Prefix of the fixed reference bank used for the cheap candidate screen.")

(defconstant +online-candidate-screen-standard-errors+ 1.0d0
  "Uncertainty allowance used by the first-stage futility screen.")

(defvar *online-candidate-process* nil
  "UIOP process information for the active independent candidate evaluator.")

(defvar *online-candidate-job* nil
  "Metadata for the online candidate currently owned by the evaluator.")

(defvar *online-candidate-next-submit-generation* nil
  "First generation at which the accumulated candidate may be submitted.")

(defvar *online-staged-best-team* nil
  "Frozen best training candidate accumulated since the previous submission.")

(defvar *online-staged-best-fitness* nil
  "Generation-training fitness associated with *ONLINE-STAGED-BEST-TEAM*.")

(defvar *online-staged-best-generation* nil
  "Source generation associated with *ONLINE-STAGED-BEST-TEAM*.")

(defvar *online-staged-best-lineage* nil
  "Phase-2 parent/child diagnostic associated with the staged challenger.")

(defvar *online-staged-best-parent-team* nil
  "Independent direct-parent graph associated with the staged challenger.")

(defconstant +online-fitness-stage-two-generation+ 201
  "First online generation evaluated with ten training episodes per team.")

(defconstant +online-fitness-stage-three-generation+ 501
  "First online generation evaluated with twenty training episodes per team.")

(defparameter +online-fitness-episode-schedule+
  '((1 . 5) (201 . 10) (501 . 20))
  "Online CAGE2 training schedule used when the requested initial count is five.")

(defvar *configured-online-fitness-episodes* 1
  "Episode count requested at launch, before optional online staging.")

(defvar *online-best-reference-scores* nil
  "Per-seed rewards for the protected online historical best.")

(defvar *mixed-training-lineage* nil
  "True when online search descends from an offline or teacher-forcing checkpoint.")

(defconstant +semantic-offline-fitness-protocol+
  :ranked-semantic-behavior-ndcg-reference-v5
  "Version tag for ranked target/response imitation with fixed reference data.")

(defconstant +semantic-offline-recurrent-fitness-protocol+
  :ranked-semantic-recurrent-sequence-reference-v1
  "Version tag for episode-ordered recurrent semantic imitation.")

(defun semantic-offline-fitness-protocol ()
  "Return the active stateless or recurrent offline checkpoint protocol."
  (if *recurrent-policy-enabled*
      +semantic-offline-recurrent-fitness-protocol+
      +semantic-offline-fitness-protocol+))

(defconstant +teacher-forcing-teacher-protocol+
  :teacher-forcing-ranked-reference-opening-v2
  "Version tag for teacher-controlled traces aligned with the opening protocol.")

(defconstant +teacher-forcing-dagger-protocol+
  :teacher-forcing-dagger-ranked-reference-opening-v3
  "Version tag for bounded learner-on-policy DAgger imitation.")

(defconstant +teacher-forcing-recurrent-teacher-protocol+
  :teacher-forcing-recurrent-sequence-opening-v1
  "Version tag for recurrent imitation on teacher-controlled episodes.")

(defconstant +teacher-forcing-recurrent-dagger-protocol+
  :teacher-forcing-recurrent-dagger-sequence-opening-v1
  "Version tag for recurrent imitation on complete learner-controlled episodes.")

(defun teacher-forcing-fitness-protocol ()
  "Return the checkpoint protocol for the active teacher-forcing rollout mode."
  (if *recurrent-policy-enabled*
      (ecase *teacher-forcing-rollout-mode*
        (:teacher +teacher-forcing-recurrent-teacher-protocol+)
        (:dagger +teacher-forcing-recurrent-dagger-protocol+))
      (ecase *teacher-forcing-rollout-mode*
        (:teacher +teacher-forcing-teacher-protocol+)
        (:dagger +teacher-forcing-dagger-protocol+))))

(defconstant +teacher-reference-episodes+ 100
  "Fixed number of deterministic teacher episodes in the reference bank.")

(defconstant +teacher-dagger-replay-capacity+ 10000
  "Maximum learner-visited, teacher-labelled rows retained by DAgger.")

(defconstant +teacher-dagger-full-gc-interval+ 25
  "Generations between full collections of retired DAgger trace storage.")

(defparameter +official-guided-teacher-mixing-rates+
  '((0.60d0 . 0.50d0) (0.30d0 . 0.25d0) (0.0d0 . 0.10d0))
  "Previous-disagreement thresholds and next-generation teacher control rates.")

(defconstant +hamming-raw-mismatch-weight+ 40
  "Integer weight for one raw-observation mismatch.")

(defconstant +hamming-scan-mismatch-weight+ 104
  "Integer weight for one scan-state mismatch.")

(defconstant +hamming-availability-mismatch-weight+ 13
  "Integer weight for one decoy-availability mismatch.")

(defconstant +hamming-projection-cache-limit+ 50000
  "Maximum number of unseen observations memoized during one operation.")

(defconstant +inf+ most-positive-fixnum)

(defvar *running* nil
  "When true, the active search should continue evolving.

Setting this to NIL requests cancellation.  *SEARCH-ACTIVE* remains true until
the search worker has actually exited, so validation cannot race a stopping
search and turn this flag back on.")

(defvar *search-active* nil
  "True from search worker launch until that worker has completely exited.")

(defvar *validation-running* nil
  "True while a validation worker owns the Python/Gym execution path.")

(defvar *last-search-failure* nil
  "Diagnostic plist for the most recent unhandled search-worker error.")

(defvar *last-telemetry-error* nil
  "Diagnostic plist for the most recent non-fatal telemetry failure.")

(defvar *current-gym-environment-name* nil
  "Gym environment used by the current search, recorded in checkpoints.")

(defvar *current-search-mode* nil
  "Active search mode: :ONLINE, :OFFLINE, :TEACHER-FORCING, or
:OFFICIAL-GUIDED.")

(defvar *current-search-seed* nil
  "Resolved integer seed used by the current search, recorded in checkpoints.")

(defvar *search-start-time* nil
  "Universal time at which the active search began.")

(defvar *generation* 1
  "Generation counter.")

(defparameter *population-size* 
  "The number of candidate solutions at any given time.")

(defparameter *num-observations* 
  "The number of possible observations.")

(defparameter *num-actions* 
  "The number of possible actions.")

(defparameter *init-num-learners* 
  "The number of learners that a team is initialized with.
   Recommended: ceil(num-actions/2).")

(defparameter *max-num-learners* 
  "The maximum number of learners that a team may have.
   Recommended hard limit: 32.")

(defparameter *soft-num-learners* 11
  "Team size above which learner-addition pressure gradually decreases.")

(defparameter *p-add* 
  "The probability that a new learner is added to a team during mutation.
   Recommended value: 0.2")

(defparameter *p-del* 
  "The probability that a learner is removed from a team during mutation.
   Recommended value: 0.1")

(defparameter *p-mut* 
  "The probability that a learner's program is mutated in a team during mutation.
   Recommended value: 0.5")

(defparameter *p-act* 
  "The probability that a learner's action is changed during mutation.
   Recommended value: 0.2")

(defparameter *p-swap*
  "The probability that a swap of actions occurs between two
   learners on a team during mutation.
   Recommended value: 0.1")

(defparameter *gap* 
  "The number of agents that will be replaced each generation.
   Recommended value: 0.5")

(defparameter *init-program-size*
  "The number of instructions in a program when it is initialized.
   Recommended value: 100")

(defparameter *max-program-size* 
  "The maximum number of instructions in a program.
   Recommended hard limit: 256.")

(defparameter *soft-program-size* 128
  "Program size above which instruction-addition pressure gradually decreases.")

(defparameter *p-add-instr* 
  "The probability that a new instruction is added when mutating a program.
   Recommended value: 0.9")

(defparameter *p-del-instr* 
  "The probability that an instruction is removed when msutating a program.
   Recommended value: 0.5")

(defparameter *p-swap-instrs* 
  "The probability that two instructions are swapped when mutating a program.
   Recommended value: 1.0")

(defparameter *p-mut-constant* 
  "The probability that a constant in a random instruction in a program
   will be mutated by adding gaussian noise.
   Recommended value: 0.5")

(defparameter *p-mut-constant-sign* 
  "The probability that when a constant is mutated, its sign will also be
   flipped at the same time.
   Recommended value: 0.1")

(defvar *teams* nil
  "The team population for this island.")

(defvar *fitness-fn*
  "The fitness function wrapped in a closure that
   is made according to whether the mode is set to
   online or offline.")

(defparameter *migration-interval* 50
  "The number of generations to wait between sending migrants.")

(defparameter *batch-size* 1000
  "The number of dataset rows sampled per offline generation.")

(defparameter *online-fitness-episodes* 1
  "Number of complete episodes used to evaluate one team in online mode.

A value of 1 reproduces the original BES/TPG behaviour.
Larger values reduce fitness variance by averaging multiple rollouts.")

(defvar *online-fitness-episode-seeds* nil
  "Episode seeds shared by all CAGE2 candidates in the current evaluation batch.")

(defvar *offline-training-dataset* nil
  "Semantic dataset used for generation training batches.")

(defvar *offline-reference-dataset* nil
  "Fixed held-out semantic dataset used to compare historical best teams.")

(defvar *teacher-training-dataset* nil
  "Generation-shared teacher trace used for population fitness.")

(defvar *teacher-reference-dataset* nil
  "Fixed teacher trace bank used for historical-best comparisons.")

(defvar *teacher-dagger-replay-rows* nil
  "Bounded learner-visited rows retained by teacher-forcing DAgger.")

(defvar *teacher-dagger-replay-episodes* nil
  "Bounded complete learner episodes retained by recurrent DAgger.")

(defvar *teacher-dagger-random-state* nil
  "Private random state used only to sample DAgger replay rows.")

(defvar *last-dagger-diagnostics* nil
  "Diagnostics from the most recent learner-proposal DAgger rollout.")

(defvar *teacher-dagger-behavior-team-snapshot* nil
  "Independent deep copy of the prior imitation champion used for DAgger.")

(defvar *teacher-dagger-behavior-fitness* nil
  "Ranked-imitation fitness associated with the DAgger behavior snapshot.")

(defvar *teacher-dagger-behavior-generation* nil
  "Generation that produced the current DAgger behavior snapshot.")

(defvar *official-guided-seed-streams* nil
  "Serializable plist holding independent training, racing, promotion, and
reference stream roots and cursors.")

(defvar *phase4-selection-enabled* nil
  "When true, replace aggregate truncation with grouped survivor lexicase.")

(defvar *phase4-selection-rng-root* nil
  "Root of the independent counter-based Phase-4a selection stream.")

(defvar *phase4-selection-rng-cursor* 0
  "Number of deterministic Phase-4a selection draws already consumed.")

(defvar *phase4-selection-age* 0
  "Number of completed Phase-4a survivor-selection generations.")

(defvar *phase4-case-groups* nil
  "Active generation case groups as plists containing keys and row indices.")

(defvar *phase4-row-group-keys* nil
  "Vector mapping each generation row to its active Phase-4a case keys.")

(defvar *phase4-team-group-scores* nil
  "EQ table mapping evaluated roots to group-score EQUAL hash tables.")

(defvar *phase4-team-group-exact-rates* nil
  "EQ table mapping evaluated roots to per-case executable exact rates.")

(defvar *phase4-team-row-behaviors* nil
  "EQ table mapping evaluated roots to compact exact row behavior vectors.")

(defvar *phase4-group-epsilons* nil
  "EQUAL table of full-population raw-MAD epsilons for active cases.")

(defvar *phase4-group-medians* nil
  "EQUAL table of full-population median scores for active cases.")

(defvar *phase4-active-specialists* nil
  "EQ table of live specialist team objects and lifecycle records.")

(defvar *phase4-specialist-history* nil
  "Completed serializable Phase-4a specialist lifecycle records.")

(defvar *phase4b-disagreement-audit-enabled* nil
  "When true, classify DAgger errors for Phase-4b without changing evolution.")

(defvar *phase4-selection-generation-record* nil
  "Pending serializable Phase-4a record for the current generation.")

(defvar *official-guided-last-evaluation* nil
  "Structured record from the latest completed official challenger evaluation.")

(defvar *official-guided-best-evaluation* nil
  "Structured official evaluation record associated with *BEST-TEAM*.")

(defvar *official-guided-incumbent-version* 0
  "Monotonic token used to reject stale asynchronous challenger results.")

(defvar *behavioral-locality-enabled* nil
  "When true, observe parent/child semantic disruption without changing mutation.")

(defvar *semantic-locality-control-enabled* nil
  "When true, Phase 3 bounds most offspring by measured behavioral locality.")

(defvar *semantic-locality-control-age* 0
  "Number of completed Phase-3 reproduction generations in this run lineage.")

(defvar *semantic-locality-control-generation-records* nil
  "Accepted-child control decisions waiting to be journaled this generation.")

(defvar *active-mutation-events* nil
  "Dynamically bound list of mutation-layer events for one reproduced child.")

(defvar *behavioral-probe-fixed-reference* nil
  "Long-lived teacher/reference quarter of the Phase-2 probe archive.")

(defvar *behavioral-probe-fixed-early* nil
  "Long-lived early-critical quarter of the Phase-2 probe archive.")

(defvar *behavioral-probe-archive* nil
  "Current versioned mixture of fixed and rolling Phase-2 probes.")

(defvar *behavioral-probe-revision* 0
  "Monotonic revision of the active Phase-2 probe archive.")

(defvar *behavioral-teacher-action-support* nil
  "EQUAL hash set of semantic pairs emitted by the active teacher reference.")

(defvar *behavioral-signature-cache* nil
  "Per-archive EQ cache of policy rankings on Phase-2 probes.")

(defvar *behavioral-team-lineage* nil
  "EQ map from live reproduced teams to their parent/child diagnostic record.")

(defvar *behavioral-team-parents* nil
  "EQ map from live reproduced children to their unmodified direct parents.")

(defvar *behavioral-generation-records* nil
  "Phase-2 child diagnostics waiting to be persisted for this generation.")

(defvar *behavioral-locality-sampling-candidates* nil
  "Live parent/child pairs eligible for passive sampling this generation.")

(defvar *behavioral-locality-sample-cursor* 0
  "Monotonic cursor for the independent Phase-2 diagnostic seed sequence.")

(defvar *behavioral-locality-stratum-counts* nil
  "Serializable alist counting submitted passive samples by distance stratum.")

(defvar *behavioral-locality-sample-process* nil
  "UIOP process information for the active passive-locality worker.")

(defvar *behavioral-locality-sample-job* nil
  "Metadata for the active passive-locality worker, never used by selection.")

(defvar *offline-fitness-batch-indices* nil
  "Uniform row indices shared by all semantic-offline candidates in one generation.")

(defvar *offline-fitness-batch-episode-indices* nil
  "Complete episode ranges shared by recurrent-offline candidates in one generation.")

(defvar *current-dataset-name* nil
  "Dataset requested for the current offline search.")

(defvar *current-dataset-fingerprint* nil
  "Portable file-name/size identity for the current semantic train/validation pair.")

(defvar *hamming-space-enabled* nil
  "When true, project unseen CAGE2 inputs onto a demonstrated observation.")

(defvar *hamming-dataset-name* nil
  "Semantic training dataset used to build the fixed Hamming reference space.")

(defvar *hamming-observation-index* nil
  "Read-only index of unique demonstrated observations for Hamming projection.")

(defvar *current-hamming-dataset-fingerprint* nil
  "Portable identity of the dataset backing the active Hamming projector.")

(defvar *hamming-validation-tracking-enabled* nil
  "When true, record exact-reference coverage during validation only.")

(defvar *hamming-validation-lookups* 0
  "Number of policy observations checked during the current validation.")

(defvar *hamming-validation-misses* 0
  "Number of validation observations absent from the exact reference set.")

(defvar *hamming-validation-unique-misses* nil
  "Content-based set of distinct missed validation observations.")

(defvar *last-hamming-validation-coverage* nil
  "Coverage plist produced by the most recently completed validation.")

(defvar *best-team* nil
  "Best root team seen so far.")

(defvar *best-fitness* nil
  "Fitness of the best root team seen so far.")

(defparameter *checkpoint-directory*
  "~/Documents/Research/checkpoints/"
  "Default directory for checkpoints.")
