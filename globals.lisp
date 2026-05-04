(in-package :bes)

(defconstant *num-threads* 140
  "The number of CPU cores available for multi-threading.")

(defconstant +num-registers+ 8
  "The number of registers that a program has access to during execution.
   This is declared as a constant for optimization speed.")

(defconstant +inf+ most-positive-fixnum)

(defvar *running* nil
  "This is enabled when a search is started by a TCP connection
  and disabled when a search is stopped also by a TCP connection.")

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
   Recommended: num-actions.")

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
   Recommended value: inf")

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
  "The number of generations to wait between sending migrants.")
