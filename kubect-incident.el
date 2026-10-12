;;; kubect-incident.el --- Kubect incident -*- lexical-binding: t; -*-

(require 'kubect-core)

(defun kubect-incident-top-resource (&optional arg)
  "Show the most useful top view for the current incident row."
  (interactive "P")
  (kubect-top-resource arg))

(defun kubect-incident-events-for-resource (&optional arg)
  "Open the most useful events view for the current incident row.
Unhealthy rows prefer events scoped to the resolved pod."
  (interactive "P")
  (if (and (derived-mode-p 'kubect-session-mode)
           (kubect--restart-trouble-line-p (kubect--current-session-line)))
      (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                    (kubect--current-line-resource-plist))
                   (pod (or (kubect--pod-for-resource kind name context namespace)
                            (and (member kind '("pod" "pods")) name)
                            (kubect--read-pod context namespace))))
        (kubect--record-session-command "incident-events" (format "pod/%s" pod))
        (kubect--events-for-resource "pod" pod context namespace arg))
    (kubect-events-for-resource arg)))

(defun kubect-incident-watch-events-for-resource (&optional arg)
  "Open the most useful live event watch for the current incident row."
  (interactive "P")
  (if (and (derived-mode-p 'kubect-session-mode)
           (kubect--restart-trouble-line-p (kubect--current-session-line)))
      (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                    (kubect--current-line-resource-plist))
                   (pod (or (kubect--pod-for-resource kind name context namespace)
                            (and (member kind '("pod" "pods")) name)
                            (kubect--read-pod context namespace)))
                   (selector (kubect--event-field-selector "pod" pod)))
        (kubect--record-session-command "incident-watch-events" (format "pod/%s" pod))
        (let ((kubect--display-buffer-action-override
               (kubect--display-action-from-prefix arg)))
          (kubect--start-stream
           (format "events watch %s" pod)
           (append (kubect--kubectl-base-args context namespace)
                   (list "get" "events" "--watch"
                         (format "--field-selector=%s" selector)))
           context namespace
           (list :mode 'events-watch
                 :context context
                 :namespace namespace
                 :kind "pod"
                 :name pod))))
    (kubect-watch-events-for-resource arg)))

(defun kubect--restart-window-log-sections (pod container context namespace)
  "Return restart-window log sections for POD."
  (let* ((status (kubect--pod-container-status pod container context namespace))
         (last-terminated (alist-get 'terminated (alist-get 'lastState status)))
         (running-state (alist-get 'running (alist-get 'state status)))
         (timestamp (or (alist-get 'finishedAt last-terminated)
                        (alist-get 'startedAt running-state)))
         (since-time (and timestamp
                          (kubect--rfc3339-minus-seconds
                           timestamp kubect-restart-log-padding-seconds)))
         (current-lines
          (apply #'kubect--kubectl-output
                 (append (kubect--kubectl-base-args context namespace)
                         (list "logs" (format "--tail=%d" kubect-default-log-tail) pod)
                         (when since-time
                           (list (format "--since-time=%s" since-time)))
                         (when container
                           (list "-c" container)))))
         (previous-lines
          (when last-terminated
            (apply #'kubect--kubectl-output
                   (append (kubect--kubectl-base-args context namespace)
                           (list "logs" "--previous=true" (format "--tail=%d" kubect-default-log-tail) pod)
                           (when since-time
                             (list (format "--since-time=%s" since-time)))
                           (when container
                             (list "-c" container)))))))
    (list :since-time since-time
          :anchor "container restart"
          :previous previous-lines
          :current current-lines)))

(defun kubect--restart-window-log-data (pod container context namespace options)
  "Return restart-window log data for POD using OPTIONS."
  (if-let* ((explicit-since-time (plist-get options :since-time)))
      (let ((current-lines
             (apply #'kubect--kubectl-output
                    (append (kubect--kubectl-base-args context namespace)
                            (list "logs" (format "--tail=%d" kubect-default-log-tail) pod
                                  (format "--since-time=%s" explicit-since-time))
                            (when container
                              (list "-c" container)))))
            (previous-lines
             (apply #'kubect--kubectl-output
                    (append (kubect--kubectl-base-args context namespace)
                            (list "logs" "--previous=true" (format "--tail=%d" kubect-default-log-tail)
                                  pod (format "--since-time=%s" explicit-since-time))
                            (when container
                              (list "-c" container))))))
        (list :since-time explicit-since-time
              :anchor "rollout window"
              :previous previous-lines
              :current current-lines))
    (kubect--restart-window-log-sections pod container context namespace)))

(defun kubect--restart-window-log-output (pod container context namespace options)
  "Return restart-window log output for POD."
  (let* ((sections (kubect--restart-window-log-data pod container context namespace options))
         (since-time (plist-get sections :since-time))
         (anchor (plist-get sections :anchor))
         (previous-lines (plist-get sections :previous))
         (current-lines (plist-get sections :current)))
    (concat
     (if since-time
         (format "Window starts at %s (%s)\n\n" since-time anchor)
       "No restart timestamp found; falling back to current logs.\n\n")
     (when previous-lines
       (concat "== Previous container ==\n\n"
               previous-lines
               "\n\n"))
     "== Current container ==\n\n"
     current-lines)))

(defun kubect-incident-describe-resource (&optional arg)
  "Open an incident-focused describe buffer for the current row.
Unhealthy rows prefer a pod-centered report with recent events first."
  (interactive "P")
  (if (and (derived-mode-p 'kubect-session-mode)
           (kubect--restart-trouble-line-p (kubect--current-session-line)))
      (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                    (kubect--current-line-resource-plist))
                   (pod (or (kubect--pod-for-resource kind name context namespace)
                            (and (member kind '("pod" "pods")) name)
                            (kubect--read-pod context namespace)))
                   (pod-resource (list :kind "pod"
                                       :name pod
                                       :context context
                                       :namespace namespace))
                   (events (kubect--event-summary-lines-for-resource pod-resource))
                   (describe-output
                    (kubect--kubectl-output
                     "--context" context
                     "--namespace" namespace
                     "describe" "pod" pod)))
        (kubect--record-session-command "incident-describe" (format "pod/%s" pod))
        (kubect--show-report-buffer
         (format "incident describe %s" pod)
         (concat
          (format "== pod/%s ==\n\n" pod)
          "== Recent events ==\n\n"
          (if events
              (concat (string-join events "\n") "\n\n")
            "No events\n\n")
          "== Describe pod ==\n\n"
          describe-output
          "\n")
         context namespace arg))
    (kubect-describe-resource arg)))

(defun kubect-incident-logs-resource (&optional arg)
  "Open the most useful logs for the current incident row.
Restart-looking rows prefer previous logs automatically."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist))
               (pod (or (kubect--pod-for-resource kind name context namespace)
                        (kubect--read-pod context namespace)))
               (container (kubect--select-container-for-pod pod context namespace t)))
    (if (and (derived-mode-p 'kubect-session-mode)
             (kubect--restart-trouble-line-p (kubect--current-session-line)))
        (kubect-logs-previous pod container context namespace
                              (kubect--display-action-from-prefix arg))
      (kubect-logs pod container context namespace
                   (kubect--display-action-from-prefix arg)))))

(defun kubect-debug-restarts-resource (&optional arg)
  "Open restart-oriented debugging buffers for the current resource.
This opens `describe` and previous logs for a resolved pod."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist))
               (pod (or (kubect--pod-for-resource kind name context namespace)
                        (kubect--read-pod context namespace)))
               (container (kubect--read-container pod context namespace)))
    (kubect--record-session-command "debug-restarts" pod)
    (kubect--show-describe-resource "pod" pod context namespace arg)
    (kubect-logs-previous pod container context namespace
                          (kubect--display-action-from-prefix arg))))

(defun kubect-incident-debug-restarts-resource (&optional arg)
  "Open a consolidated restart triage report for the current incident row.
Healthy rows fall back to `kubect-debug-restarts-resource'."
  (interactive "P")
  (if (and (derived-mode-p 'kubect-session-mode)
           (kubect--restart-trouble-line-p (kubect--current-session-line)))
      (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                    (kubect--current-line-resource-plist))
                   (pod (or (kubect--pod-for-resource kind name context namespace)
                            (and (member kind '("pod" "pods")) name)
                            (kubect--read-pod context namespace)))
                   (resource-options (kubect--effective-log-snapshot-options
                                      (list :kind kind :name name :context context :namespace namespace)
                                      '(:restart-window t)))
                   (container (kubect--select-container-for-pod pod context namespace t))
                   (restart-data (kubect--restart-window-log-data
                                  pod container context namespace resource-options))
                   (pod-resource (list :kind "pod"
                                       :name pod
                                       :context context
                                       :namespace namespace))
                   (events (kubect--event-summary-lines-for-resource pod-resource))
                   (describe-output
                   (kubect--kubectl-output
                     "--context" context
                     "--namespace" namespace
                     "describe" "pod" pod))
                   (restart-window-logs
                    (kubect--bulk-log-snapshot-output
                     pod container context namespace resource-options))
                   (window-header
                    (if-let* ((since-time (plist-get restart-data :since-time)))
                        (format "Restart triage: %s/%s window=%s (%s)"
                                context namespace since-time
                                (plist-get restart-data :anchor))
                      (format "Restart triage: %s/%s window=live fallback"
                              context namespace))))
        (kubect--record-session-command
         "incident-debug-restarts"
         (if container
             (format "%s/%s" pod container)
           pod))
        (kubect--show-report-buffer
         (format "incident restart triage %s" pod)
         (concat
          (format "== pod/%s%s ==\n\n"
                  pod
                  (if container (format " container=%s" container) ""))
          "== Recent events ==\n\n"
          (if events
              (concat (string-join events "\n") "\n\n")
            "No events\n\n")
          "== Describe pod ==\n\n"
          describe-output
          "\n\n== Restart window logs ==\n\n"
          restart-window-logs
          "\n")
         context namespace arg window-header))
    (kubect-debug-restarts-resource arg)))

(defun kubect-incident-rollout-history-resource (&optional arg)
  "Open a rollout-focused incident report for the deployment at point."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist)))
    (unless (member kind '("deployment" "deployments"))
      (user-error "Incident rollout history is only available for deployments"))
    (let* ((pod (or (kubect--pod-for-resource kind name context namespace)
                    (kubect--read-pod context namespace)))
           (container (kubect--select-container-for-pod pod context namespace t))
           (resource-options (kubect--effective-log-snapshot-options
                              (list :kind kind :name name :context context :namespace namespace)
                              '(:restart-window t)))
           (restart-data (kubect--restart-window-log-data
                          pod container context namespace resource-options))
           (events (kubect--event-summary-lines-for-resource
                    (list :kind kind :name name :context context :namespace namespace)))
           (history-output
            (kubect--kubectl-output
             "--context" context
             "--namespace" namespace
             "rollout" "history" (format "deployment/%s" name)))
           (log-output
            (kubect--bulk-log-snapshot-output
             pod container context namespace resource-options))
           (window-header
            (if-let* ((since-time (plist-get restart-data :since-time)))
                (format "Rollout triage: %s/%s window=%s (%s)"
                        context namespace since-time
                        (plist-get restart-data :anchor))
              (format "Rollout triage: %s/%s window=live fallback"
                      context namespace))))
      (kubect--record-session-command
       "incident-rollout-history"
       (if container
           (format "%s via %s/%s" name pod container)
         (format "%s via %s" name pod)))
      (kubect--show-report-buffer
       (format "incident rollout %s" name)
       (concat
        (format "== deployment/%s ==\n\n" name)
        "== Recent deployment events ==\n\n"
        (if events
            (concat (string-join events "\n") "\n\n")
          "No events\n\n")
        "== Rollout history ==\n\n"
        history-output
        "\n\n== Rollout window logs ==\n\n"
        (if container
            (format "Pod %s, container %s\n\n%s\n" pod container log-output)
          (format "Pod %s\n\n%s\n" pod log-output)))
       context namespace arg window-header))))

(provide 'kubect-incident)
;;; kubect-incident.el ends here
