;; -*- lexical-binding: t; -*-
(require 'transient)
(require 'cl-lib)

(defvar *islands*
  '(("127.0.0.1" . 0) ;; ds-login2
    ("10.100.202.42" . 1) ;; ds-cmlm-02
    ("10.100.202.43" . 2) ;; ds-cmlm-03
    ("10.100.202.44" . 3) ;; ds-cmlm-04
    ("10.100.202.46" . 4) ;; ds-cmlm-06
    ("10.100.202.47" . 5) ;; ds-cmlm-07
    ("10.100.202.48" . 6) ;; ds-cmlm-08
    ("10.100.202.49" . 7) ;; ds-cmlm-09
    ("10.100.202.51" . 8) ;; ds-cmlm-11
    ("10.100.202.52" . 9) ;; ds-cmlm-12
    ("10.100.202.54" . 10) ;; ds-cmlm-14
    ("10.100.202.55" . 11) ;; ds-cmlm-15
    ("10.100.202.56" . 12) ;; ds-cmlm-16
    ("10.100.202.57" . 13) ;; ds-cmlm-17
    ("10.100.202.58" . 14) ;; ds-cmlm-18
    ("10.100.202.59" . 15)) ;; ds-cmlm-19
  "The mapping between IP address and their island ID.")

(defun plist-to-cl-sexp (plist)
  "Format a plist as a Common Lisp readable s-expression with keywords."
  (concat "("
          (mapconcat
           (lambda (pair)
             (let ((key (car pair))
                   (val (cdr pair)))
               (format ":%s %s"
                       (substring (symbol-name key) 1)  ; strip the leading ':'
                       (cond
                        ((stringp val) (format "\"%s\"" val))
                        ((symbolp val) (format ":%s" (symbol-name val)))
                        ((numberp val) (format "%s" val))
                        (t (format "%S" val))))))
           (cl-loop for (k v . _rest) on plist by #'cddr
                    collect (cons k v))
           " ")
          ")"))

(defun lookup-ip-by-island-id (id)
  "Given an island ID, look up the island's IP address."
  (car (rassoc id *islands*)))

(defun string-to-number-or-inf (string)
  "Returns a string as a number. If 'inf' is provided then :inf is returned."
  (if (string= string "inf")
      :inf
    (string-to-number string)))

(defun make-payload-from-transient-args (args)
  "Given a list of transient args, construct the TCP payload for starting searches."
  (let ((mode (pcase (transient-arg-value "--mode=" args)
		("online" :online)
		("offline" :offline)
		(other (error "Invalid mode: %S" other))))
	(gym-environment-name  (pcase (transient-arg-value "*env=" args)
				 ("none" :none)
				 (other other)))
	(dataset-name (pcase (transient-arg-value "*dataset=" args)
			("none" :none)
			(other other)))
	(num-observations (string-to-number
			   (transient-arg-value "*num-observations=" args)))
	(num-actions (string-to-number
		      (transient-arg-value "*num-actions=" args)))
        (population-size (string-to-number
	 		  (transient-arg-value "*population-size=" args)))
	(init-num-learners (string-to-number
			    (transient-arg-value "*init-num-learners=" args)))
	(max-num-learners (string-to-number-or-inf
			   (transient-arg-value "*max-num-learners=" args)))
	(p-add (string-to-number
		(transient-arg-value "*p-add=" args)))
	(p-del (string-to-number
	 	(transient-arg-value "*p-del=" args)))
	(p-mut (string-to-number
		(transient-arg-value "*p-mut=" args)))
	(p-act (string-to-number
		(transient-arg-value "*p-act=" args)))
	(p-swap (string-to-number
	 	 (transient-arg-value "*p-swap=" args)))
	(gap (string-to-number
	      (transient-arg-value "*gap=" args)))
        (init-program-size (string-to-number-or-inf
	 		    (transient-arg-value "*init-program-size=" args)))
	(max-program-size (string-to-number-or-inf
	 		   (transient-arg-value "*max-program-size=" args)))
	(p-add-instr (string-to-number
		      (transient-arg-value "*p-add-instr=" args)))
	(p-del-instr (string-to-number
		      (transient-arg-value "*p-del-instr=" args)))
	(p-swap-instrs (string-to-number
			(transient-arg-value "*p-swap-instrs=" args)))
	(p-mut-constant (string-to-number
			 (transient-arg-value "*p-mut-constant=" args)))
	(p-mut-constant-sign (string-to-number
			      (transient-arg-value "*p-mut-constant-sign=" args)))
	(migration-interval (string-to-number
			     (transient-arg-value "*migration-interval=" args)))
	(batch-size (string-to-number
		     (transient-arg-value "*batch-size=" args)))
	(seed (let ((seed-arg (transient-arg-value "*seed=" args)))
		(cond
		 ((string= seed-arg "random")
		  :random)
		 ((stringp seed-arg)
		  (string-to-number seed-arg))))))
    `(:type :start-search
      :mode ,mode
      :gym-environment-name ,gym-environment-name
      :dataset-name ,dataset-name
      :num-observations ,num-observations
      :num-actions ,num-actions
      :population-size ,population-size
      :init-num-learners ,init-num-learners
      :max-num-learners ,max-num-learners
      :p-add ,p-add
      :p-del ,p-del
      :p-mut ,p-mut
      :p-act ,p-act
      :p-swap ,p-swap
      :gap ,gap
      :init-program-size ,init-program-size
      :max-program-size ,max-program-size
      :p-add-instr ,p-add-instr
      :p-del-instr ,p-del-instr
      :p-swap-instrs ,p-swap-instrs
      :p-mut-constant ,p-mut-constant
      :p-mut-constant-sign ,p-mut-constant-sign
      :migration-interval ,migration-interval
      :batch-size ,batch-size
      :seed ,seed)))

(transient-define-suffix start-search ()
  (interactive)
  (let* ((args (transient-args 'start-search-menu))
         (island-arg (transient-arg-value "--island=" args))
         (island-ids (if (string= island-arg "all")
                         '(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
                         (list (string-to-number island-arg))))
         (ip-addresses (mapcar #'lookup-ip-by-island-id island-ids))
         (payload (make-payload-from-transient-args args)))
    (message "[LOCAL] Sending start-search request to islands %s at IPs %s."
             island-ids ip-addresses)
    (message "%s" payload)
    (cl-loop for island-id in island-ids
             for ip-address in ip-addresses
             do
             (message "[LOCAL] Sending start-search request to island %s at IP address %s."
                      island-id ip-address)
             (let ((proc (make-network-process
                          :name "start-search-tcp-client"
                          :host ip-address
                          :service 8080
                          :family 'ipv4
                          :nowait nil
                          :sentinel (lambda (_proc event)
                                      (message "TCP Event: %s" event)))))
               (process-send-string proc (concat (plist-to-cl-sexp payload) "\n"))
               (process-send-eof proc)))))

(transient-define-suffix stop-search ()
  (interactive)
  (let* ((args (transient-args 'stop-search-menu))
         (island-arg (transient-arg-value "--island=" args))
         (island-ids (if (string= island-arg "all")
                         '(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
                       (list (string-to-number island-arg))))
         (payload '(:type :stop-search)))
    (cl-loop for id in island-ids
             for ip = (lookup-ip-by-island-id id)
             do
             (when ip
               (message "[LOCAL] Stopping island %s at %s" id ip)
               (condition-case nil
                   (let ((proc (make-network-process
                                :name "stop-search-tcp-client"
                                :host ip :service 8080 :family 'ipv4
                                :nowait t))) ;; t prevents the 'hang' and immediate error
                     (process-send-string proc (format "%S\n" payload))
                     (process-send-eof proc))
                 (error (message "[LOCAL] Island %s connection failed (already down)." id)))))))
	    
(transient-define-prefix stop-search-menu ()
  "Menu for stopping searches."
  ["Island"
   ("-I" "Island" "--island="
    :choices ("all" "0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "10" "11" "12" "13" "14" "15"))]
  ["Actions"
   ("D" "STOP Search" stop-search)
   ("q" "Back to Main" bes-menu)])

(transient-define-prefix start-search-menu ()
  "Menu for configuring TPG hyperparameters before starting a run."
  :refresh-suffixes t
  ;; These are the default values for the entire prefix
  :value '("*p-add=0.2" 
           "*p-del=0.1"
           "*p-mut=0.5" 
           "*p-act=0.2"
	   "*p-swap=0.1"
           "*init-program-size=100"
           "*max-program-size=inf"
           "*gap=0.5"
           "*p-add-instr=0.9"
           "*p-del-instr=0.5"
           "*p-swap-instrs=1.0"
	   "*p-mut-constant=0.5"
	   "*p-mut-constant-sign=0.1"
	   "*env=none"
	   "*dataset=none"
	   "*population-size=160"
	   "*init-num-learners=3"
	   "*max-num-learners=inf"
	   "*migration-interval=50"
	   "*batch-size=1000"
	   "*seed=random")
  ["Island"
    ("-I" "Island" "--island="
    :choices ("all" "0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "10" "11" "12" "13" "14" "15"))]
  ["Evaluation"
   ("-M" "Evaluation Mode" "--mode="
    :choices ("online" "offline"))
   ("-G" "Gymnasium Environment Name" "*env="
    :choices ("none" "Hopper-v5" "Walker2d-v5" "HalfCheetah-v5" "Acrobot-v1" "LunarLander-v3" "MountainCar-v0" "CartPole-v1"))
   ("-F" "Dataset Name" "*dataset=")]
  ["Key Settings"
   ("-Z" "Number of Observations" "*num-observations=")
   ("-X" "Number of Actions" "*num-actions=")
   ("-P" "Population Size" "*population-size=")
   ("-g" "Gap" "*gap=")
   ("-n" "Migration Interval" "*migration-interval=") 
   ("-b" "Batch Size" "*batch-size=")
   ("-s" "Seed" "*seed=")]
  [:description "Team Constraints"
   ("-l" "Initial Number of Learners" "*init-num-learners=")
   ("-L" "Maximum Number of Learners" "*max-num-learners=")]
  [:description "Team Mutation Probabilities"
   ("-a" "Add Learner (p)"      "*p-add=")
   ("-d" "Delete Learner (p)"   "*p-del=")
   ("-m" "Mutate Program (p)"   "*p-mut=")
   ("-c" "Change Action (p)"    "*p-act=")
   ("-w" "Swap Learner Actions (p)" "*p-swap=")]

  [:description "Program Constraints"
   ("-i" "Initial Size"         "*init-program-size=")
   ("-x" "Maximum Size"         "*max-program-size=")]

  [:description "Program Mutation Probabilities"
   ("-A" "Add Instruction (p)"  "*p-add-instr=")
   ("-D" "Delete Instruction (p)" "*p-del-instr=")
   ("-S" "Swap Instructions (p)" "*p-swap-instrs=")
   ("-C" "Mutate Constant (p)" "*p-mut-constant=")
   ("-V" "Mutate Constant Sign (p)" "*p-mut-constant-sign=")]

  ["Actions"
   ("S" "START Search" start-search)
   ("q" "Back to Main" bes-menu)])

(transient-define-prefix bes-menu ()
  "Control Center for BES."
  ["Dashboard Controls"
   ("r" "Start Auto-Refresh" bes-start-auto-refresh)
   ("s" "Stop Auto-Refresh" bes-stop-auto-refresh)
   ("g" "Force Refresh" revert-buffer)]

  ["Runs"
   ("S" "Configure & START" start-search-menu)
   ("D" "Stop a search" stop-search-menu)]

  ["Navigation"
   ("q" "Quit Menu" transient-quit-one)])

(defvar bes-data (make-hash-table :test 'equal))

(defvar bes-refresh-timer nil
  "Timer for auto-refreshing the BES dashboard.")

(defun bes-start-auto-refresh ()
  "Start a timer to refresh the *bes* buffer every 2 seconds."
  (interactive)
  ;; Cancel existing timer if it exists
  (when bes-refresh-timer
    (cancel-timer bes-refresh-timer))

  (setq bes-refresh-timer
	(run-at-time 0 1
		     (lambda ()
		       (let ((buf (get-buffer "*bes-log*")))
			 (when (buffer-live-p buf)
			   (with-current-buffer buf
			     (goto-char (point-max)))))
		       (let ((buf (get-buffer "*bes*")))
			 (when (buffer-live-p buf)
			   (with-current-buffer buf
			     (revert-buffer t t))))))))

(defun bes-stop-auto-refresh ()
  "Stop the BES refresh timer."
  (interactive)
  (cancel-timer bes-refresh-timer)
  (setq bes-refresh-timer nil))

(define-derived-mode bes-mode tabulated-list-mode "BES-Islands"
  "Major mode for displaying Island fitness data."
  (setq tabulated-list-format [("Island" 15 t) 
                               ("Fitness" 15 t)
			       ("Generation" 15 t)
			       ("CPU" 15 t)
			       ("Mem" 15 t)])
  (setq tabulated-list-padding 2)
  (add-hook 'tabulated-list-revert-hook #'bes--refresh-data nil t)
  (tabulated-list-init-header))

(defun bes--refresh-data ()
  "Translate hash table data into tabulated-list format."
  (interactive)
  (let (entries)
    (maphash (lambda (id data)
	       (let ((fitness (plist-get data :fitness))
		     (gen (plist-get data :generation))
		     (cpu (plist-get data :cpu))
		     (memory (plist-get data :memory)))
		 (push (list id (vector
				 (format "%s" id)
				 (format "%s" (or fitness "-"))
				 (format "%s" (or gen "-"))
				 (format "%.1f" (or cpu 0.0))
				 (format "%.1f" (or memory 0.0))))
		       entries)))
	     bes-data)
    (setq tabulated-list-entries entries)))

(defun bes-telemetry-handler (_proc string)
  "Receive telemetry information from the island nodes."
  (ignore-errors
    (let* ((msg (read string))
	   (type (plist-get msg :TYPE))
	   (from-id (plist-get msg :FROM))
	   ;; Get existing data for this island, or an empty list if new.
	   (current-data (gethash from-id bes-data '())))
      (cond
       ((eq type :FITNESS)
	(let ((fitness (plist-get msg :FITNESS))
	      (generation (plist-get msg :GENERATION)))
	  (puthash from-id
		   (plist-put (plist-put current-data :fitness fitness) :generation generation)
		   bes-data)))

       ((eq type :MESSAGE)
	(let ((message (plist-get msg :MSG)))
	  (bes--log-event (format "[ISLAND %s] Message: %s"
				  from-id message))))
       ((eq type :HEARTBEAT)
	(let ((cpu (plist-get msg :CPU))
	      (memory (plist-get msg :MEMORY)))
	  (puthash from-id
		   (plist-put (plist-put current-data :cpu cpu) :memory memory)
		   bes-data)
	  (bes--log-event (format "[ISLAND %s] Heartbeat received."
				  from-id cpu memory))))
       ((eq type :ERROR)
	(let ((error-message (plist-get msg :MSG)))
	  (bes--log-event (propertize (format "ISLAND %s ENCOUNTERED AN ERROR: %s"
					      from-id error-message)
				      'font-lock-face 'error))))))))
	   
(defun bes--log-event (message)
  "Appends MESSAGE to the *bes-log* buffer and caps it at 1000 lines."
  (let ((log-buf (get-buffer-create "*bes-log*"))
        (max-lines 1000))
    (with-current-buffer log-buf
      (let ((inhibit-read-only t))
        (save-excursion
          ;; 1. Move to the end and insert the new log entry
          (goto-char (point-max))
          (insert (format "[%s] %s\n"
                          (format-time-string "%H:%M:%S")
                          message))
          
          ;; 2. Check line count and trim if necessary
          (let ((line-count (count-lines (point-min) (point-max))))
            (when (> line-count max-lines)
              (goto-char (point-min))
              ;; Calculate how many lines to delete to get back to max-lines
              (forward-line (- line-count max-lines))
              (delete-region (point-min) (point)))))))))

(defun bes ()
  "Start BES dashboard and log."
  (interactive)
  ;; Ensure server is running
  (unless (process-live-p (get-process "bes"))
    (make-network-process
     :name "bes" :family 'ipv4 :service 8080 :type 'datagram
     :host "0.0.0.0" :server t :filter #'bes-telemetry-handler))
  
  ;; Setup Dashboard
  (let ((db-buf (get-buffer-create "*bes*"))
        (log-buf (get-buffer-create "*bes-log*")))
    
    (with-current-buffer db-buf
      (bes-mode)
      (revert-buffer))

    ;; Display logic: Dashboard on top, Log on bottom
    (delete-other-windows)
    (switch-to-buffer db-buf)
    (set-window-buffer (split-window-vertically -30) log-buf)))

;; Bind the transient menu to C-c C-c
(define-key bes-mode-map (kbd "C-c C-c") 'bes-menu)

