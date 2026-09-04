(in-package :cl-tpg)

(defvar *server-threads* nil
  "List of threads spawned by START-SERVER.")

(defvar *server-socket* nil
  "The TCP server socket, stored so STOP-SERVER can stop it.")

(defvar *server-running* nil
  "When NIL, server loops will exit.")

(defparameter *telemetry-ip* "127.0.0.1"
  "IP address of the Emacs client receiving telemetry.")

(defparameter *heartbeat-interval* 100
  "The amount of time to wait between sending heartbeats (in seconds).")

(defparameter *islands*
  '((:local . 0)               ;; current local machine / island 0
    ("10.100.202.42" . 1)      ;; ds-cmlm-02
    ("10.100.202.43" . 2)      ;; ds-cmlm-03
    ("10.100.202.44" . 3)      ;; ds-cmlm-04
    ("10.100.202.46" . 4)      ;; ds-cmlm-06
    ("10.100.202.47" . 5)      ;; ds-cmlm-07
    ("10.100.202.48" . 6)      ;; ds-cmlm-08
    ("10.100.202.49" . 7)      ;; ds-cmlm-09
    ("10.100.202.51" . 8)      ;; ds-cmlm-11
    ("10.100.202.52" . 9)      ;; ds-cmlm-12
    ("10.100.202.54" . 10)     ;; ds-cmlm-14
    ("10.100.202.55" . 11)     ;; ds-cmlm-15
    ("10.100.202.56" . 12)     ;; ds-cmlm-16
    ("10.100.202.57" . 13)     ;; ds-cmlm-17
    ("10.100.202.58" . 14)     ;; ds-cmlm-18
    ("10.100.202.59" . 15))    ;; ds-cmlm-19
  "The mapping between island location and island ID.
The special key :LOCAL always resolves dynamically to the current machine IP.")

(defparameter *topology*
  '((1 . (2 5 6 11))
    (2 . (1 3 7 12))
    (3 . (2 4 8 13))
    (4 . (3 5 9 14))
    (5 . (1 4 10 15))
    (6 . (1 7 10 11))
    (7 . (2 6 8 12))
    (8 . (3 7 9 13))
    (9 . (4 8 10 14))
    (10 . (5 6 9 15))
    (11 . (1 6 12 15))
    (12 . (2 7 11 13))
    (13 . (3 12 8 14))
    (14 . (4 9 13 15))
    (15 . (5 10 11 14)))
  "This is a 3x5 toroidal grid. Each island has 4 adjacent neighbours wrapping around if necessary.")

(defun notify-telemetry (msg)
  "Fire and forget a message over UDP to the telemetry client."
  (let ((socket (usocket:socket-connect *telemetry-ip* 8080 :protocol :datagram)))
    (unwind-protect
	 (usocket:socket-send socket msg (length msg))
      (usocket:socket-close socket))))
			 
(defun emit-fitness-scores
       (island-id
        generation-best
        historical-best
        population-mean
        population-median
        population-worst
        generation
        &key online-fitness-episodes)
  "Send generation-level and population-level fitness statistics
to the telemetry client."
  (let ((payload
          (prin1-to-string
           `(:type :fitness
             :generation-best
             ,(format nil "~,4F" generation-best)

             :historical-best
             ,(format nil "~,4F" historical-best)

             :population-mean
             ,(format nil "~,4F" population-mean)

             :population-median
             ,(format nil "~,4F" population-median)

             :population-worst
             ,(format nil "~,4F" population-worst)

             :online-fitness-episodes
             ,online-fitness-episodes

             :from
             ,island-id

             :generation
             ,generation

             :ts
             ,(get-universal-time)))))
    (notify-telemetry payload)))

(defun emit-heartbeat ()
  "On a regular interval *heartbeat-interval*, send a heartbeat message
   to the telemetry client and additionally send CPU and memory usage."
  (let* ((ip-address (get-local-ip))
	 (island-id (lookup-island-id-by-ip ip-address))
	 (payload (prin1-to-string
		  `(:type :heartbeat
		    :from ,island-id
		    :ts ,(get-universal-time)
		    :cpu ,(get-cpu-usage)
		    :memory ,(get-memory-usage)))))
    (notify-telemetry payload)))
			  
(defun get-local-ip ()
  "By getting our local IP, we know who we are and who our adjacent neighbours are."
  (let ((socket (usocket:socket-connect "8.8.8.8" 53 :protocol :datagram)))
    (unwind-protect
	 (format nil "~{~A~^.~}" (coerce (usocket:get-local-address socket) 'list))
      (usocket:socket-close socket))))

(defun resolve-island-ip (entry)
  "Return the current IP address represented by an island ENTRY.

For island 0, whose address is stored as :LOCAL, dynamically call
GET-LOCAL-IP every time. Other islands use their fixed configured IP."
  (let ((ip-spec (car entry)))
    (if (eq ip-spec :local)
        (get-local-ip)
        ip-spec)))


(defun lookup-island-id-by-ip (ipaddr)
  "Look up the island ID corresponding to IPADDR.

Fixed island addresses take precedence over the dynamic :LOCAL entry.
If no fixed address matches, island 0 is resolved against the current local
IP so an address change does not break its identity."
  (or (loop for (ip-spec . id) in *islands*
            when (and (stringp ip-spec)
                      (string= ipaddr ip-spec))
              do (return id))
      (let ((local-entry (assoc :local *islands*)))
        (when (and local-entry
                   (string= ipaddr (resolve-island-ip local-entry)))
          (cdr local-entry)))))


(defun lookup-island-ip-by-id (id)
  "Look up the current IP address of island ID.

Island 0 always returns the current value of GET-LOCAL-IP. Other islands
return their fixed configured addresses."
  (let ((entry (rassoc id *islands* :test #'equal)))
    (when entry
      (resolve-island-ip entry))))

(defun emit-error (message)
  "An error has occurred, notify the telemetry client."
  (let* ((ip (get-local-ip))
	 (island-id (lookup-island-id-by-ip ip))
	 (payload (prin1-to-string
		   `(:type :error
		     :from ,island-id
		     :ts ,(get-universal-time)
		     :msg ,message))))
    (notify-telemetry payload)))

(defun emit-message (message)
  "Sends a message to the telemetry client log."
  (let* ((ip (get-local-ip))
	 (island-id (lookup-island-id-by-ip ip))
	 (payload (prin1-to-string
		   `(:type :message
		     :from ,island-id
		     :ts ,(get-universal-time)
		     :msg ,message))))
    (notify-telemetry payload)))

(defun send-migrant-over-socket (island-id root-team)
  "Sends a TEAM to island ISLAND-ID through a TCP socket.
   Notifies the telemetry client that a migrant was sent over UDP."
  (let ((receiver-ip-address (lookup-island-ip-by-id island-id))
	(sender-id (who-am-i))
	(serialized-team (serialize-team root-team)))
    (bt:make-thread
     (lambda ()
       (handler-case
	   (progn
	     (usocket:with-client-socket (socket stream receiver-ip-address 8080 :timeout 30)
	       (prin1 `(:type :migrant
			:from ,sender-id
			:ts ,(get-universal-time)
			:team ,serialized-team)
		      stream)
	       (finish-output stream))
	     ;; Notify the telemetry client over UDP that a migrant was sent.
	     (emit-message (format nil "Migrant was sent to island ~A.~%" island-id)))
	 (error (e)
	   (emit-error (format nil "Failed to send migrant to ~A: ~A~%" island-id e)))))
     :name (format nil "migrant-sender-to~A" island-id))))

(defun receive-migrant-over-socket (msg)
  (when *running*
    (let* ((from-id (getf msg :from))
	   (root-team (deserialize-team (getf msg :team) (make-hash-table :test 'equal)))
	   ;; Visited map ensures we only push each unique team to the buffer once.
	   (visited (make-hash-table :test 'eq)))
      (labels ((process-migrant (tm)
		 (unless (gethash tm visited)
		   (setf (gethash tm visited) t)

		   (if (eq tm root-team)
		       (push-root-team tm)
		       (push-internal-team tm))

		   ;; Recurse through learners to find internal teams
		   (dolist (learner (team-learners tm))
		     (let ((action (action-action (learner-action learner))))
		       (when (team-p action)
			 (process-migrant action)))))))
	(process-migrant root-team)
	(emit-message (format nil "Migrant received from island ~A.~%" from-id))))))

(defun get-neighbour-ids (island-id)
  "Returns the island IDs that this island ID is connected to."
  (cdr (assoc island-id *topology* :test #'equal)))

(defun set-global-parameters (population-size
                              num-observations num-actions
                              init-num-learners max-num-learners
                              p-add p-del p-mut p-act p-swap
                              gap init-program-size max-program-size
                              p-add-instr p-del-instr p-swap-instrs
                              p-mut-constant p-mut-constant-sign
                              migration-interval
                              batch-size
                              online-fitness-episodes
                              &key checkpoint-directory)
  "Set the hyperparameters according to the TCP request."

  (setf *population-size* population-size)
  (setf *num-observations* num-observations)
  (setf *num-actions* num-actions)

  (setf *init-num-learners* init-num-learners)
  (setf *max-num-learners*
        (case max-num-learners
          (:inf +inf+)
          (otherwise max-num-learners)))

  (setf *p-add* p-add)
  (setf *p-del* p-del)
  (setf *p-mut* p-mut)
  (setf *p-act* p-act)
  (setf *p-swap* p-swap)

  (setf *gap* gap)

  (setf *init-program-size* init-program-size)
  (setf *max-program-size*
        (case max-program-size
          (:inf +inf+)
          (otherwise max-program-size)))

  (setf *p-add-instr* p-add-instr)
  (setf *p-del-instr* p-del-instr)
  (setf *p-swap-instrs* p-swap-instrs)
  (setf *p-mut-constant* p-mut-constant)
  (setf *p-mut-constant-sign* p-mut-constant-sign)

  (setf *migration-interval* migration-interval)
  (setf *batch-size* batch-size)

  (setf *online-fitness-episodes*
        online-fitness-episodes)

  (setf *checkpoint-directory* checkpoint-directory))

(defun valid-search-parameters-p (mode gym-environment-name dataset-name
				  num-observations num-actions
				  population-size init-num-learners
				  max-num-learners p-add
				  p-del p-mut p-act p-swap
				  gap init-program-size max-program-size
				  p-add-instr p-del-instr p-swap-instrs
				  p-mut-constant p-mut-constant-sign
				  migration-interval batch-size seed)
  "Returns T if the search parameters are valid. NIL otherwise."
       ;; 1. Check that mode is either :online or :offline
  (and (or (eq mode :online)
	   (eq mode :offline))
       ;; 2. Check that if mode is online then a gym environment is set and a dataset is not provided.
       (case mode
	 (:online (and gym-environment-name
		       (not (eq gym-environment-name :none))
		       (eq dataset-name :none)))
	 (:offline (and dataset-name
			(not (eq dataset-name :none))
			(eq gym-environment-name :none))))
       ;; The semantic CAGE2 bridge requires 52 observations and 11 targets.
       (or (not (and (stringp gym-environment-name)
                     (search "Cage2" gym-environment-name)))
           (and (integerp num-observations)
                (integerp num-actions)
                (= num-observations 52)
                (= num-actions +num-semantic-targets+)))))

(defun who-am-i ()
  "Returns the island ID of the currently running server."
  (let ((ip-address (get-local-ip)))
    (lookup-island-id-by-ip ip-address)))

(defun handle-start-search (msg)
  "Validate a start-search request, configure globals, and begin searching."
  (when *running*
    (emit-error "A search is already running on this node.")
    (return-from handle-start-search))

  (let ((mode (getf msg :mode))
        (gym-environment-name (getf msg :gym-environment-name))
        (checkpoint-directory (getf msg :checkpoint-directory))
        (dataset-name (getf msg :dataset-name))
        (num-observations (getf msg :num-observations))
        (num-actions (getf msg :num-actions))
        (population-size (getf msg :population-size))
        (init-num-learners (getf msg :init-num-learners))
        (max-num-learners (getf msg :max-num-learners))
        (p-add (getf msg :p-add))
        (p-del (getf msg :p-del))
        (p-mut (getf msg :p-mut))
        (p-act (getf msg :p-act))
        (p-swap (getf msg :p-swap))
        (gap (getf msg :gap))
        (init-program-size (getf msg :init-program-size))
        (max-program-size (getf msg :max-program-size))
        (p-add-instr (getf msg :p-add-instr))
        (p-del-instr (getf msg :p-del-instr))
        (p-swap-instrs (getf msg :p-swap-instrs))
        (p-mut-constant (getf msg :p-mut-constant))
        (p-mut-constant-sign (getf msg :p-mut-constant-sign))
        (migration-interval (getf msg :migration-interval))
        (batch-size (getf msg :batch-size))
        (online-fitness-episodes
          (or (getf msg :online-fitness-episodes) 1))
        (seed (getf msg :seed)))

    (format t "~S~%" msg)

    (emit-message
     (format nil
             "PARAM DEBUG: mode=~A env=~A dataset=~A obs=~A actions=~A pop=~A init-learners=~A max-learners=~A gap=~A migration=~A batch=~A online-fit-eps=~A checkpoint-dir=~A seed=~A"
             mode
             gym-environment-name
             dataset-name
             num-observations
             num-actions
             population-size
             init-num-learners
             max-num-learners
             gap
             migration-interval
             batch-size
             online-fitness-episodes
             checkpoint-directory
             seed))

    (emit-message
     (format nil
             "MUTATION PARAM DEBUG: p-add=~A p-del=~A p-mut=~A p-act=~A p-swap=~A init-prog=~A max-prog=~A p-add-instr=~A p-del-instr=~A p-swap-instrs=~A p-mut-constant=~A p-mut-constant-sign=~A"
             p-add
             p-del
             p-mut
             p-act
             p-swap
             init-program-size
             max-program-size
             p-add-instr
             p-del-instr
             p-swap-instrs
             p-mut-constant
             p-mut-constant-sign))

    (if (valid-search-parameters-p
         mode
         gym-environment-name
         dataset-name
         num-observations
         num-actions
         population-size
         init-num-learners
         max-num-learners
         p-add
         p-del
         p-mut
         p-act
         p-swap
         gap
         init-program-size
         max-program-size
         p-add-instr
         p-del-instr
         p-swap-instrs
         p-mut-constant
         p-mut-constant-sign
         migration-interval
         batch-size
         seed)

        (progn
          (set-global-parameters
           population-size
           num-observations
           num-actions
           init-num-learners
           max-num-learners
           p-add
           p-del
           p-mut
           p-act
           p-swap
           gap
           init-program-size
           max-program-size
           p-add-instr
           p-del-instr
           p-swap-instrs
           p-mut-constant
           p-mut-constant-sign
           migration-interval
           batch-size
           online-fitness-episodes
           :checkpoint-directory checkpoint-directory)

          (setf *running* t)

          (push
           (bt:make-thread
            (lambda ()
              (unwind-protect
                   (handler-case
                       (progn
                         (emit-message
                          (format nil
                                  "Search started on island ~A"
                                  (who-am-i)))

                         (when *checkpoint-directory*
                           (emit-message
                            (format nil
                                    "Checkpoint directory: ~A"
                                    *checkpoint-directory*)))

                         (setf lparallel:*kernel*
                               (make-kernel *num-threads*))

                         (run-search
                          mode
                          gym-environment-name
                          dataset-name
                          seed))

                     (error (c)
                       (setf *running* nil)
                       (emit-error
                        (format nil "Search crashed: ~A" c))))

                (setf *running* nil)

                (when lparallel:*kernel*
                  (lparallel:end-kernel))))
            :name "search-thread")
           *server-threads*))

        (emit-error
         "The search parameters provided are invalid."))))

(defun handle-resume-search (msg)
  "Warm-start a search from a saved best-team file."
  (when *running*
    (emit-error "A search is already running on this node.")
    (return-from handle-resume-search))

  (let ((mode (getf msg :mode))
        (gym-environment-name (getf msg :gym-environment-name))
        (dataset-name (getf msg :dataset-name))
        (best-team-path (getf msg :best-team-path))
        (checkpoint-directory (getf msg :checkpoint-directory))
        (num-observations (getf msg :num-observations))
        (num-actions (getf msg :num-actions))
        (population-size (getf msg :population-size))
        (init-num-learners (getf msg :init-num-learners))
        (max-num-learners (getf msg :max-num-learners))
        (p-add (getf msg :p-add))
        (p-del (getf msg :p-del))
        (p-mut (getf msg :p-mut))
        (p-act (getf msg :p-act))
        (p-swap (getf msg :p-swap))
        (gap (getf msg :gap))
        (init-program-size (getf msg :init-program-size))
        (max-program-size (getf msg :max-program-size))
        (p-add-instr (getf msg :p-add-instr))
        (p-del-instr (getf msg :p-del-instr))
        (p-swap-instrs (getf msg :p-swap-instrs))
        (p-mut-constant (getf msg :p-mut-constant))
        (p-mut-constant-sign (getf msg :p-mut-constant-sign))
        (migration-interval (getf msg :migration-interval))
        (batch-size (getf msg :batch-size))
        (online-fitness-episodes
          (or (getf msg :online-fitness-episodes) 1))
        (seed (getf msg :seed)))

    (format t "~S~%" msg)

    (unless best-team-path
      (emit-error "No best-team-path provided for resume-search.")
      (return-from handle-resume-search))

    (unless checkpoint-directory
      (setf checkpoint-directory
            (namestring
             (make-pathname
              :directory
              (pathname-directory
               (pathname best-team-path))))))

    (if (valid-search-parameters-p
         mode
         gym-environment-name
         dataset-name
         num-observations
         num-actions
         population-size
         init-num-learners
         max-num-learners
         p-add
         p-del
         p-mut
         p-act
         p-swap
         gap
         init-program-size
         max-program-size
         p-add-instr
         p-del-instr
         p-swap-instrs
         p-mut-constant
         p-mut-constant-sign
         migration-interval
         batch-size
         seed)

        (progn
          (set-global-parameters
           population-size
           num-observations
           num-actions
           init-num-learners
           max-num-learners
           p-add
           p-del
           p-mut
           p-act
           p-swap
           gap
           init-program-size
           max-program-size
           p-add-instr
           p-del-instr
           p-swap-instrs
           p-mut-constant
           p-mut-constant-sign
           migration-interval
           batch-size
           online-fitness-episodes
           :checkpoint-directory checkpoint-directory)

          (setf *running* t)

          (push
           (bt:make-thread
            (lambda ()
              (unwind-protect
                   (handler-case
                       (progn
                         (emit-message
                          (format nil
                                  "Warm-start resume started on island ~A from best team: ~A"
                                  (who-am-i)
                                  best-team-path))

                         (emit-message
                          (format nil
                                  "Checkpoint directory: ~A"
                                  *checkpoint-directory*))

                         (setf lparallel:*kernel*
                               (make-kernel *num-threads*))

                         (run-search-from-best-team
                          mode
                          gym-environment-name
                          dataset-name
                          seed
                          best-team-path))

                     (error (c)
                       (setf *running* nil)
                       (emit-error
                        (format nil
                                "Warm-start resume crashed: ~A"
                                c))))

                (setf *running* nil)

                (when lparallel:*kernel*
                  (lparallel:end-kernel))))
            :name "warm-start-resume-thread")
           *server-threads*))

        (emit-error
         "The resume-search parameters provided are invalid."))))

(defun handle-stop-search ()
  "When a request is received to stop a running search, set *running* to NIL."
  (unless *running*
    (emit-error "There is no search currently running on this node to stop.")
    (return-from handle-stop-search))
  (emit-message (format nil "Search stopped on island ~A~%" (who-am-i)))
  (setf *running* nil))
				   
(defun start-server ()
  "Start the server for this island."
  (when *server-running*
    (format t "Server is already running.~%")
    (return-from start-server))
  (setf *server-running* t)
  (setf *server-threads* nil)
  (let* ((ip-address (get-local-ip))
	 (island-id (lookup-island-id-by-ip ip-address))
	 (neighbour-ids (get-neighbour-ids island-id)))
    (format t "Server started on ~A:8080.~%" ip-address)
    (format t "This is island ~A.~%" island-id)
    (when neighbour-ids
      (format t "My neighbours are: ~{~A~^, ~}~%" neighbour-ids) 
      (format t "Their IPs are: ~{~A~^, ~}~%" (mapcar #'lookup-island-ip-by-id neighbour-ids)))

    ;; Start the heartbeat thread over UDP
    (push (bt:make-thread
	   (lambda ()
	     (loop
	       do (emit-heartbeat)
	       do (sleep *heartbeat-interval*)))
	   :name "heartbeat")
	  *server-threads*)
    
    ;; Start listening for commands over TCP
    (push (bt:make-thread
	   (lambda ()
	     (usocket:with-server-socket (server (usocket:socket-listen "0.0.0.0" 8080))
	       (loop
		 (let ((client-socket (usocket:socket-accept server)))
		   (bt:make-thread
		    (lambda ()
		      (usocket:with-connected-socket (client client-socket)
			(let* ((stream (usocket:socket-stream client))
			       (msg (read stream nil :eof)))
			  (unless (eq msg :eof)
			    ;; Dispatch according to the request received
			    (ecase (getf msg :type)
			      (:migrant (receive-migrant-over-socket msg))
            (:validate-best-team (handle-validate-best-team msg))
 
			      (:start-search (handle-start-search msg))
				  (:resume-search (handle-resume-search msg))
			      (:stop-search (handle-stop-search)))))))
		    :name (format nil "search-handler-~A" (get-universal-time)))))))
	   :name "tcp-listener")
	  *server-threads*)))

(defun stop-server ()
  "Shut down the server gracefully."
  (setf *server-running* nil)
  (setf *running* nil)

  ;; Close the TCP listener
  (when *server-socket*
    (ignore-errors (usocket:socket-close *server-socket*))
    (setf *server-socket* nil))

  ;; Give threads a moment to notice then close threads.
  (sleep 1)
  (dolist (thread *server-threads*)
    (when (bt:thread-alive-p thread)
      (bt:destroy-thread thread)))

  (setf *server-threads* nil)
  (format t "Server stopped.~%"))
  


(defun handle-validate-best-team (msg)
  "Run validation for a saved best team."
  (when *running*
    (emit-error "Cannot validate while a search is running on this node.")
    (return-from handle-validate-best-team))

  (let ((best-team-path (getf msg :best-team-path))
        (environment (getf msg :environment))
        (mode (getf msg :validation-mode))
        (red-agent-name (getf msg :red-agent-name))
        (episodes (getf msg :episodes)))

    (unless best-team-path
      (emit-error "No best-team-path provided for validation.")
      (return-from handle-validate-best-team))

    (setf *running* t)

    (push
     (bt:make-thread
      (lambda ()
        (unwind-protect
             (handler-case
                 (validate-best-team best-team-path
                                     environment
                                     mode
                                     :red-agent-name red-agent-name
                                     :episodes episodes)
               (error (c)
                 (emit-error
                  (format nil "Validation crashed: ~A" c))))
          (setf *running* nil)))
      :name "validation-thread")
     *server-threads*)))
