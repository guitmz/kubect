;;; kubect-logs.el --- Kubect logs -*- lexical-binding: t; -*-

(require 'kubect-core)

(defun kubect--stream-filter (proc output)
  "Insert kubectl OUTPUT for PROC."
  (when-let* ((buffer (process-buffer proc)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (moving (= (point) (point-max))))
          (save-excursion
            (goto-char (point-max))
            (insert (ansi-color-apply output)))
          (when moving
            (goto-char (point-max))))))))

(defun kubect--stream-sentinel (proc event)
  "Append process EVENT for PROC."
  (when-let* ((buffer (process-buffer proc)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (format "\n[%s] %s" (process-name proc) (string-trim event))))))))

(defun kubect--stream-header ()
  "Return a header line for the current stream buffer, when useful."
  (when kubect-stream-state
    (let* ((timestamps (plist-get kubect-stream-state :timestamps))
           (preset (plist-get kubect-stream-state :last-filter-preset))
           (parts
            (delq nil
                  (list
                   (when (eq (plist-get kubect-stream-state :mode) 'logs)
                     (format "logs timestamps=%s" (if timestamps "on" "off")))
                   (when preset
                     (format "preset=%s" preset))
                   "o occur"
                   "F preset search"
                   "q stop"
                   (when (eq (plist-get kubect-stream-state :mode) 'logs)
                     "t toggle timestamps")))))
      (string-join parts "  |  "))))

(defun kubect-quit-stream ()
  "Stop the current stream before dismissing its window."
  (interactive)
  (when-let* ((process (get-buffer-process (current-buffer))))
    (set-process-sentinel process #'ignore)
    (delete-process process))
  (quit-window))

(defun kubect--logs-args (pod container context namespace previous all-containers timestamps &optional selector)
  "Return kubectl log ARGS for POD or SELECTOR using the given options."
  (append (kubect--kubectl-base-args context namespace)
          (list "logs" "-f" (format "--tail=%d" kubect-default-log-tail))
          (if selector
              (list "-l" selector "--prefix=true"
                    (format "--max-log-requests=%d" kubect-max-log-requests))
            (list pod))
          (when previous
            (list "--previous=true"))
          (when all-containers
            (list "--all-containers=true"))
          (when timestamps
            (list "--timestamps=true"))
          (when (and container (not all-containers) (not selector))
            (list "-c" container))))

(defun kubect--restart-stream ()
  "Restart the current kubect stream buffer from `kubect-stream-state'."
  (interactive)
  (unless kubect-stream-state
    (user-error "Current buffer is not a kubect stream"))
  (let* ((state kubect-stream-state)
         (process (get-buffer-process (current-buffer)))
         (args (pcase (plist-get state :mode)
                 ('logs
                 (kubect--logs-args
                   (plist-get state :pod)
                   (plist-get state :container)
                   (plist-get state :context)
                   (plist-get state :namespace)
                   (plist-get state :previous)
                   (plist-get state :all-containers)
                   (plist-get state :timestamps)
                   (plist-get state :selector)))
                 (_ (plist-get state :args)))))
    (when process
      (delete-process process))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "$ %s\n\n" (kubect--shell-command args))))
    (setq-local header-line-format (kubect--stream-header))
    (make-process
     :name (buffer-name)
     :buffer (current-buffer)
     :command (cons (kubect--ensure-kubectl) args)
     :filter #'kubect--stream-filter
     :sentinel #'kubect--stream-sentinel)))

(defun kubect-stream-toggle-timestamps ()
  "Toggle timestamps in the current log stream buffer."
  (interactive)
  (unless (and kubect-stream-state
               (eq (plist-get kubect-stream-state :mode) 'logs))
    (user-error "Timestamps are only available for log streams"))
  (setf (plist-get kubect-stream-state :timestamps)
        (not (plist-get kubect-stream-state :timestamps)))
  (kubect--restart-stream)
  (message "Kubect log timestamps %s"
           (if (plist-get kubect-stream-state :timestamps) "enabled" "disabled")))

(defun kubect-stream-occur-preset ()
  "Run `occur' with a named preset regexp in the current stream buffer."
  (interactive)
  (unless kubect-log-filter-presets
    (user-error "No kubect log filter presets are configured"))
  (let* ((names (mapcar #'car kubect-log-filter-presets))
         (preset (kubect--completing-read "Log preset: " names))
         (regexp (alist-get preset kubect-log-filter-presets nil nil #'equal)))
    (setf (plist-get kubect-stream-state :last-filter-preset) preset)
    (setq-local header-line-format (kubect--stream-header))
    (occur regexp)))

(defun kubect--start-stream (name args &optional context namespace state)
  "Start a kubectl stream called NAME with ARGS in CONTEXT and NAMESPACE.
STATE stores optional stream metadata such as log timestamps."
  (let* ((buffer-name (kubect--compilation-buffer-name name context namespace))
         (buffer (get-buffer-create buffer-name))
         (command (cons (kubect--ensure-kubectl) args)))
    (with-current-buffer buffer
      (when-let* ((old (get-buffer-process buffer)))
        (set-process-sentinel old #'ignore)
        (delete-process old))
      (kubect-stream-mode)
      (setq-local kubect-stream-state state)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "$ %s\n\n" (kubect--shell-command args))))
      (setq-local header-line-format (kubect--stream-header)))
    (make-process
     :name buffer-name
     :buffer buffer
     :command command
     :filter #'kubect--stream-filter
     :sentinel #'kubect--stream-sentinel)
    (kubect--display-buffer buffer)))

(defun kubect--effective-log-snapshot-options (resource options)
  "Return OPTIONS adjusted for RESOURCE."
  (if (or (plist-get options :restart-window)
          (plist-get options :since-rollout))
      (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace) resource)
                   (since-time (kubect--resource-rollout-since-time kind name context namespace)))
        (if since-time
            (plist-put (copy-sequence options) :since-time since-time)
          options))
    options))

(defun kubect--bulk-log-snapshot-output (pod container context namespace options)
  "Return snapshot log output for POD using OPTIONS."
  (let ((output
         (if (plist-get options :restart-window)
             (kubect--restart-window-log-output pod container context namespace options)
           (apply #'kubect--kubectl-output
                  (append (kubect--kubectl-base-args context namespace)
                          (list "logs" (format "--tail=%d" kubect-default-log-tail) pod)
                          (when-let* ((since (plist-get options :since)))
                            (list (format "--since=%s" since)))
                          (when (plist-get options :previous)
                            (list "--previous=true"))
                          (when (plist-get options :all-containers)
                            (list "--all-containers=true"))
                          (when-let* ((since-time (plist-get options :since-time)))
                            (list (format "--since-time=%s" since-time)))
                          (when (and container (not (plist-get options :all-containers)))
                            (list "-c" container)))))))
    (if-let* ((regexp (plist-get options :regexp)))
        (let ((lines (cl-remove-if-not
                      (lambda (line)
                        (string-match-p regexp line))
                      (split-string output "\n" t))))
          (if lines
              (string-join lines "\n")
            "No matching log lines"))
      output)))

(defun kubect--show-bulk-log-snapshot (resources &optional arg options)
  "Show a consolidated recent log snapshot for RESOURCES.
OPTIONS is a plist accepted by `kubect--bulk-log-snapshot-output'."
  (let* ((first (car resources))
         (context (plist-get first :context))
         (namespace (plist-get first :namespace))
         (title (or (plist-get options :title) "bulk log snapshot"))
         (buffer (get-buffer-create
                  (kubect--compilation-buffer-name title context namespace))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (resource resources)
          (pcase-let* ((`(:kind ,kind :name ,name :context ,resource-context :namespace ,resource-namespace) resource)
                       (pod (or (kubect--pod-for-resource kind name resource-context resource-namespace)
                                (kubect--read-pod resource-context resource-namespace)))
                       (resource-options (kubect--effective-log-snapshot-options resource options))
                       (container (if (plist-get resource-options :restart-window)
                                      (kubect--select-container-for-pod
                                       pod resource-context resource-namespace t)
                                    (kubect--read-container pod resource-context resource-namespace)))
                       (identifier (format "%s/%s" kind name))
                       (output (kubect--bulk-log-snapshot-output
                                pod container resource-context resource-namespace resource-options)))
            (insert (format "== %s -> pod/%s%s ==\n\n%s\n\n"
                            identifier
                            pod
                            (if container (format " container=%s" container) "")
                            output))))
        (goto-char (point-min)))
      (kubect-report-mode))
    (let ((kubect--display-buffer-action-override
           (kubect--display-action-from-prefix arg)))
      (kubect--display-buffer buffer))))

(defun kubect--initial-log-selector (&optional context namespace)
  "Return a useful initial log selector for CONTEXT and NAMESPACE."
  (or (ignore-errors
        (when (derived-mode-p 'kubect-session-mode)
          (pcase-let* ((`(:kind ,kind :name ,name :context ,line-context :namespace ,line-namespace)
                        (kubect--current-line-resource-plist)))
            (kubect--selector-for-resource kind name
                                           (or context line-context)
                                           (or namespace line-namespace)))))
      (kubect--project-default :log-selector)))

(defun kubect--read-log-selector (&optional context namespace initial)
  "Prompt for a log label selector in CONTEXT and NAMESPACE."
  (let* ((initial (or initial
                      (kubect--initial-log-selector context namespace)))
         (candidates (kubect--log-selector-candidates context namespace))
         (selector (if candidates
                       (completing-read "Label selector: "
                                        candidates nil nil initial
                                        'kubect--selector-history initial)
                     (read-string "Label selector: " initial))))
    (unless (and selector (not (string-empty-p selector)))
      (user-error "A label selector is required"))
    selector))

(defun kubect--log-selector-candidates (&optional context namespace)
  "Return completion candidates for label selectors in CONTEXT and NAMESPACE."
  (let* ((context (or context (kubect-current-context)))
         (namespace (or namespace (kubect-current-namespace)))
         (data (apply #'kubect--kubectl-json
                      (append (kubect--kubectl-base-args context namespace)
                              (list "get" "pods" "-o" "json"))))
         (candidates (make-hash-table :test #'equal)))
    (dolist (item (alist-get 'items data))
      (dolist (label (alist-get 'labels (alist-get 'metadata item)))
        (puthash (format "%s" (car label)) t candidates)
        (puthash (format "%s=%s" (car label) (cdr label)) t candidates)))
    (sort (hash-table-keys candidates) #'string<)))

(defun kubect-logs (pod &optional container context namespace display-action previous all-containers)
  "Stream logs for POD and optional CONTAINER in CONTEXT and NAMESPACE."
  (interactive
   (let* ((pod (kubect--read-pod))
          (container (kubect--read-container pod)))
     (list pod container nil nil
           (kubect--display-action-from-prefix current-prefix-arg)
           nil nil)))
  (let ((kubect--display-buffer-action-override display-action))
    (kubect--record-session-command
     (cond
      (all-containers "logs-all")
      (previous "logs-previous")
      (t "logs"))
     (if container
         (format "%s/%s" pod container)
       pod))
    (kubect--start-stream
     (format "logs %s%s%s" pod
             (if previous " previous" "")
             (if all-containers " all" ""))
     (kubect--logs-args pod container context namespace previous all-containers nil)
     context namespace
     (list :mode 'logs
           :name (format "logs %s%s%s" pod
                         (if previous " previous" "")
                         (if all-containers " all" ""))
           :pod pod
           :container container
           :context context
           :namespace namespace
           :previous previous
           :all-containers all-containers
           :timestamps nil))))

(defun kubect-logs-previous (pod &optional container context namespace display-action)
  "Stream previous logs for POD."
  (interactive
   (let* ((pod (kubect--read-pod))
          (container (kubect--read-container pod)))
     (list pod container nil nil
           (kubect--display-action-from-prefix current-prefix-arg))))
  (kubect-logs pod container context namespace display-action t nil))

(defun kubect-logs-all-containers (pod &optional context namespace display-action)
  "Stream logs for all containers in POD."
  (interactive
   (let ((pod (kubect--read-pod)))
     (list pod nil nil nil
           (kubect--display-action-from-prefix current-prefix-arg))))
  (kubect-logs pod nil context namespace display-action nil t))

(defun kubect-logs-resource (&optional arg)
  "Stream logs for the pod at point, or resolve a pod for the resource."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist))
               (pod (or (kubect--pod-for-resource kind name context namespace)
                        (kubect--read-pod context namespace)))
               (container (kubect--read-container pod context namespace)))
    (kubect-logs pod container context namespace
                 (kubect--display-action-from-prefix arg))))

(defun kubect-logs-previous-resource (&optional arg)
  "Stream previous logs for the pod behind the current resource."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist))
               (pod (or (kubect--pod-for-resource kind name context namespace)
                        (kubect--read-pod context namespace)))
               (container (kubect--read-container pod context namespace)))
    (kubect-logs-previous pod container context namespace
                          (kubect--display-action-from-prefix arg))))

(defun kubect-logs-all-containers-resource (&optional arg)
  "Stream all-container logs for the pod behind the current resource."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist))
               (pod (or (kubect--pod-for-resource kind name context namespace)
                        (kubect--read-pod context namespace))))
  (kubect-logs-all-containers pod context namespace
                                (kubect--display-action-from-prefix arg))))

(defun kubect-logs-selector (selector &optional context namespace display-action)
  "Stream logs for all pods matching SELECTOR in CONTEXT and NAMESPACE.
This follows logs across all matching pods and all containers."
  (interactive
   (let* ((context (kubect-current-context))
          (namespace (kubect-current-namespace))
          (selector (kubect--read-log-selector context namespace)))
     (list selector context namespace
           (kubect--display-action-from-prefix current-prefix-arg))))
  (let* ((context (or context (kubect-current-context)))
         (namespace (or namespace (kubect-current-namespace)))
         (kubect--display-buffer-action-override display-action)
         (name (format "logs selector %s" selector)))
    (kubect--record-session-command "logs-selector" selector)
    (kubect--start-stream
     name
     (kubect--logs-args nil nil context namespace nil t nil selector)
     context namespace
     (list :mode 'logs
           :name name
           :selector selector
           :context context
           :namespace namespace
           :previous nil
           :all-containers t
           :timestamps nil))))

(defun kubect-logs-selector-resource (&optional arg)
  "Stream logs for all pods matching the selector of the resource at point."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist))
               (selector (or (kubect--selector-for-resource kind name context namespace)
                             (kubect--read-log-selector context namespace))))
    (kubect-logs-selector selector context namespace
                          (kubect--display-action-from-prefix arg))))

(provide 'kubect-logs)
;;; kubect-logs.el ends here
