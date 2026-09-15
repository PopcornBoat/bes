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

(defvar *factored-actions-enabled* nil
  "When true, newly created atomic actions contain categorical target and
response fields. Legacy numeric atomic actions remain executable so historical
checkpoints can be loaded and gradually mutated into the new representation.")

(defparameter *decoy-order-mode* :evolved
  "CAGE2 Decoy ordering mode. :FIXED always uses the teacher-derived agreement
order; :EVOLVED uses each root team's serialized, mutable option orders.")

(defparameter *cage2-opening-mode* :fixed
  "CAGE2 episode-opening mode. :FIXED executes the three main-agent probe
actions before consulting TPG; :POLICY lets TPG control the episode from step 0.")

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
  :ranked-semantic-next-best-shared-seeds-opening-v7
  "Version tag for ranked semantic CAGE2 execution and shared episode seeds.")

(defconstant +semantic-offline-fitness-protocol+
  :ranked-semantic-behavior-ndcg-reference-v5
  "Version tag for ranked target/response imitation with fixed reference data.")

(defconstant +teacher-forcing-fitness-protocol+
  :teacher-forcing-ranked-reference-opening-v2
  "Version tag for teacher traces aligned with the episode-opening protocol.")

(defconstant +teacher-reference-episodes+ 100
  "Fixed number of deterministic teacher episodes in the reference bank.")

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
  "Active search mode: :ONLINE, :OFFLINE, or :TEACHER-FORCING.")

(defvar *current-search-seed* nil
  "Resolved integer seed used by the current search, recorded in checkpoints.")

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

(defvar *offline-fitness-batch-indices* nil
  "Uniform row indices shared by all semantic-offline candidates in one generation.")

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
