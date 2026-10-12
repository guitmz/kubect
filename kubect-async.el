;;; kubect-async.el --- Nonblocking read only reports -*- lexical-binding: t; -*-

(require 'cl-lib)
(defcustom kubect-async-reports t
  "Fetch interactive reports without blocking Emacs."
  :type 'boolean :group 'kubect)
(defcustom kubect-request-timeout 30
  "Timeout in seconds for each asynchronous report request."
  :type 'natnum :group 'kubect)
(defvar kubect--async-running nil)
(defvar-local kubect--async-job nil)
(defvar-local kubect--last-refresh-request nil)

(defun kubect--async-scope ()
  "Return the authoritative scope for the buffer starting an async job.
Session buffers carry their scope in `kubect-session'.  Reading it directly
avoids falling back to project state while an asynchronous refresh is queued."
  (cond
   ((and (derived-mode-p 'kubect-session-mode) kubect-session)
    (list :context (kubect-session-context kubect-session)
          :namespace (kubect-session-namespace kubect-session)
          :resource (kubect-session-resource kubect-session)))
   ((and (derived-mode-p 'kubect-report-mode) kubect-report-state)
    (list :context (plist-get kubect-report-state :context)
          :namespace (plist-get kubect-report-state :namespace)
          :resource (kubect-current-resource)))
   (t
    (list :context (kubect-current-context)
          :namespace (kubect-current-namespace)
          :resource (kubect-current-resource)))))

(defun kubect--async-action-label (function)
  "Return a concise, human-readable label for asynchronous FUNCTION."
  (if (symbolp function)
      (replace-regexp-in-string "-" " "
                                (string-remove-prefix "kubect-" (symbol-name function)))
    "refresh"))

(defun kubect--async-header (header action &optional state)
  "Add ACTION and optional STATE to HEADER without accumulating status text."
  (format "%s | %s%s"
          (replace-regexp-in-string
           " | \\(?:Updated [0-9:]+\\|last=[^|]+\\)\\(?: | \\(?:Updated [0-9:]+\\|last=[^|]+\\)\\)*\\'"
           "" (or header ""))
          (or state (format "Updated %s" (format-time-string "%H:%M:%S")))
          (format " | last=%s" action)))

(defun kubect-show-refresh-error ()
  "Show the complete error from the most recent refresh failure."
  (interactive)
  (unless kubect--last-refresh-error
    (user-error "This buffer has no refresh error"))
  (let ((error-text kubect--last-refresh-error)
        (buffer (get-buffer-create "*kubect refresh error*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert error-text "\n")
        (goto-char (point-min)))
      (special-mode)
      (setq-local header-line-format "Kubect refresh error | q quit"))
    (kubect--display-buffer buffer)))

(defun kubect--async-fail (buffer error)
  "Record ERROR in BUFFER while preserving any last successful output."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq kubect--async-job nil
            kubect--last-refresh-error error)
      (setq header-line-format
            (format "%s%s failed: %s | last=%s | C-c C-e details"
                    (if (> (buffer-size) 0) "Stale | " "")
                    (or kubect--last-action "Refresh")
                    (truncate-string-to-width error 160 nil nil t)
                    (or kubect--last-action "refresh"))))))

(defun kubect-cancel-refresh ()
  "Cancel the current report fetch."
  (interactive)
  (when kubect--async-job
    (setf (plist-get kubect--async-job :cancelled) t)
    (when-let* ((timer (plist-get kubect--async-job :timer)))
      (cancel-timer timer))
    (when-let* ((process (plist-get kubect--async-job :process)))
      (when (process-live-p process) (delete-process process)))
    (setq kubect--async-job nil)
    (setq header-line-format
          (format "%s cancelled | last=%s"
                  (or kubect--last-action "Refresh")
                  (or kubect--last-action "refresh")))))

(defun kubect--async-fetch (job request)
  "Fetch REQUEST for JOB, cleaning up processes, buffers, and timers."
  (let ((out (generate-new-buffer " *kubect response*"))
        (errors (generate-new-buffer " *kubect stderr*")))
    (when-let* ((target (plist-get job :target))
                ((buffer-live-p target)))
      (with-current-buffer target
        (setq kubect--last-refresh-request request)))
    (condition-case err
        (let ((process
               (make-process
                :name "kubect-fetch" :buffer out :stderr errors
                :noquery t :connection-type 'pipe
                :command (append (list (kubect--ensure-kubectl)
                                       (format "--request-timeout=%ss" kubect-request-timeout))
                                 request)
                :sentinel
                (lambda (process _event)
                  (when (memq (process-status process) '(exit signal))
                    (when-let* ((timer (plist-get job :timer))) (cancel-timer timer))
                    (unwind-protect
                        (unless (plist-get job :cancelled)
                          (puthash request
                                   (if (= (process-exit-status process) 0)
                                       (cons t (with-current-buffer out
                                                 (string-trim (buffer-string))))
                                     (cons 'error
                                           (format "kubectl exited %s: %s\nCommand: kubectl %s"
                                                   (process-exit-status process)
                                                   (with-current-buffer errors
                                                     (string-trim (buffer-string)))
                                                   (mapconcat #'shell-quote-argument request " "))))
                                   (plist-get job :cache))
                          (kubect--async-step job))
                      (kill-buffer out) (kill-buffer errors)))))))
          (setf (plist-get job :process) process
                (plist-get job :timer)
                (run-at-time
                 kubect-request-timeout nil
                 (lambda ()
                   (when (process-live-p process)
                     (with-current-buffer errors (insert "Request timed out"))
                     (delete-process process))))))
      (error
       (kill-buffer out) (kill-buffer errors)
       (signal (car err) (cdr err))))))

(defun kubect--async-step (job)
  "Continue read only JOB using cached responses.
Replay the report builder until its next uncached request.  Builders must
only fetch data before rendering; each request runs exactly once per job."
  (let ((origin (plist-get job :origin))
        (target (plist-get job :target)))
    (when (and (buffer-live-p origin)
               (not (plist-get job :cancelled)))
      (with-current-buffer origin
        (unless (= (buffer-chars-modified-tick) (plist-get job :tick))
          (kubect-cancel-refresh))))
    (when (and (buffer-live-p origin) (buffer-live-p target)
               (not (plist-get job :cancelled)))
      (condition-case err
          (let ((request
                 (catch 'kubect-request
                   (with-current-buffer origin
                     (save-excursion
                       (goto-char (min (plist-get job :point) (point-max)))
                       (let ((kubect--async-running t)
                             (display (symbol-function 'kubect--display-buffer))
                             (complete (symbol-function 'kubect--completing-read)))
                         (cl-letf (((symbol-function 'kubect--kubectl-output)
                                    (lambda (&rest args)
                                      (let ((cached (gethash args (plist-get job :cache))))
                                        (cond ((eq (car cached) 'error)
                                               (error "%s" (cdr cached)))
                                              (cached (cdr cached))
                                              (t (throw 'kubect-request args))))))
                                   ((symbol-function 'kubect--record-session-command)
                                    (lambda (&rest args)
                                      (cl-pushnew args (plist-get job :history) :test #'equal)))
                                   ((symbol-function 'kubect--completing-read)
                                    (lambda (&rest args)
                                      (let* ((key (cons 'completion args))
                                             (cached (gethash key (plist-get job :cache))))
                                        (if cached (cdr cached)
                                          (let ((answer (apply complete args)))
                                            (puthash key (cons t answer) (plist-get job :cache))
                                            answer)))))
                                   ((symbol-function 'kubect--display-buffer)
                                    (lambda (buffer)
                                      (setf (plist-get job :result) buffer)
                                      (funcall display buffer)))
                                   ((symbol-function 'kubect-current-context)
                                    (lambda () (plist-get job :context)))
                                   ((symbol-function 'kubect-current-namespace)
                                    (lambda () (plist-get job :namespace)))
                                   ((symbol-function 'kubect-current-resource)
                                    (lambda () (plist-get job :resource))))
                           (apply (plist-get job :function) (plist-get job :args)))))
                     nil))))
            (if request
                (kubect--async-fetch job request)
              (with-current-buffer target
                (setq kubect--async-job nil)
                (setq kubect--last-refresh-error nil)
                (setq kubect--last-action (plist-get job :action))
                (dolist (entry (reverse (plist-get job :history)))
                  (apply #'kubect--record-session-command entry))
                (when (and (plist-get job :result)
                           (not (eq target (plist-get job :result))))
                  (setq header-line-format (plist-get job :old-header))))
              (with-current-buffer (or (plist-get job :result) target)
                (setq kubect--last-action (plist-get job :action))
                (setq header-line-format
                      (kubect--async-header header-line-format
                                             (plist-get job :action))))))
        (quit
         (with-current-buffer target (kubect-cancel-refresh))
         (signal 'quit nil))
        (error
         (kubect--async-fail target (error-message-string err)))))))

(defun kubect--async-command (function &rest args)
  "Run read only FUNCTION with ARGS asynchronously when interactive."
  (if (or noninteractive kubect--async-running (not kubect-async-reports))
      (apply function args)
    ;; A deliberate command wins over an older refresh.  Timer-driven refreshes
    ;; remain non-disruptive by leaving an active request alone.
    (when (and kubect--async-job (called-interactively-p 'interactive))
      (kubect-cancel-refresh))
    (unless kubect--async-job
      (let* ((origin (current-buffer))
             (action (kubect--async-action-label function))
             (scope (kubect--async-scope))
             (job (list :origin origin :target origin :point (point)
                        :process nil :timer nil :result nil :cancelled nil :history nil
                        :tick (buffer-chars-modified-tick)
                        :context (plist-get scope :context)
                        :namespace (plist-get scope :namespace)
                        :resource (plist-get scope :resource)
                        :function function :args args :action action :old-header header-line-format
                        :cache (make-hash-table :test #'equal))))
        (setq kubect--async-job job)
        (add-hook 'kill-buffer-hook #'kubect-cancel-refresh nil t)
        (setq header-line-format
              (format "Loading %s... %s | C-c C-k cancels"
                      action
                      (kubect--scope-summary (plist-get scope :context)
                                              (plist-get scope :namespace)
                                              (plist-get scope :resource))))
        (kubect--async-step job)))))

(dolist (command '(kubect-home kubect-xray kubect-timeline
                   kubect-timeline-for-resource kubect-top-nodes kubect-top-pods
                   kubect-cost-signals kubect-policy-guardrails
                   kubect-network-explorer kubect-rollout-watch
                   kubect-describe-resource kubect-describe-resource-at-point
                   kubect-report-refresh kubect-output-refresh kubect-node-pods
                   kubect-refresh))
  (advice-add command :around #'kubect--async-command))
(dolist (map (list kubect-session-mode-map kubect-report-mode-map kubect-output-mode-map))
  (define-key map (kbd "C-c C-k") #'kubect-cancel-refresh)
  (define-key map (kbd "C-c C-e") #'kubect-show-refresh-error))
(defun kubect--stop-buffer-work ()
  "Release pending requests and watch timers owned by this buffer."
  (kubect-cancel-refresh)
  (when (derived-mode-p 'kubect-session-mode) (kubect-stop-watch))
  (when (timerp kubect--report-watch-timer)
    (cancel-timer kubect--report-watch-timer)
    (setq kubect--report-watch-timer nil)))

(defun kubect--install-cleanup-hooks ()
  "Install buffer-local cleanup for destruction and mode reinitialization."
  (add-hook 'kill-buffer-hook #'kubect--stop-buffer-work nil t)
  (add-hook 'change-major-mode-hook #'kubect--stop-buffer-work nil t))

(dolist (hook '(kubect-session-mode-hook kubect-report-mode-hook kubect-output-mode-hook))
  (add-hook hook #'kubect--install-cleanup-hooks))

(defun kubect-quit-report ()
  "Cancel fetching and stop watching before dismissing this buffer."
  (interactive)
  (kubect--stop-buffer-work)
  (quit-window))
(define-key kubect-report-mode-map (kbd "q") #'kubect-quit-report)
(define-key kubect-output-mode-map (kbd "q") #'kubect-quit-report)
(define-key kubect-session-mode-map (kbd "q") #'kubect-quit-report)
(define-key kubect-report-mode-map (kbd "RET") #'kubect-report-visit)

(provide 'kubect-async)
;;; kubect-async.el ends here
