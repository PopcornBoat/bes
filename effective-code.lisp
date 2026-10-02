(in-package :cl-tpg)

(defconstant +effective-code-analysis-protocol+ :effective-code-v1
  "Version identifier for non-mutating program liveness analysis.")

(defun normalize-effective-output-registers (output-registers)
  "Return validated, duplicate-free internal register indices."
  (let ((registers
          (remove-duplicates
           (coerce output-registers 'list)
           :test #'=)))
    (unless registers
      (error "Effective-code analysis requires at least one output register."))
    (dolist (register registers)
      (unless (and (integerp register)
                   (<= 0 register)
                   (< register +num-registers+))
        (error "Invalid effective-code output register: ~S" register)))
    registers))

(defun effective-register-source-index (type value)
  "Return VALUE as a validated register index when TYPE is :REG."
  (when (eq type :reg)
    (let ((index (truncate value)))
      (unless (<= 0 index (1- +num-registers+))
        (error "Instruction references invalid register index ~S." index))
      index)))

(defun effective-observation-source-index (type value)
  "Return VALUE as an observation index when TYPE is :OBS."
  (when (eq type :obs)
    (truncate value)))

(defun record-effective-source (live observations type value)
  "Record the dependency denoted by one effective instruction source."
  (case type
    (:reg
     (setf (sbit live (effective-register-source-index type value)) 1))
    (:obs
     (setf (gethash (effective-observation-source-index type value)
                    observations)
           t))))

(defun analyze-program-effective-code
       (program &key (output-registers (list +bid-register+)))
  "Return a non-mutating backward-slice analysis of PROGRAM.

An instruction is effective when its destination is live while traversing the
program backwards from OUTPUT-REGISTERS. A live destination kills the value
written before it, while register sources make their earlier values live. The
result is a plist containing an independently owned bit mask, instruction
indices, observation dependencies, and registers whose initial values reach an
output. No instructions or programs are modified."
  (let* ((outputs (normalize-effective-output-registers output-registers))
         (instructions (program-instructions program))
         (count (length instructions))
         (mask (make-array count :element-type 'bit :initial-element 0))
         (live (make-array +num-registers+
                           :element-type 'bit
                           :initial-element 0))
         (observations (make-hash-table :test #'eql)))
    (dolist (register outputs)
      (setf (sbit live register) 1))
    (loop for index fixnum downfrom (1- count) to 0
          for instruction = (aref instructions index)
          for destination = (instruction-dest instruction)
          do (unless (<= 0 destination (1- +num-registers+))
               (error "Instruction ~D writes invalid register index ~S."
                      index destination))
             (when (= (sbit live destination) 1)
               (setf (sbit mask index) 1
                     (sbit live destination) 0)
               (record-effective-source
                live observations
                (instruction-src1-type instruction)
                (instruction-src1-val instruction))
               (when (= (instruction-arity instruction) 2)
                 (record-effective-source
                  live observations
                  (instruction-src2-type instruction)
                  (instruction-src2-val instruction)))))
    (let* ((indices
             (loop for bit across mask
                   for index fixnum from 0
                   when (= bit 1) collect index))
           (effective-count (length indices)))
      (list
       :protocol +effective-code-analysis-protocol+
       :output-registers (copy-list outputs)
       :instruction-count count
       :effective-instruction-count effective-count
       :intron-count (- count effective-count)
       :effective-ratio
         (if (plusp count)
             (/ effective-count (coerce count 'double-float))
             1.0d0)
       :effective-mask mask
       :effective-indices indices
       :observation-indices
         (sort (loop for observation being the hash-keys of observations
                     collect observation)
               #'<)
       :initial-register-indices
         (loop for bit across live
               for register fixnum from 0
               when (= bit 1) collect register)))))

(defun effective-program-record
       (team learner &key (output-registers (list +bid-register+)))
  "Return one serialization-safe effective-code record for LEARNER."
  (let* ((analysis
           (analyze-program-effective-code
            (learner-program learner)
            :output-registers output-registers)))
    (list
     :team-id (team-id team)
     :learner-id (learner-id learner)
     :instruction-count (getf analysis :instruction-count)
     :effective-instruction-count
       (getf analysis :effective-instruction-count)
     :intron-count (getf analysis :intron-count)
     :effective-ratio (getf analysis :effective-ratio)
     :observation-indices (copy-list (getf analysis :observation-indices))
     :initial-register-indices
       (copy-list (getf analysis :initial-register-indices)))))

(defun analyze-team-effective-code
       (root-team &key (output-registers (list +bid-register+)))
  "Return a non-mutating effective-code summary for ROOT-TEAM's closure.

The default output is the bid register only, which is correct for stateless
Semantic-36 target/response checkpoints. Callers auditing legacy terminal
register decoding or another policy contract must explicitly include every
register that contributes to policy output."
  (let* ((outputs (normalize-effective-output-registers output-registers))
         (teams (closure root-team))
         (records
           (loop for team in teams append
             (loop for learner in (team-learners team)
                   collect
                   (effective-program-record
                    team learner :output-registers outputs))))
         (instruction-count
           (loop for record in records
                 sum (getf record :instruction-count)))
         (effective-count
           (loop for record in records
                 sum (getf record :effective-instruction-count)))
         (observations (make-hash-table :test #'eql)))
    (dolist (record records)
      (dolist (observation (getf record :observation-indices))
        (setf (gethash observation observations) t)))
    (list
     :protocol +effective-code-analysis-protocol+
     :output-registers (copy-list outputs)
     :team-count (length teams)
     :learner-count (length records)
     :instruction-count instruction-count
     :effective-instruction-count effective-count
     :intron-count (- instruction-count effective-count)
     :effective-ratio
       (if (plusp instruction-count)
           (/ effective-count (coerce instruction-count 'double-float))
           1.0d0)
     :programs-without-effective-instructions
       (count 0 records
              :key (lambda (record)
                     (getf record :effective-instruction-count)))
     :max-program-size
       (if records
           (reduce #'max records
                   :key (lambda (record)
                          (getf record :instruction-count)))
           0)
     :max-effective-program-size
       (if records
           (reduce #'max records
                   :key (lambda (record)
                          (getf record :effective-instruction-count)))
           0)
     :observation-indices
       (sort (loop for observation being the hash-keys of observations
                   collect observation)
             #'<)
     :program-records records)))

(defun effective-code-most-bloated-programs (analysis limit)
  "Return up to LIMIT copied program records ordered by intron count."
  (subseq
   (stable-sort
    (copy-list (getf analysis :program-records))
    (lambda (left right)
      (let ((left-introns (getf left :intron-count))
            (right-introns (getf right :intron-count)))
        (if (= left-introns right-introns)
            (> (getf left :instruction-count)
               (getf right :instruction-count))
            (> left-introns right-introns)))))
   0
   (min limit (length (getf analysis :program-records)))))

(defun write-effective-code-report
       (root-team &key (stream *standard-output*) checkpoint-path fitness
                       metadata (output-registers (list +bid-register+))
                       (top-programs 20))
  "Write a deterministic human-readable effective-code report for ROOT-TEAM.

This function performs analysis only. It never removes instructions, changes
programs, or changes the graph. The returned value is the full analysis plist."
  (let ((analysis
          (analyze-team-effective-code
           root-team :output-registers output-registers)))
    (format stream "Effective code analysis~%")
    (format stream "protocol: ~A~%" (getf analysis :protocol))
    (when checkpoint-path
      (format stream "checkpoint: ~A~%" checkpoint-path))
    (when fitness
      (format stream "stored fitness: ~S~%" fitness))
    (when metadata
      (format stream "generation: ~S~%" (getf metadata :generation))
      (format stream "terminal action format: ~S~%"
              (getf metadata :terminal-action-format))
      (format stream "instruction set profile: ~S~%"
              (or (getf metadata :instruction-set-profile) :full))
      (format stream "recurrent policy: ~S~%"
              (getf metadata :recurrent-policy-enabled)))
    (format stream "output register indices: ~S~%"
            (getf analysis :output-registers))
    (format stream "teams: ~D~%" (getf analysis :team-count))
    (format stream "learners/programs: ~D~%" (getf analysis :learner-count))
    (format stream "instructions: ~D~%" (getf analysis :instruction-count))
    (format stream "effective instructions: ~D~%"
            (getf analysis :effective-instruction-count))
    (format stream "introns: ~D~%" (getf analysis :intron-count))
    (format stream "effective ratio: ~,6F~%"
            (getf analysis :effective-ratio))
    (format stream "programs without effective instructions: ~D~%"
            (getf analysis :programs-without-effective-instructions))
    (format stream "max program size: ~D~%"
            (getf analysis :max-program-size))
    (format stream "max effective program size: ~D~%"
            (getf analysis :max-effective-program-size))
    (format stream "effective observation indices: ~S~%"
            (getf analysis :observation-indices))
    (format stream "~%Most bloated programs (up to ~D):~%" top-programs)
    (format stream
            "~20A ~22A ~8A ~10A ~8A ~10A~%"
            "team" "learner" "total" "effective" "introns" "ratio")
    (dolist (record
               (effective-code-most-bloated-programs
                analysis top-programs))
      (format stream
              "~20A ~22A ~8D ~10D ~8D ~10,6F~%"
              (getf record :team-id)
              (getf record :learner-id)
              (getf record :instruction-count)
              (getf record :effective-instruction-count)
              (getf record :intron-count)
              (getf record :effective-ratio)))
    analysis))
