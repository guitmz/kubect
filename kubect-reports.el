;;; kubect-reports.el --- Kubect reports -*- lexical-binding: t; -*-

(require 'kubect-core)

(defun kubect--yaml-top-level-value (key)
  "Return the top-level YAML KEY from the current document."
  (pcase-let ((`(,start . ,end) (kubect--current-doc-bounds)))
    (save-excursion
      (goto-char start)
      (when (re-search-forward
             (format "^%s:[[:space:]]*\\([^#\n]+\\)$" (regexp-quote key))
             end t)
        (string-trim (match-string 1) "\"" "\"")))))

(defun kubect--report-style-buffer ()
  "Apply stable face styling to the current kubect report buffer."
  (let ((inhibit-read-only t))
    (cl-labels ((paint (beg end face)
                  (put-text-property beg end 'face face)
                  (put-text-property beg end 'font-lock-face face)))
    (save-excursion
      (goto-char (point-min))
      (when (not (eobp))
        (let ((line-end (line-end-position)))
          (when (re-search-forward "  " line-end t)
            (when (member (buffer-substring-no-properties (point-min) (- (point) 2))
                          '("OVERVIEW" "XRAY" "TIMELINE"))
              (paint (point-min) (- (point) 2) 'kubect-report-title-face)
              (paint (point) line-end 'kubect-report-subject-face)))))
      (goto-char (point-min))
      (forward-line 1)
      (when (not (eobp))
        (paint (line-beginning-position)
               (line-end-position)
               'kubect-report-subtle-face))))))

(defun kubect--report-title (title subject)
  "Return a formatted overview TITLE and SUBJECT line."
  (concat (propertize (upcase title) 'face 'kubect-report-title-face)
          "  "
          (propertize subject 'face 'kubect-report-subject-face)
          "\n"
          (propertize kubect--report-rule 'face 'kubect-report-subtle-face)
          "\n\n"))

(defun kubect--report-section (title body &optional compact)
  "Return a formatted section TITLE with BODY.
When COMPACT is non-nil, omit the extra trailing blank line."
  (concat (format "## %s\n" title)
          "-----\n"
          body
          (unless (string-suffix-p "\n" body) "\n")
          (unless compact "\n")))

(defun kubect--report-kv-lines (pairs &optional indent)
  "Return aligned key/value lines for PAIRS using INDENT."
  (let* ((indent (or indent 2))
         (width (max 8 (apply #'max 0 (mapcar (lambda (pair) (length (car pair))) pairs)))))
    (mapconcat
     (lambda (pair)
       (let* ((value (if (consp (cdr pair))
                         (cadr pair)
                       (cdr pair)))
              (label (concat (car pair) ":"))
              (padding (max 1 (- (1+ width) (length label)))))
         (concat (make-string indent ?\s)
                 label
                 (make-string padding ?\s)
                 (format "%s" (or value "")))))
     pairs
     "\n")))

(defun kubect--report-footer (&optional extra watchable)
  "Return a common footer line with optional EXTRA and WATCHABLE hint."
  (concat kubect--report-rule
          "\n"
          (concat "Press ? for commands, g to refresh"
                  (when watchable ", t to watch")
                  ", o for occur, q to quit.")
          (when extra
            (format "  %s" extra))
          "\n"))

(defun kubect--report-block (lines &optional indent)
  "Return LINES joined as a report block with INDENT spaces."
  (let ((prefix (make-string (or indent 2) ?\s)))
    (concat
     (string-join (mapcar (lambda (line) (concat prefix line)) lines) "\n")
     "\n")))

(defun kubect-stop-watch ()
  "Stop automatic refresh for the current kubect session buffer."
  (interactive)
  (when (timerp kubect--watch-timer)
    (cancel-timer kubect--watch-timer))
  (setq kubect--watch-timer nil)
  (when (called-interactively-p 'interactive)
    (force-mode-line-update)
    (message "Kubect watch disabled")))

(defun kubect--show-report-buffer (title body context namespace &optional arg header state)
  "Show a read only kubect report with TITLE and BODY.
HEADER, when non-nil, becomes the report buffer header line.
STATE stores extra report-local metadata such as URL lists."
  (let ((buffer (get-buffer-create
                 (kubect--compilation-buffer-name title context namespace))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert body)
        (goto-char (point-min)))
      (kubect-report-mode)
      (setq-local header-line-format header)
      (setq-local kubect-report-state state)
      (kubect--report-style-buffer))
    (let ((kubect--display-buffer-action-override
           (kubect--display-action-from-prefix arg)))
      (kubect--display-buffer buffer))))

(defun kubect--timeline-items (context namespace &optional field-selector limit)
  "Return recent event items for CONTEXT, NAMESPACE, and FIELD-SELECTOR."
  (let* ((data (apply #'kubect--kubectl-json
                      (append (kubect--kubectl-base-args context namespace)
                              (list "get" "events"
                                    "--sort-by=.lastTimestamp"
                                    "-o" "json")
                              (when field-selector
                                (list "--field-selector" field-selector)))))
         (items (reverse (alist-get 'items data))))
    (if (and limit (> (length items) limit))
        (cl-subseq items 0 limit)
      items)))

(defun kubect--timeline-body (context namespace &optional field-selector title limit)
  "Return a timeline report body for CONTEXT and NAMESPACE."
  (let* ((items (kubect--timeline-items context namespace field-selector limit))
         (lines (if items
                    (mapcar (lambda (item) (kubect--event-item-line item t)) items)
                    '("No events")))
         (scope (if (equal namespace kubect-all-namespaces-token)
                    "all namespaces"
                  namespace)))
    (let ((scope-body
           (concat
            (kubect--report-kv-lines
             `(("Context" ,context)
               ("Namespace" ,scope)
               ("Limit" ,(number-to-string (or limit kubect-timeline-default-limit)))))
            "\n"))
          (events-body
           (concat
            (string-join (mapcar (lambda (line) (format "  %s" line)) lines) "\n")
            "\n")))
      (concat
       (kubect--report-title "timeline" (or title "recent-events"))
       (kubect--report-section "Scope" scope-body)
       (kubect--report-section "Events" events-body)
       (kubect--report-footer nil t)))))

(defun kubect-timeline (&optional arg)
  "Open a unified recent event timeline for the current scope.
With a prefix ARG, prefer all namespaces."
  (interactive "P")
  (let* ((session (ignore-errors (kubect--current-session)))
         (context (if session
                      (kubect-session-context session)
                    (kubect-current-context)))
         (namespace (cond
                     ((equal arg '(4)) kubect-all-namespaces-token)
                     (session (kubect-session-namespace session))
                     (t (kubect-current-namespace))))
         (scope (if (equal namespace kubect-all-namespaces-token)
                    "all namespaces"
                  namespace))
         (title (format "timeline %s" scope))
         (header (format "Timeline: %s/%s | g refresh | t watch | q quit"
                         context scope))
         (state (list :type 'plain
                      :header header
                      :body (kubect--timeline-body context namespace nil title
                                                   kubect-timeline-default-limit)
                      :refresh-fn
                      (lambda (state)
                        (plist-put
                         (copy-sequence state)
                         :body
                         (kubect--timeline-body
                          context namespace nil title kubect-timeline-default-limit))))))
    (kubect--show-report-buffer
     title
     (plist-get state :body)
     context namespace arg header state)))

(defun kubect-timeline-for-resource (&optional arg)
  "Open a recent event timeline scoped to the resource at point."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--resource-for-command))
               (selector (kubect--event-field-selector kind name))
               (title (format "timeline %s/%s" kind name))
               (header (format "Timeline: %s/%s  %s/%s | g refresh | t watch | q quit"
                               context namespace kind name))
               (state (list :type 'plain
                            :header header
                            :body (kubect--timeline-body context namespace selector title
                                                         kubect-timeline-default-limit)
                            :refresh-fn
                            (lambda (state)
                              (plist-put
                               (copy-sequence state)
                               :body
                               (kubect--timeline-body
                                context namespace selector title
                                kubect-timeline-default-limit))))))
    (kubect--record-session-command "timeline" (format "%s/%s" kind name))
    (kubect--show-report-buffer
     title
     (plist-get state :body)
     context namespace arg header state)))

(defun kubect--home-body (context namespace summary-namespace)
  "Return a pulses-style home body for CONTEXT, NAMESPACE, and SUMMARY-NAMESPACE."
  (let* ((pod-summary (kubect--pods-health-summary context summary-namespace))
         (event-summary (kubect--event-warning-summary context summary-namespace))
         (sessions (cl-remove-if-not #'kubect--session-live-p kubect--sessions))
         (profiles (kubect--investigation-profile-names))
         (scope-label (if (equal summary-namespace kubect-all-namespaces-token)
                          "all namespaces"
                        summary-namespace))
         (hot-pods
          (if-let* ((samples (plist-get pod-summary :samples)))
              (kubect--report-block
               (mapcar (lambda (sample)
                         (format "%-28s %-20s restarts=%s"
                                 (format "%s/%s"
                                         (plist-get sample :namespace)
                                         (plist-get sample :name))
                                 (plist-get sample :status)
                                 (plist-get sample :restarts)))
                       samples))
            (kubect--report-block '("none"))))
         (warnings
          (if-let* ((recent (plist-get event-summary :recent)))
              (kubect--report-block recent 0)
            (kubect--report-block '("none") 0)))
         (profile-lines
          (if profiles
              (kubect--report-block profiles)
            (kubect--report-block '("none"))))
         (session-lines
          (if sessions
              (kubect--report-block
               (mapcar (lambda (session)
                         (kubect-session-name session))
                       sessions))
            (kubect--report-block '("none")))))
    (let ((context-body
           (concat
            (kubect--report-kv-lines
             `(("Context" ,context)
               ("Namespace" ,namespace)
               ("Resource" ,(kubect-current-resource))
               ("Pulse scope" ,scope-label)))
            "\n"))
          (pulse-body
           (concat
            (kubect--report-kv-lines
             `(("Pods" ,(format "%d total" (plist-get pod-summary :total)))
               ("Unhealthy" ,(number-to-string (plist-get pod-summary :unhealthy)))
               ("Pending" ,(number-to-string (plist-get pod-summary :pending)))
               ("Restarting" ,(number-to-string (plist-get pod-summary :restarting)))
               ("Warning events" ,(number-to-string (plist-get event-summary :warnings)))
               ("Active sessions" ,(number-to-string (length sessions)))))
            "\n")))
      (concat
       (kubect--report-title "overview"
                             (format "%s  pulse:%s"
                                     context
                                     (if (equal summary-namespace kubect-all-namespaces-token)
                                         "all-namespaces"
                                       summary-namespace)))
       (kubect--report-section "Context" context-body)
       (kubect--report-section "Pulse" pulse-body)
       (kubect--report-section "Hot Pods" hot-pods)
       (kubect--report-section "Recent Warnings" warnings t)
       (kubect--report-section "Profiles" profile-lines)
       (kubect--report-section "Sessions" session-lines)
       (kubect--report-footer ". home  X xray  y timeline  N all namespaces  P all pods" t)))))

(defun kubect-home (&optional arg)
  "Open a pulses-style kubect home buffer for the current context."
  (interactive "P")
  (let* ((session (ignore-errors (kubect--current-session)))
         (context (if session
                      (kubect-session-context session)
                    (kubect-current-context)))
         (namespace (if session
                        (kubect-session-namespace session)
                      (kubect-current-namespace)))
         (summary-namespace
          (if (equal arg '(4))
              kubect-all-namespaces-token
            namespace))
         (title "home")
         (body (kubect--home-body context namespace summary-namespace))
         (header (format "Kubect home: %s  pulse=%s | g refresh | t watch | q quit"
                         context
                         (if (equal summary-namespace kubect-all-namespaces-token)
                             "all-namespaces"
                           summary-namespace)))
         (state (list :type 'plain
                      :header header
                      :body body
                      :refresh-fn
                      (lambda (state)
                        (plist-put (copy-sequence state)
                                   :body
                                   (kubect--home-body context namespace summary-namespace))))))
    (kubect--show-report-buffer title body context namespace arg header state)))

(defun kubect--xray-body (resource)
  "Return a text focused xray body for RESOURCE plist."
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace) resource)
               (summary (kubect--resource-basic-summary kind name context namespace))
               (owners (mapcar (lambda (entry)
                                 (format "%s/%s"
                                         (alist-get 'kind entry)
                                         (alist-get 'name entry)))
                               (or (plist-get summary :owners) '())))
               (selector (kubect--selector-for-resource kind name context namespace))
               (pods (when selector
                       (kubect--pod-names-for-selector selector context namespace)))
               (events (kubect--resource-event-items kind name context namespace 8))
               (urls (kubect--resource-url-lines kind name context namespace))
               (spec (plist-get summary :spec))
               (template-spec (or (alist-get 'template spec)
                                  (alist-get 'template (alist-get 'spec (plist-get summary :data)))))
               (pod-spec (or (alist-get 'spec template-spec)
                             (and (member (kubect--singular-kind kind) '("pod" "pods"))
                                  spec)))
               (config-refs (and pod-spec (kubect--pod-config-refs pod-spec)))
               (replicasets (when (member (kubect--singular-kind kind) '("deployment" "deployments"))
                              (mapcar (lambda (entry)
                                        (format "replicaset/%s revision=%s"
                                                (plist-get entry :name)
                                                (plist-get entry :revision)))
                                      (kubect--deployment-replicasets name context namespace))))
               (service-refs
                (when (member (kubect--singular-kind kind) '("pod" "pods"))
                  (kubect--services-for-pod summary context namespace)))
               (ingress-refs
                (when (member (kubect--singular-kind kind) '("service" "services"))
                  (kubect--ingresses-for-service name context namespace))))
    (let ((resource-body
           (concat
            (kubect--report-kv-lines
             `(("Context" ,context)
               ("Namespace" ,namespace)
               ("Kind" ,kind)
               ("Name" ,name)
               ("Selector" ,(or selector "n/a"))))
            "\n"
            (when owners
              (concat "\n  Owners:\n"
                      (string-join (mapcar (lambda (line) (format "    - %s" line)) owners) "\n")
                      "\n"))
            (when urls
              (concat "\n  URLs:\n"
                      (string-join (mapcar (lambda (line) (format "    - %s" line)) urls) "\n")
                      "\n"))))
          (related-body
           (concat
            "  Pods:\n"
            (if pods
                (concat
                 (string-join (mapcar (lambda (line) (format "    - pod/%s" line)) pods) "\n")
                              "\n")
              "    - none resolved\n")
            (when service-refs
              (concat "  Services:\n"
                      (string-join (mapcar (lambda (line) (format "    - service/%s" line)) service-refs) "\n")
                      "\n"))
            (when ingress-refs
              (concat "  Ingresses:\n"
                      (string-join (mapcar (lambda (line) (format "    - ingress/%s" line)) ingress-refs) "\n")
                      "\n"))
            (when replicasets
              (concat "  ReplicaSets:\n"
                      (string-join (mapcar (lambda (line) (format "    - %s" line)) replicasets) "\n")
                      "\n"))
            (when config-refs
              (concat "  Config refs:\n"
                      (string-join (mapcar (lambda (line) (format "    - %s" line)) config-refs) "\n")
                      "\n"))))
          (events-body
           (if events
               (concat
                (string-join
                 (mapcar (lambda (item)
                           (format "  - %s" (kubect--event-item-line item)))
                         events)
                 "\n")
                "\n")
             "  - none\n")))
      (concat
       (kubect--report-title "xray" (format "%s/%s" kind name))
       (kubect--report-section "Resource" resource-body)
       (kubect--report-section "Related" related-body)
       (kubect--report-section "Recent Events" events-body)
       (kubect--report-footer "RET opens buttons when present.")))))

(defun kubect-xray (&optional arg)
  "Open a text focused dependency xray for the current resource."
  (interactive "P")
  (let* ((resource (kubect--resource-for-command))
         (context (plist-get resource :context))
         (namespace (plist-get resource :namespace))
         (kind (plist-get resource :kind))
         (name (plist-get resource :name))
         (title (format "xray %s/%s" kind name))
         (header (format "Xray: %s/%s/%s | g refresh | q quit"
                         context namespace title))
         (state (list :type 'plain
                      :header header
                      :body (kubect--xray-body resource)
                      :refresh-fn
                      (lambda (state)
                        (plist-put (copy-sequence state)
                                   :body
                                   (kubect--xray-body resource))))))
    (kubect--record-session-command "xray" (format "%s/%s" kind name))
    (kubect--show-report-buffer title (plist-get state :body)
                                context namespace arg header state)))

(defun kubect--report-target (label kind name context namespace &optional action)
  "Return LABEL carrying a navigable Kubernetes resource target."
  (propertize label 'kubect-resource-target
              (list :kind kind :name name :context context :namespace namespace
                    :action (or action 'view))))

(defun kubect--resource-graph-body (resource)
  "Return a compact, navigable dependency graph for RESOURCE."
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace) resource)
               (summary (kubect--resource-basic-summary kind name context namespace))
               (owners (alist-get 'ownerReferences (alist-get 'metadata (plist-get summary :data))))
               (selector (kubect--selector-for-resource kind name context namespace))
               (pods (when selector
                       (kubect--pod-names-for-selector selector context namespace)))
               (spec (or (alist-get 'template (plist-get summary :spec))
                         (plist-get summary :spec)))
               (pod-spec (or (alist-get 'spec spec) spec))
               (config-refs (and (eq kubect-graph-depth 'full)
                                 (kubect--pod-config-refs pod-spec)))
               (root (kubect--report-target (format "%s/%s" kind name)
                                            kind name context namespace)))
    (concat
     (kubect--report-title "graph" (format "%s/%s" kind name))
     (kubect--report-section
      "Edges"
      (concat "  " root "\n"
              (if owners
                  (concat
                   (mapconcat
                    (lambda (owner)
                      (format "    <- owner: %s"
                              (kubect--report-target
                               (format "%s/%s" (alist-get 'kind owner) (alist-get 'name owner))
                               (alist-get 'kind owner) (alist-get 'name owner)
                               context namespace)))
                    owners "\n") "\n")
                "    <- owner: none\n")
              (if (and selector (memq kubect-graph-depth '(workload full)))
                  (format "    -> selector: %s\n" selector)
                "    -> selector: none\n")
              (if (and pods (memq kubect-graph-depth '(workload full)))
                  (concat (mapconcat
                           (lambda (pod)
                             (format "      -> %s"
                                     (kubect--report-target (format "pod/%s" pod)
                                                            "pods" pod context namespace)))
                           pods "\n") "\n")
                "      -> pods: none resolved\n")
              (if config-refs
                  (concat (mapconcat
                           (lambda (ref)
                             (pcase-let ((`(,ref-kind ,ref-name) (split-string ref "/" t)))
                               (format "    -> config: %s"
                                       (kubect--report-target ref ref-kind ref-name context namespace))))
                           config-refs "\n") "\n")
                "    -> config: none\n")))
     (kubect--report-footer "RET opens the node at point." t))))

(defun kubect-resource-graph (&optional arg)
  "Open a navigable dependency graph for the resource at point."
  (interactive "P")
  (let* ((kubect-graph-depth
          (if arg
              (intern (kubect--completing-read "Graph depth: " '("owners" "workload" "full")
                                               (symbol-name kubect-graph-depth)))
            kubect-graph-depth))
         (resource (kubect--resource-for-command))
         (context (plist-get resource :context))
         (namespace (plist-get resource :namespace))
         (title (format "graph %s/%s" (plist-get resource :kind) (plist-get resource :name)))
         (header (format "Graph: %s/%s depth=%s | RET open node | g refresh | q quit"
                         context namespace kubect-graph-depth))
         (state (list :type 'plain :header header
                      :body (kubect--resource-graph-body resource)
                      :refresh-fn (lambda (state)
                                    (plist-put (copy-sequence state) :body
                                               (kubect--resource-graph-body resource))))))
    (kubect--show-report-buffer title (plist-get state :body)
                                context namespace arg header state)))

(defun kubect--namespace-dashboard-data (context)
  "Return per-namespace pod and warning counts for CONTEXT."
  (let ((counts (make-hash-table :test #'equal)))
    (cl-labels ((entry (namespace)
                  (or (gethash namespace counts)
                      (let ((value (list :namespace namespace :pods 0 :unhealthy 0
                                         :pending 0 :restarts 0 :warnings 0)))
                        (puthash namespace value counts) value))))
      (dolist (pod (alist-get 'items
                               (kubect--kubectl-json "--context" context
                                                       "--all-namespaces=true" "get" "pods" "-o" "json")))
        (let* ((value (entry (alist-get 'namespace (alist-get 'metadata pod))))
               (status (kubect--pod-status-string pod))
               (restarts (kubect--pod-restarts pod)))
          (cl-incf (plist-get value :pods))
          (cl-incf (plist-get value :restarts) restarts)
          (when (> (kubect--pod-priority-score pod) 0) (cl-incf (plist-get value :unhealthy)))
          (when (string-match-p "Pending\\|ContainerCreating\\|Unknown" status)
            (cl-incf (plist-get value :pending)))))
      (dolist (event (alist-get 'items
                                 (kubect--kubectl-json "--context" context
                                                         "--all-namespaces=true" "get" "events" "-o" "json")))
        (when (equal (alist-get 'type event) "Warning")
          (cl-incf (plist-get (entry (alist-get 'namespace (alist-get 'metadata event))) :warnings))))
      (sort (hash-table-values counts)
            (lambda (left right)
              (> (+ (* 1000 (plist-get left :unhealthy)) (plist-get left :warnings))
                 (+ (* 1000 (plist-get right :unhealthy)) (plist-get right :warnings))))))))

(defun kubect--namespace-dashboard-body (context)
  "Return a namespace health dashboard for CONTEXT."
  (let ((rows (kubect--namespace-dashboard-data context)))
    (concat (kubect--report-title "dashboard" context)
            (kubect--report-section "Namespace Health"
                                     (concat "  NAMESPACE                         PODS  BAD  PENDING  RESTARTS  WARNINGS\n"
                                             (if rows
                                                 (concat (mapconcat
                                                          (lambda (row)
                                                            (format "  %-32s %4d %4d %8d %9d %9d"
                                                                    (kubect--report-target (plist-get row :namespace)
                                                                                           "pods" nil context
                                                                                           (plist-get row :namespace) 'session)
                                                                    (plist-get row :pods) (plist-get row :unhealthy)
                                                                    (plist-get row :pending) (plist-get row :restarts)
                                                                    (plist-get row :warnings)))
                                                          rows "\n") "\n")
                                               "  No namespaced workload data\n"))
            (kubect--report-footer "RET opens pods in the namespace." t)))))

(defun kubect-namespace-dashboard (&optional arg)
  "Open a cluster-wide namespace health dashboard."
  (interactive "P")
  (let* ((context (kubect-current-context))
         (title "namespace dashboard")
         (header (format "Namespace dashboard: %s | RET namespace pods | g refresh | t watch | q quit" context))
         (state (list :type 'plain :header header :body (kubect--namespace-dashboard-body context)
                      :refresh-fn (lambda (state)
                                    (plist-put (copy-sequence state) :body
                                               (kubect--namespace-dashboard-body context))))))
    (kubect--show-report-buffer title (plist-get state :body)
                                context kubect-all-namespaces-token arg header state)))

(defun kubect--alerts-body (context)
  "Return alerts for CONTEXT according to `kubect-alert-rules'."
  (let* ((rows (kubect--namespace-dashboard-data context))
         (pods (alist-get 'items (kubect--kubectl-json "--context" context
                                                    "--all-namespaces=true" "get" "pods" "-o" "json")))
         (lines nil))
    (dolist (rule kubect-alert-rules)
      (pcase-let ((`(,label . ,plist) rule))
        (pcase (plist-get plist :type)
          ('pod-status
           (dolist (pod pods)
             (when (> (kubect--pod-priority-score pod) 0)
               (push (format "  %-8s %-20s %s  %s"
                             (upcase (symbol-name (plist-get plist :severity))) label
                             (kubect--report-target
                              (format "%s/pod/%s" (alist-get 'namespace (alist-get 'metadata pod))
                                      (alist-get 'name (alist-get 'metadata pod)))
                              "pods" (alist-get 'name (alist-get 'metadata pod)) context
                              (alist-get 'namespace (alist-get 'metadata pod)))
                             (kubect--pod-status-string pod)) lines))))
          ('pod-restarts
           (dolist (pod pods)
             (when (>= (kubect--pod-restarts pod) (or (plist-get plist :minimum) 1))
               (push (format "  %-8s %-20s %s  restarts=%d"
                             (upcase (symbol-name (plist-get plist :severity))) label
                             (kubect--report-target
                              (format "%s/pod/%s" (alist-get 'namespace (alist-get 'metadata pod))
                                      (alist-get 'name (alist-get 'metadata pod)))
                              "pods" (alist-get 'name (alist-get 'metadata pod)) context
                              (alist-get 'namespace (alist-get 'metadata pod)))
                             (kubect--pod-restarts pod)) lines))))
          ('warning-events
           (dolist (row rows)
             (when (>= (plist-get row :warnings) (or (plist-get plist :minimum) 1))
               (push (format "  %-8s %-20s %s  warnings=%d"
                             (upcase (symbol-name (plist-get plist :severity))) label
                             (kubect--report-target (plist-get row :namespace) "pods" nil context
                                                    (plist-get row :namespace) 'session)
                             (plist-get row :warnings)) lines)))))))
    (concat (kubect--report-title "alerts" context)
            (kubect--report-section "Active Alerts"
                                     (if lines
                                         (concat (string-join (nreverse lines) "\n") "\n")
                                       "  No alerts matched the configured rules\n"))
            (kubect--report-footer "RET opens the affected pod or namespace." t))))

(defun kubect-alerts (&optional arg)
  "Open the configured cluster alert report."
  (interactive "P")
  (let* ((context (kubect-current-context))
         (title "alerts")
         (header (format "Alerts: %s | RET open target | g refresh | t watch | q quit" context))
         (state (list :type 'plain :header header :body (kubect--alerts-body context)
                      :refresh-fn (lambda (state)
                                    (plist-put (copy-sequence state) :body
                                               (kubect--alerts-body context))))))
    (kubect--show-report-buffer title (plist-get state :body)
                                context kubect-all-namespaces-token arg header state)))

(defun kubect-export-report-markdown ()
  "Copy the current Kubect report as portable Markdown."
  (interactive)
  (unless (derived-mode-p 'kubect-report-mode)
    (user-error "Current buffer is not a Kubect report"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (setq text (replace-regexp-in-string "^## " "## " text))
    (kill-new text)
    (message "Kubect report copied as Markdown")))

(defun kubect-incident-bundle (&optional arg)
  "Capture describe, recent events, and a pod log snapshot in one report."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--resource-for-command))
               (pod (or (and (member (kubect--singular-kind kind) '("pod" "pods")) name)
                        (ignore-errors (kubect--pod-for-resource kind name context namespace))))
               (describe (kubect--kubectl-output "--context" context "--namespace" namespace
                                                  "describe" (kubect--singular-kind kind) name))
               (events (kubect--resource-event-items kind name context namespace 20))
               (logs (when pod (kubect--kubectl-output "--context" context "--namespace" namespace
                                                       "logs" (format "--tail=%d" kubect-default-log-tail) pod)))
               (body (concat (kubect--report-title "incident bundle" (format "%s/%s" kind name))
                             (kubect--report-section "Describe" (concat describe "\n"))
                             (kubect--report-section "Recent Events"
                                                      (concat (or (mapconcat #'kubect--event-item-line events "\n") "none") "\n"))
                             (kubect--report-section "Log Snapshot" (concat (or logs "No pod resolved") "\n"))
                             (kubect--report-footer "M-x kubect-export-report-markdown copies this bundle."))))
    (kubect--show-report-buffer "incident bundle" body context namespace arg
                                (format "Incident bundle: %s/%s | o occur | q quit" kind name)
                                (list :type 'plain :body body))))

(defun kubect-compare-resource-contexts (left-context right-context &optional arg)
  "Compare the resource at point between LEFT-CONTEXT and RIGHT-CONTEXT."
  (interactive (list (kubect--completing-read "Left context: " (kubect--list-contexts))
                     (kubect--completing-read "Right context: " (kubect--list-contexts)) current-prefix-arg))
  (pcase-let* ((`(:kind ,kind :name ,name :namespace ,namespace) (kubect--resource-for-command))
               (left (kubect--resource-json kind name left-context namespace))
               (right (kubect--resource-json kind name right-context namespace))
               (left-text (kubect--json-pretty-string left))
               (right-text (kubect--json-pretty-string right)))
    (kubect--rollout-diff-buffer (format "%s %s" left-context name) (format "%s %s" right-context name)
                                 left-text right-text left-context namespace arg)))

(defun kubect-rbac-inspect (verb resource subject &optional context namespace arg)
  "Report whether SUBJECT can perform VERB on RESOURCE in the current scope."
  (interactive (list (kubect--completing-read "Verb: " '("get" "list" "watch" "create" "update" "patch" "delete"))
                     (kubect--completing-read "Resource: " kubect-resource-shortcuts)
                     (read-string "Impersonate user/serviceaccount (optional): ") nil nil current-prefix-arg))
  (let* ((context (or context (kubect-current-context))) (namespace (or namespace (kubect-current-namespace)))
         (answer (apply #'kubect--kubectl-output
                        (append (kubect--kubectl-base-args context namespace)
                                (list "auth" "can-i" verb resource)
                                (unless (string-empty-p subject) (list "--as" subject)))))
         (body (concat (kubect--report-title "rbac" (format "%s %s" verb resource))
                       (kubect--report-section "Decision" (concat "  " answer "\n"))
                       (kubect--report-footer))))
    (kubect--show-report-buffer "rbac" body context namespace arg
                                (format "RBAC: %s/%s | q quit" context namespace) (list :type 'plain :body body))))

(defun kubect-crd-view (name &optional arg)
  "Open configured custom-resource view NAME across all namespaces."
  (interactive (list (kubect--completing-read "CRD view: " (mapcar #'car kubect-crd-views)) current-prefix-arg))
  (let* ((spec (alist-get name kubect-crd-views nil nil #'equal))
         (resource (plist-get spec :resource))
         (columns (plist-get spec :columns)))
    (unless resource (user-error "CRD view %s has no :resource" name))
    (let* ((context (kubect-current-context))
           (output (apply #'kubect--kubectl-output
                          (append (kubect--kubectl-base-args context kubect-all-namespaces-token)
                                  (list "get" resource)
                                  (when columns (list "-o" (concat "custom-columns=" columns)))))))
      (kubect--show-output-buffer (format "crd %s" name) output context kubect-all-namespaces-token arg
                                  (format "CRD view: %s | q quit" name)))))

(defun kubect--pod-cost-resources (pod)
  "Return declared CPU and memory requests and limit coverage for POD."
  (let ((containers (alist-get 'containers (alist-get 'spec pod)))
        (cpu-request 0.0) (memory-request 0.0) (missing-limits nil))
    (dolist (container containers)
      (let* ((resources (alist-get 'resources container))
             (requests (alist-get 'requests resources))
             (limits (alist-get 'limits resources)))
        (setq cpu-request (+ cpu-request (kubect--cpu-millicores (alist-get 'cpu requests))))
        (setq memory-request (+ memory-request (kubect--memory-mib (alist-get 'memory requests))))
        (unless (and (alist-get 'cpu limits) (alist-get 'memory limits))
          (setq missing-limits t))))
    (list :cpu-request cpu-request :memory-request memory-request :missing-limits missing-limits)))

(defun kubect--cost-signal-lines (context)
  "Return capacity-risk lines from pod declarations and current metrics in CONTEXT."
  (let* ((pods (alist-get 'items
                           (kubect--kubectl-json "--context" context "get" "pods"
                                                  "--all-namespaces" "-o" "json")))
         (top-output (condition-case nil
                         (kubect--kubectl-output "--context" context "top" "pods" "--all-namespaces")
                       (error nil)))
         (usage (make-hash-table :test #'equal))
         lines)
    (dolist (row (and top-output (kubect--parse-top-output top-output)))
      (puthash (format "%s/%s" (alist-get "NAMESPACE" row nil nil #'equal)
                       (alist-get "NAME" row nil nil #'equal)) row usage))
    (dolist (pod pods)
      (let* ((metadata (alist-get 'metadata pod))
             (namespace (alist-get 'namespace metadata))
             (name (alist-get 'name metadata))
             (key (format "%s/%s" namespace name))
             (resources (kubect--pod-cost-resources pod))
             (top-row (gethash key usage))
             (cpu-usage (and top-row (kubect--cpu-millicores
                                      (alist-get "CPU(cores)" top-row nil nil #'equal))))
             (memory-usage (and top-row (kubect--memory-mib
                                         (alist-get "MEMORY(bytes)" top-row nil nil #'equal))))
             (target (kubect--report-target key "pods" name context namespace)))
        (when (plist-get resources :missing-limits)
          (push (format "  LIMITS   %s  missing CPU or memory limit" target) lines))
        (when (and cpu-usage (> (plist-get resources :cpu-request) 0)
                   (>= (/ (plist-get resources :cpu-request) (max 1.0 cpu-usage))
                       kubect-cost-request-usage-ratio))
          (push (format "  CPU      %s  request %.0fm vs usage %.0fm" target
                        (plist-get resources :cpu-request) cpu-usage) lines))
        (when (and memory-usage (> (plist-get resources :memory-request) 0)
                   (>= (/ (plist-get resources :memory-request) (max 1.0 memory-usage))
                       kubect-cost-request-usage-ratio))
          (push (format "  MEMORY   %s  request %.0fMi vs usage %.0fMi" target
                        (plist-get resources :memory-request) memory-usage) lines))))
    (nreverse lines)))

(defun kubect--cost-signals-body (context)
  "Build the cost-signal report body for CONTEXT."
  (let ((lines (kubect--cost-signal-lines context)))
    (concat (kubect--report-title "cost signals" context)
            (kubect--report-section
             "Capacity Signals"
             (if lines
                 (concat (string-join lines "\n") "\n")
               "  No cost signals matched current metrics\n"))
            (kubect--report-footer
             (format "Uses kubectl top. Ratio threshold: %sx." kubect-cost-request-usage-ratio) t))))

(defun kubect-cost-signals (&optional arg)
  "Report pods with missing limits or unusually high request-to-usage ratios."
  (interactive "P")
  (let* ((context (kubect-current-context))
         (header (format "Cost signals: %s | RET open pod | g refresh | q quit" context))
         (body (kubect--cost-signals-body context))
         (state (list :type 'plain :header header :body body
                      :refresh-fn (lambda (state)
                                    (plist-put (copy-sequence state) :body
                                               (kubect--cost-signals-body context))))))
    (kubect--show-report-buffer
     "cost signals" body context kubect-all-namespaces-token arg
     header state)))

(defun kubect--resource-pod-spec (data)
  "Return the pod spec embedded in Kubernetes resource DATA, if any."
  (let* ((spec (alist-get 'spec data))
         (template (or (alist-get 'template spec)
                       (alist-get 'template
                                  (alist-get 'spec
                                             (alist-get 'jobTemplate spec))))))
    (or (alist-get 'spec template)
        (and (alist-get 'containers spec) spec))))

(defun kubect--report-resource-with-session-scope (resource)
  "Return RESOURCE with the current Kubect buffer's authoritative scope.
Rows supply names and all-namespace row namespaces.  Session and report state
remain authoritative for context and ordinary namespace scopes."
  (let ((scoped (copy-sequence resource)) context namespace all-namespaces)
    (cond
     ((and (derived-mode-p 'kubect-session-mode) kubect-session)
      (setq context (kubect-session-context kubect-session)
            namespace (kubect-session-namespace kubect-session)
            all-namespaces (equal namespace kubect-all-namespaces-token)))
     ((and (derived-mode-p 'kubect-report-mode) kubect-report-state)
      (setq context (plist-get kubect-report-state :context)
            namespace (plist-get kubect-report-state :namespace)
            all-namespaces (equal namespace kubect-all-namespaces-token))))
    (when context
      (plist-put scoped :context context)
      (unless all-namespaces
        (plist-put scoped :namespace namespace)))
    scoped))

(defun kubect--policy-guardrail-lines (data)
  "Return security and resource guardrail findings for resource DATA."
  (let ((pod-spec (kubect--resource-pod-spec data)) lines)
    (when pod-spec
      (let ((pod-security (alist-get 'securityContext pod-spec)))
        (dolist (field '(hostNetwork hostPID hostIPC))
          (when (eq (alist-get field pod-spec) t)
            (push (format "  HIGH     %s is enabled" field) lines)))
        (when (equal (alist-get 'runAsUser pod-security) 0)
          (push "  HIGH     pod runs as UID 0" lines)))
      (dolist (volume (alist-get 'volumes pod-spec))
        (when (alist-get 'hostPath volume)
          (push (format "  HIGH     hostPath volume: %s" (alist-get 'name volume)) lines)))
      (dolist (container (append (alist-get 'containers pod-spec)
                                 (alist-get 'initContainers pod-spec)))
        (let* ((name (or (alist-get 'name container) "unnamed"))
               (security (alist-get 'securityContext container))
               (resources (alist-get 'resources container))
               (limits (alist-get 'limits resources))
               (image (or (alist-get 'image container) "")))
          (when (eq (alist-get 'privileged security) t)
            (push (format "  CRITICAL %s is privileged" name) lines))
          (when (equal (alist-get 'runAsUser security) 0)
            (push (format "  HIGH     %s runs as UID 0" name) lines))
          (when (or (string-empty-p image) (string-suffix-p ":latest" image)
                    (and (not (string-match-p "@" image))
                         (not (string-match-p ":" (car (split-string image "@"))))))
            (push (format "  MEDIUM   %s uses an unpinned image: %s" name image) lines))
          (unless (and (alist-get 'cpu limits) (alist-get 'memory limits))
            (push (format "  MEDIUM   %s lacks CPU or memory limits" name) lines)))))
    (nreverse lines)))

(defun kubect--policy-guardrails-body (resource)
  "Build a guardrail report for RESOURCE."
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace) resource)
               (data (kubect--resource-json kind name context namespace))
               (lines (kubect--policy-guardrail-lines data)))
    (concat (kubect--report-title "policy" (format "%s/%s" kind name))
            (kubect--report-section "Guardrails"
                                    (if lines (concat (string-join lines "\n") "\n")
                                      "  No pod-security or resource-limit findings\n"))
            (kubect--report-footer "Read only checks. Review findings in cluster context." t))))

(defun kubect-policy-guardrails (&optional arg)
  "Inspect the current resource for common pod security guardrails."
  (interactive "P")
  (let* ((resource (kubect--report-resource-with-session-scope
                    (kubect--resource-for-command)))
         (context (plist-get resource :context))
         (namespace (plist-get resource :namespace))
         (header "Policy guardrails | g refresh | q quit")
         (body (kubect--policy-guardrails-body resource))
         (state (list :type 'plain :header header :body body :refresh-fn
                      (lambda (state) (plist-put (copy-sequence state) :body
                                                  (kubect--policy-guardrails-body resource))))))
    (kubect--show-report-buffer "policy" body context namespace arg header state)))

(defun kubect--endpoint-slice-addresses (service context namespace)
  "Return ready endpoint addresses for SERVICE in CONTEXT and NAMESPACE."
  (condition-case nil
      (let* ((data (apply #'kubect--kubectl-json
                          (append (kubect--kubectl-base-args context namespace)
                                  (list "get" "endpointslices" "-l"
                                        (format "kubernetes.io/service-name=%s" service) "-o" "json"))))
             addresses)
        (dolist (slice (alist-get 'items data))
          (dolist (endpoint (alist-get 'endpoints slice))
            (when (not (eq (alist-get 'ready (alist-get 'conditions endpoint)) :json-false))
              (setq addresses (nconc addresses (alist-get 'addresses endpoint))))))
        (delete-dups addresses))
    (error nil)))

(defun kubect--network-explorer-body (resource)
  "Build the service, endpoint, ingress, and policy view for RESOURCE."
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace) resource)
               (data (kubect--resource-json kind name context namespace))
               (services (cond ((member (kubect--singular-kind kind) '("service" "services")) (list name))
                               ((member (kubect--singular-kind kind) '("pod" "pods"))
                                (kubect--services-for-pod
                                 (list :labels (alist-get 'labels (alist-get 'metadata data))) context namespace))
                               (t nil)))
               (policies (alist-get 'items (apply #'kubect--kubectl-json
                                                  (append (kubect--kubectl-base-args context namespace)
                                                          (list "get" "networkpolicies" "-o" "json"))))))
    (concat
     (kubect--report-title "network" (format "%s/%s" kind name))
     (kubect--report-section
      "Traffic Path"
      (if services
          (concat (mapconcat
                   (lambda (service)
                     (let ((target (kubect--report-target (format "service/%s" service) "services" service context namespace))
                           (ingresses (kubect--ingresses-for-service service context namespace))
                           (endpoints (kubect--endpoint-slice-addresses service context namespace)))
                       (concat "  " target "\n"
                               (format "    endpoints: %s\n" (or (and endpoints (string-join endpoints ", ")) "none"))
                               (format "    ingresses: %s" (or (and ingresses (string-join ingresses ", ")) "none")))))
                   services "\n") "\n")
        "  No directly selected Service resolved for this resource\n"))
     (kubect--report-section
      "Network Policies"
      (if policies
          (concat (mapconcat (lambda (policy)
                               (format "  %s" (kubect--report-target
                                                (format "networkpolicy/%s" (alist-get 'name (alist-get 'metadata policy)))
                                                "networkpolicies" (alist-get 'name (alist-get 'metadata policy)) context namespace)))
                             policies "\n") "\n")
        "  No NetworkPolicies in this namespace\n"))
     (kubect--report-footer "RET opens a linked Service or NetworkPolicy." t))))

(defun kubect-network-explorer (&optional arg)
  "Open a network path report for the current Service or Pod."
  (interactive "P")
  (let* ((context (kubect-current-context))
         (namespace (kubect-current-namespace))
         (resource (kubect--report-resource-with-session-scope
                    (kubect--resource-for-command context namespace)))
         (context (plist-get resource :context))
         (namespace (plist-get resource :namespace))
         (header "Network explorer | RET open target | g refresh | q quit")
         (body (kubect--network-explorer-body resource))
         (state (list :type 'plain :header header :body body :refresh-fn
                      (lambda (state) (plist-put (copy-sequence state) :body
                                                  (kubect--network-explorer-body resource))))))
    (kubect--show-report-buffer "network" body context namespace arg header state)))

(defun kubect--rollout-watch-body (resource)
  "Build a rollout-health report for workload RESOURCE."
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace) resource)
               (data (kubect--resource-json kind name context namespace))
               (spec (alist-get 'spec data))
               (status (alist-get 'status data))
               (selector (kubect--json-selector-string (alist-get 'matchLabels (alist-get 'selector spec))))
               (pods (and selector (kubect--pods-for-selector selector context namespace)))
               (events (kubect--resource-event-items kind name context namespace 10)))
    (concat
     (kubect--report-title "rollout" (format "%s/%s" kind name))
     (kubect--report-section "Progress"
                             (concat (kubect--report-kv-lines
                                      `(("Desired" ,(or (alist-get 'replicas spec) "n/a"))
                                        ("Updated" ,(or (alist-get 'updatedReplicas status) 0))
                                        ("Available" ,(or (alist-get 'availableReplicas status) 0))
                                        ("Unavailable" ,(or (alist-get 'unavailableReplicas status) 0)))) "\n"))
     (kubect--report-section "Pods"
                             (if pods
                                 (concat (mapconcat (lambda (pod)
                                                    (format "  %s" (kubect--report-target
                                                                     (format "pod/%s" (alist-get 'name (alist-get 'metadata pod)))
                                                                     "pods" (alist-get 'name (alist-get 'metadata pod)) context namespace)))
                                                  pods "\n") "\n")
                               "  No pods resolved from workload selector\n"))
     (kubect--report-section "Recent Events"
                             (concat (or (mapconcat #'kubect--event-item-line events "\n") "  none") "\n"))
     (kubect--report-footer "RET opens a pod. l/D/V work on report targets." t))))

(defun kubect-rollout-watch (&optional arg)
  "Watch rollout health, related pods, and events for the resource at point."
  (interactive "P")
  (let* ((resource (kubect--report-resource-with-session-scope
                    (kubect--resource-for-command)))
         (kind (kubect--singular-kind (plist-get resource :kind))))
    (unless (member kind '("deployment" "statefulset" "daemonset"))
      (user-error "Rollout watch supports Deployments, StatefulSets, and DaemonSets"))
    (let* ((context (plist-get resource :context))
           (namespace (plist-get resource :namespace))
           (header "Rollout watch | RET pod | g refresh | t watch | q quit")
           (body (kubect--rollout-watch-body resource))
           (state (list :type 'plain :header header :body body :refresh-fn
                        (lambda (state) (plist-put (copy-sequence state) :body
                                                    (kubect--rollout-watch-body resource))))))
      (kubect--show-report-buffer "rollout watch" body context namespace arg header state))))

(defun kubect--prometheus-query (query)
  "Run PromQL QUERY through the configured function or HTTP API."
  (cond
   (kubect-prometheus-query-function
    (funcall kubect-prometheus-query-function query))
   ((not kubect-prometheus-url)
    (user-error "Set kubect-prometheus-url or kubect-prometheus-query-function first"))
   (t
    (require 'url)
    (require 'url-util)
    (let ((buffer (url-retrieve-synchronously
                   (format "%s/api/v1/query?query=%s" (string-remove-suffix "/" kubect-prometheus-url)
                           (url-hexify-string query)) t t kubect-command-timeout)))
      (unless buffer (error "Prometheus request timed out"))
      (unwind-protect
          (let (response)
            (setq response (with-current-buffer buffer
            (goto-char (point-min))
            (re-search-forward "\r?\n\r?\n" nil 'move)
            (let ((json-object-type 'alist) (json-array-type 'list) (json-key-type 'symbol))
              (json-read))))
            (when (and (alist-get 'status response)
                       (not (equal (alist-get 'status response) "success")))
              (error "Prometheus error: %s" (or (alist-get 'error response) "unknown response")))
            response)
        (kill-buffer buffer))))))

(defun kubect--prometheus-result-lines (data)
  "Render Prometheus vector DATA as report lines."
  (mapcar
   (lambda (entry)
     (let* ((metric (alist-get 'metric entry))
            (value (cadr (alist-get 'value entry)))
            (labels (mapcar (lambda (pair) (format "%s=%s" (car pair) (cdr pair))) metric)))
       (format "  %-12s %s" (or value "n/a") (string-join labels " "))))
   (alist-get 'result (alist-get 'data data))))

(defun kubect-prometheus-alerts (&optional arg)
  "Show firing Prometheus alerts using `kubect-prometheus-alert-query'."
  (interactive "P")
  (let* ((header "Prometheus alerts | g refresh | q quit")
         (builder (lambda ()
                    (let* ((data (kubect--prometheus-query kubect-prometheus-alert-query))
                           (lines (kubect--prometheus-result-lines data)))
                      (concat (kubect--report-title "prometheus" "firing alerts")
                              (kubect--report-section "Alerts"
                                                      (if lines (concat (string-join lines "\n") "\n") "  No matching alerts\n"))
                              (kubect--report-footer "Query is customizable via kubect-prometheus-alert-query.")))))
         (body (funcall builder))
         (state (list :type 'plain :header header :body body :refresh-fn
                      (lambda (state) (plist-put (copy-sequence state) :body (funcall builder))))))
    (kubect--show-report-buffer "prometheus alerts" body (kubect-current-context)
                                kubect-all-namespaces-token arg header state)))

(defun kubect--top-number (value)
  "Return a sortable numeric score for kubectl top VALUE."
  (cond
   ((or (null value) (string-empty-p value)) 0)
   ((string-match "\\`\\([0-9.]+\\)n\\'" value)
    (/ (string-to-number (match-string 1 value)) 1000000.0))
   ((string-match "\\`\\([0-9.]+\\)m\\'" value)
    (string-to-number (match-string 1 value)))
   ((string-match "\\`\\([0-9.]+\\)Ki\\'" value)
    (/ (string-to-number (match-string 1 value)) 1024.0))
   ((string-match "\\`\\([0-9.]+\\)Mi\\'" value)
    (string-to-number (match-string 1 value)))
   ((string-match "\\`\\([0-9.]+\\)Gi\\'" value)
    (* 1024.0 (string-to-number (match-string 1 value))))
   (t
    (string-to-number value))))

(defun kubect--cpu-millicores (value)
  "Return VALUE converted to millicores."
  (cond
   ((or (null value) (equal value "")) 0.0)
   ((numberp value) (* 1000.0 value))
   ((string-match "\\`\\([0-9.]+\\)n\\'" value)
    (/ (string-to-number (match-string 1 value)) 1000000.0))
   ((string-match "\\`\\([0-9.]+\\)u\\'" value)
    (/ (string-to-number (match-string 1 value)) 1000.0))
   ((string-match "\\`\\([0-9.]+\\)m\\'" value)
    (string-to-number (match-string 1 value)))
   (t
    (* 1000.0 (string-to-number (format "%s" value))))))

(defun kubect--memory-mib (value)
  "Return VALUE converted to MiB."
  (cond
   ((or (null value) (equal value "")) 0.0)
   ((numberp value) (/ value (float (* 1024 1024))))
   ((string-match "\\`\\([0-9.]+\\)Ki\\'" value)
    (/ (string-to-number (match-string 1 value)) 1024.0))
   ((string-match "\\`\\([0-9.]+\\)Mi\\'" value)
    (string-to-number (match-string 1 value)))
   ((string-match "\\`\\([0-9.]+\\)Gi\\'" value)
    (* 1024.0 (string-to-number (match-string 1 value))))
   ((string-match "\\`\\([0-9.]+\\)Ti\\'" value)
    (* 1024.0 1024.0 (string-to-number (match-string 1 value))))
   ((string-match "\\`\\([0-9.]+\\)K\\'" value)
    (/ (* 1000.0 (string-to-number (match-string 1 value))) 1048576.0))
   ((string-match "\\`\\([0-9.]+\\)M\\'" value)
    (/ (* 1000000.0 (string-to-number (match-string 1 value))) 1048576.0))
   ((string-match "\\`\\([0-9.]+\\)G\\'" value)
    (/ (* 1000000000.0 (string-to-number (match-string 1 value))) 1048576.0))
   (t
    (/ (string-to-number (format "%s" value)) (float (* 1024 1024))))))

(defun kubect--pod-resource-total (pod resource parser)
  "Return POD RESOURCE total with init-container max semantics using PARSER."
  (let* ((spec (alist-get 'spec pod))
         (containers (alist-get 'containers spec))
         (init-containers (alist-get 'initContainers spec))
         (app-sum
          (cl-loop for container in containers
                   sum (funcall parser
                                (or (alist-get resource (alist-get 'requests (alist-get 'resources container)))
                                    0.0))))
         (init-max
          (cl-loop for container in init-containers
                   maximize (funcall parser
                                     (or (alist-get resource (alist-get 'requests (alist-get 'resources container)))
                                         0.0)) into current
                   finally return (or current 0.0)))
         (overhead
          (funcall parser
                   (or (alist-get resource (alist-get 'overhead spec))
                       0.0))))
    (+ (max app-sum init-max) overhead)))

(defun kubect--node-capacity-top-map (output)
  "Return an alist of node name to top row parsed from OUTPUT."
  (mapcar (lambda (row)
            (cons (alist-get "NAME" row nil nil #'equal) row))
          (kubect--parse-top-output output)))

(defun kubect--node-capacity-rows (nodes pods top-output)
  "Return kube-capacity-like rows from NODES, PODS, and TOP-OUTPUT."
  (let* ((top-map (kubect--node-capacity-top-map top-output))
         (pod-items (alist-get 'items pods))
         (pods-by-node (make-hash-table :test #'equal))
         (node-items (alist-get 'items nodes))
         (_index (dolist (pod pod-items)
                   (unless (member (alist-get 'phase (alist-get 'status pod))
                                   '("Succeeded" "Failed"))
                     (push pod (gethash (alist-get 'nodeName (alist-get 'spec pod)) pods-by-node)))))
         (rows
          (mapcar
           (lambda (node)
             (let* ((metadata (alist-get 'metadata node))
                    (status (alist-get 'status node))
                    (node-name (alist-get 'name metadata))
                    (allocatable (or (alist-get 'allocatable status)
                                     (alist-get 'capacity status)))
                    (cpu-total (kubect--cpu-millicores (alist-get 'cpu allocatable)))
                    (memory-total (kubect--memory-mib (alist-get 'memory allocatable)))
                    (pod-total (string-to-number (or (alist-get 'pods allocatable) "0")))
                    (node-pods (gethash node-name pods-by-node))
                    (cpu-requests
                     (cl-loop for pod in node-pods
                              sum (kubect--pod-resource-total pod 'cpu #'kubect--cpu-millicores)))
                    (cpu-limits
                     (cl-loop for pod in node-pods
                              sum (kubect--pod-limit-total pod 'cpu #'kubect--cpu-millicores)))
                    (memory-requests
                     (cl-loop for pod in node-pods
                              sum (kubect--pod-resource-total pod 'memory #'kubect--memory-mib)))
                    (memory-limits
                     (cl-loop for pod in node-pods
                              sum (kubect--pod-limit-total pod 'memory #'kubect--memory-mib)))
                    (top-row (cdr (assoc node-name top-map)))
                    (cpu-util (kubect--cpu-millicores
                               (alist-get "CPU(cores)" top-row nil nil #'equal)))
                    (memory-util (kubect--memory-mib
                                  (alist-get "MEMORY(bytes)" top-row nil nil #'equal)))
                    (pod-count (length node-pods)))
               `(("NODE" . ,node-name)
                 ("CPU REQUESTS" . ,(kubect--format-cpu-with-percent cpu-requests cpu-total))
                 ("CPU LIMITS" . ,(kubect--format-cpu-with-percent cpu-limits cpu-total))
                 ("CPU UTIL" . ,(if top-row (kubect--format-cpu-with-percent cpu-util cpu-total) "N/A"))
                 ("MEMORY REQUESTS" . ,(kubect--format-memory-with-percent memory-requests memory-total))
                 ("MEMORY LIMITS" . ,(kubect--format-memory-with-percent memory-limits memory-total))
                 ("MEMORY UTIL" . ,(if top-row (kubect--format-memory-with-percent memory-util memory-total) "N/A"))
                 ("POD COUNT" . ,(format "%s/%s" pod-count pod-total))
                 ("__cpu-requests" . ,cpu-requests)
                 ("__cpu-limits" . ,cpu-limits)
                 ("__cpu-util" . ,cpu-util)
                 ("__memory-requests" . ,memory-requests)
                 ("__memory-limits" . ,memory-limits)
                 ("__memory-util" . ,memory-util)
                 ("__pod-count" . ,pod-count))))
           node-items))
         (cluster-cpu-total
          (cl-loop for node in node-items
                   sum (kubect--cpu-millicores
                        (alist-get 'cpu
                                   (or (alist-get 'allocatable (alist-get 'status node))
                                       (alist-get 'capacity (alist-get 'status node)))))))
         (cluster-memory-total
          (cl-loop for node in node-items
                   sum (kubect--memory-mib
                        (alist-get 'memory
                                   (or (alist-get 'allocatable (alist-get 'status node))
                                       (alist-get 'capacity (alist-get 'status node)))))))
         (cluster-pod-total
          (cl-loop for node in node-items
                   sum (string-to-number
                        (or (alist-get 'pods
                                       (or (alist-get 'allocatable (alist-get 'status node))
                                           (alist-get 'capacity (alist-get 'status node))))
                            "0"))))
         (cpu-requests (cl-loop for row in rows sum (alist-get "__cpu-requests" row nil nil #'equal)))
         (cpu-limits (cl-loop for row in rows sum (alist-get "__cpu-limits" row nil nil #'equal)))
         (cpu-util (cl-loop for row in rows sum (alist-get "__cpu-util" row nil nil #'equal)))
         (memory-requests (cl-loop for row in rows sum (alist-get "__memory-requests" row nil nil #'equal)))
         (memory-limits (cl-loop for row in rows sum (alist-get "__memory-limits" row nil nil #'equal)))
         (memory-util (cl-loop for row in rows sum (alist-get "__memory-util" row nil nil #'equal)))
         (pod-count (cl-loop for row in rows sum (alist-get "__pod-count" row nil nil #'equal)))
         (total-row
          `(("NODE" . "*")
            ("CPU REQUESTS" . ,(kubect--format-cpu-with-percent cpu-requests cluster-cpu-total))
            ("CPU LIMITS" . ,(kubect--format-cpu-with-percent cpu-limits cluster-cpu-total))
            ("CPU UTIL" . ,(kubect--format-cpu-with-percent cpu-util cluster-cpu-total))
            ("MEMORY REQUESTS" . ,(kubect--format-memory-with-percent memory-requests cluster-memory-total))
            ("MEMORY LIMITS" . ,(kubect--format-memory-with-percent memory-limits cluster-memory-total))
            ("MEMORY UTIL" . ,(kubect--format-memory-with-percent memory-util cluster-memory-total))
            ("POD COUNT" . ,(format "%s/%s" pod-count cluster-pod-total))
            ("__cpu-requests" . ,cpu-requests)
            ("__cpu-limits" . ,cpu-limits)
            ("__cpu-util" . ,cpu-util)
            ("__memory-requests" . ,memory-requests)
            ("__memory-limits" . ,memory-limits)
            ("__memory-util" . ,memory-util)
            ("__pod-count" . ,pod-count))))
    (when (cl-some (lambda (row) (equal (cdr (assoc "CPU UTIL" row)) "N/A")) rows)
      (setcdr (assoc "CPU UTIL" total-row) "N/A (partial)")
      (setcdr (assoc "MEMORY UTIL" total-row) "N/A (partial)"))
    (cons total-row rows)))

(defun kubect--node-capacity-table (rows)
  "Return a fixed-width table string from node-capacity ROWS."
  (let* ((columns '("NODE" "CPU REQUESTS" "CPU LIMITS" "CPU UTIL"
                    "MEMORY REQUESTS" "MEMORY LIMITS" "MEMORY UTIL" "POD COUNT"))
         (widths
          (mapcar
           (lambda (column)
             (max (length column)
                  (cl-loop for row in rows
                           maximize (length (format "%s" (alist-get column row nil nil #'equal))))))
           columns))
         (format-row
          (lambda (row)
            (string-join
             (cl-mapcar
              (lambda (column width)
                (format (format "%%-%ds" width)
                        (or (alist-get column row nil nil #'equal) "")))
              columns widths)
             "   "))))
    (string-join
     (cons (funcall format-row
                    (mapcar (lambda (column) (cons column column)) columns))
           (mapcar format-row rows))
     "\n")))

(defun kubect--node-capacity-state (&optional context)
  "Return report STATE for a kube-capacity-like node utilization view."
  (let* ((context (or context (kubect-current-context)))
         (nodes (kubect--kubectl-json "--context" context "get" "nodes" "-o" "json"))
         (pods (kubect--kubectl-json "--context" context "--all-namespaces=true" "get" "pods" "-o" "json"))
         (top-output (condition-case nil
                         (kubect--kubectl-output "--context" context "top" "nodes")
                       (error "")))
         (rows (kubect--node-capacity-rows nodes pods top-output))
         (body (concat (kubect--node-capacity-table rows) "\n")))
    (list :type 'plain
          :title "node capacity"
          :header (format "Node capacity: %s | RET node pods | g refresh | t watch | q quit"
                          context)
          :body body
          :context context
          :namespace kubect-all-namespaces-token
          :rows rows
          :node-capacity t
          :refresh-fn (lambda (_state)
                        (kubect--node-capacity-state context)))))

(defun kubect-node-pods (&optional arg)
  "Show pods assigned to the node at point in a capacity report."
  (interactive "P")
  (unless (plist-get kubect-report-state :node-capacity)
    (user-error "Open a node capacity report first"))
  (let* ((node (car (split-string (buffer-substring-no-properties
                                 (line-beginning-position) (line-end-position)))))
         (context (plist-get kubect-report-state :context)))
    (unless (and node (not (member node '("*" "NODE")))
                 (cl-find node (plist-get kubect-report-state :rows)
                          :key (lambda (row) (cdr (assoc "NODE" row))) :test #'equal))
      (user-error "Move point to a node row"))
    (kubect-open context kubect-all-namespaces-token "pods" nil
                 (kubect--display-action-from-prefix arg)
                 (concat "spec.nodeName=" node)
                 (format "node:%s" node))))

(defun kubect-report-visit (&optional arg)
  "Visit a node row or activate a report button."
  (interactive "P")
  (if-let* ((target (or (get-text-property (point) 'kubect-resource-target)
                        (and (> (point) (point-min))
                             (get-text-property (1- (point)) 'kubect-resource-target)))))
      (if (eq (plist-get target :action) 'session)
          (kubect-open (plist-get target :context) (plist-get target :namespace) "pods" nil
                       (kubect--display-action-from-prefix arg))
        (kubect--view-known-resource
         (plist-get target :kind) (plist-get target :name)
         (plist-get target :context) (plist-get target :namespace) arg))
    (if (plist-get kubect-report-state :node-capacity)
        (kubect-node-pods arg)
      (push-button))))

(defun kubect--report-target-at-point ()
  "Return the graph or alert resource target at point, or signal an error."
  (or (get-text-property (point) 'kubect-resource-target)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'kubect-resource-target))
      (user-error "Move point to a resource target")))

(defun kubect-report-target-describe (&optional arg)
  "Describe the resource target at point in a graph or alert report."
  (interactive "P")
  (let ((target (kubect--report-target-at-point)))
    (kubect--show-describe-resource (plist-get target :kind) (plist-get target :name)
                                    (plist-get target :context) (plist-get target :namespace) arg)))

(defun kubect-report-target-events (&optional arg)
  "Open events for the resource target at point."
  (interactive "P")
  (let ((target (kubect--report-target-at-point)))
    (kubect--events-for-resource (plist-get target :kind) (plist-get target :name)
                                  (plist-get target :context) (plist-get target :namespace) arg)))

(defun kubect-report-target-logs (&optional arg)
  "Open logs for a pod target at point."
  (interactive "P")
  (let ((target (kubect--report-target-at-point)))
    (unless (member (kubect--singular-kind (plist-get target :kind)) '("pod" "pods"))
      (user-error "Logs are available only for pod targets"))
    (kubect-logs (plist-get target :name) nil (plist-get target :context)
                 (plist-get target :namespace) (kubect--display-action-from-prefix arg))))

(defun kubect--top-report-render (state)
  "Render a top-oriented report from STATE."
  (let* ((title (plist-get state :title))
         (rows (copy-sequence (plist-get state :rows)))
         (sort-key (plist-get state :sort))
         (header-line (or (plist-get state :header)
                          "Top report"))
         (columns (or (plist-get state :columns)
                      '("NAME" "CPU(cores)" "MEMORY(bytes)"))))
    (when sort-key
      (setq rows
            (sort rows
                  (lambda (left right)
                    (> (kubect--top-number (alist-get sort-key left nil nil #'equal))
                       (kubect--top-number (alist-get sort-key right nil nil #'equal)))))))
    (let ((lines (cons (string-join columns "\t")
                       (mapcar
                        (lambda (row)
                          (string-join
                           (mapcar (lambda (column)
                                     (or (alist-get column row nil nil #'equal) ""))
                                   columns)
                           "\t"))
                        rows))))
      (list :body (concat (format "== %s ==\n\n" title)
                          (string-join lines "\n")
                          "\n")
            :header header-line
            :state (plist-put (copy-sequence state) :rows rows)))))

(defun kubect--parse-top-output (output)
  "Parse kubectl top OUTPUT into column-oriented alists."
  (let* ((lines (split-string output "\n" t))
         (columns (split-string (or (car lines) "") "[[:space:]]+" t)))
    (mapcar
     (lambda (line)
       (let ((values (split-string line "[[:space:]]+" t)))
         (cl-mapcar #'cons columns values)))
     (cdr lines))))

(defun kubect--render-report-state (state)
  "Render the current report from STATE."
  (pcase (plist-get state :type)
    ('top
     (kubect--top-report-render state))
    (_
     (list :body (or (plist-get state :body) "")
           :header (plist-get state :header)
           :state state))))

(defun kubect-report-refresh ()
  "Refresh the current kubect report buffer when it has a generator."
  (interactive)
  (unless kubect-report-state
    (user-error "Current buffer is not a kubect report"))
  (let* ((refresh-fn (plist-get kubect-report-state :refresh-fn))
         (state (if refresh-fn
                    (funcall refresh-fn kubect-report-state)
                  kubect-report-state))
         (rendered (kubect--render-report-state state)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (plist-get rendered :body))
      (goto-char (point-min)))
    (setq-local header-line-format (plist-get rendered :header))
    (setq-local kubect-report-state (plist-get rendered :state))
    (when (fboundp 'font-lock-ensure)
      (font-lock-ensure))
    (kubect--report-style-buffer)))

(defun kubect--report-watch-refresh (buffer)
  "Refresh BUFFER when it is a live watchable kubect report."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and kubect--report-watch-timer
                 (plist-get kubect-report-state :refresh-fn))
        (ignore-errors
          (kubect-report-refresh))))))

(defun kubect-report-toggle-watch ()
  "Toggle automatic refresh for the current kubect report buffer."
  (interactive)
  (unless (plist-get kubect-report-state :refresh-fn)
    (user-error "Current report is not watchable"))
  (if (timerp kubect--report-watch-timer)
      (progn
        (cancel-timer kubect--report-watch-timer)
        (setq kubect--report-watch-timer nil)
        (message "Kubect report watch disabled"))
    (setq kubect--report-watch-timer
          (run-at-time kubect-watch-interval
                       kubect-watch-interval
                       #'kubect--report-watch-refresh
                       (current-buffer)))
    (message "Kubect report watch enabled (%ss)" kubect-watch-interval)))

(defun kubect-report-sort-top-by-cpu ()
  "Sort the current top report by CPU usage."
  (interactive)
  (unless (eq (plist-get kubect-report-state :type) 'top)
    (user-error "Current report is not a top report"))
  (setf (plist-get kubect-report-state :sort) "CPU(cores)")
  (kubect-report-refresh))

(defun kubect-report-sort-top-by-memory ()
  "Sort the current top report by memory usage."
  (interactive)
  (unless (eq (plist-get kubect-report-state :type) 'top)
    (user-error "Current report is not a top report"))
  (setf (plist-get kubect-report-state :sort) "MEMORY(bytes)")
  (kubect-report-refresh))

(defun kubect--report-urls ()
  "Return URL list stored for the current report buffer."
  (or (plist-get kubect-report-state :urls)
      (user-error "This report buffer does not expose URL actions")))

(defun kubect--report-url-at-point ()
  "Return the URL at point when it matches the report URL list."
  (let* ((line (string-trim (buffer-substring-no-properties
                             (line-beginning-position)
                             (line-end-position))))
         (urls (kubect--report-urls)))
    (when (member line urls)
      line)))

(defun kubect--read-report-url (prompt)
  "Read a URL from the current report buffer with PROMPT."
  (let* ((urls (kubect--report-urls))
         (default (or (kubect--report-url-at-point)
                      (car urls))))
    (if (or (= (length urls) 1)
            (kubect--report-url-at-point))
        default
      (kubect--completing-read prompt urls default))))

(defun kubect-report-open-url ()
  "Open one URL from the current report buffer."
  (interactive)
  (let ((url (kubect--read-report-url "Open URL: ")))
    (browse-url url)
    (message "Opened %s" url)))

(defun kubect-report-open-all-urls ()
  "Open all URLs from the current report buffer."
  (interactive)
  (let ((urls (kubect--report-urls)))
    (mapc #'browse-url urls)
    (message "Opened %d URL%s" (length urls) (if (= (length urls) 1) "" "s"))))

(defun kubect-report-copy-url ()
  "Copy one URL from the current report buffer."
  (interactive)
  (let ((url (kubect--read-report-url "Copy URL: ")))
    (kill-new url)
    (message "Copied %s" url)))

(defun kubect-report-copy-all-urls ()
  "Copy all URLs from the current report buffer."
  (interactive)
  (let ((urls (kubect--report-urls)))
    (kill-new (string-join urls "\n"))
    (message "Copied %d URL%s" (length urls) (if (= (length urls) 1) "" "s"))))

(defun kubect--top-pods-state (&optional namespace context)
  "Return report STATE for a top pods view in NAMESPACE."
  (let* ((context (or context (kubect-current-context)))
         (namespace (or namespace (kubect-current-namespace)))
         (output (apply #'kubect--kubectl-output
                        (append (kubect--kubectl-base-args context namespace)
                                '("top" "pods")))))
    (list :type 'top
          :title (if (equal namespace kubect-all-namespaces-token)
                     "top pods all namespaces"
                   "top pods")
          :header (if (equal namespace kubect-all-namespaces-token)
                      (format "Top pods: %s all namespaces | g refresh | t watch | c cpu | m memory"
                              context)
                    (format "Top pods: %s/%s | g refresh | t watch | c cpu | m memory"
                            context namespace))
          :context context
          :namespace namespace
          :columns (split-string (car (split-string output "\n" t)) "[[:space:]]+" t)
          :rows (kubect--parse-top-output output)
          :sort "CPU(cores)"
          :refresh-fn (lambda (state)
                        (let ((fresh (kubect--top-pods-state (plist-get state :namespace) context)))
                          (plist-put fresh :sort (plist-get state :sort)))))))

(defun kubect--show-rendered-report (state &optional arg)
  "Render STATE into a kubect report buffer."
  (let* ((rendered (kubect--render-report-state state))
         (context (plist-get state :context))
         (namespace (plist-get state :namespace)))
    (kubect--show-report-buffer
     (plist-get state :title)
     (plist-get rendered :body)
     context namespace arg
     (plist-get rendered :header)
     (plist-get rendered :state))))

(defun kubect-top-pods (&optional arg)
  "Show `kubectl top pods' for the current namespace."
  (interactive "P")
  (let ((state (kubect--top-pods-state)))
    (kubect--record-session-command "top-pods" (plist-get state :namespace))
    (kubect--show-rendered-report state arg)))

(defun kubect-top-nodes (&optional arg)
  "Show a kube-capacity-like node utilization report."
  (interactive "P")
  (let ((state (kubect--node-capacity-state)))
    (kubect--record-session-command "top-nodes" (plist-get state :context))
    (kubect--show-rendered-report state arg)))

(defun kubect-top-resource (&optional arg)
  "Show `kubectl top' for the resource at point or a resolved pod."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist)))
    (when (member kind '("events" "event"))
      (if-let* ((object (kubect--event-object-at-point)))
          (pcase-let* ((`(,object-kind ,object-name)
                        (split-string object "/" t)))
            (setq kind (downcase object-kind)
                  name object-name))
        (user-error "Could not determine the involved object for this event")))
    (let ((singular (kubect--singular-kind kind)))
      (cond
       ((member singular '("pod" "pods"))
      (kubect--record-session-command "top" (format "pod/%s" name))
      (kubect--show-report-buffer
       (format "top pod %s" name)
       (concat
        (kubect--kubectl-output
         "--context" context
         "--namespace" namespace
         "top" "pod" name "--containers=true")
        "\n")
       context namespace arg
       (format "Top pod: %s/%s" context namespace)))
       ((string= singular "node")
      (kubect--record-session-command "top" (format "node/%s" name))
      (kubect--show-report-buffer
       (format "top node %s" name)
       (concat
        (kubect--kubectl-output
         "--context" context
         "top" "node" name)
        "\n")
       context namespace arg
       (format "Top node: %s" context)))
       (t
        (let ((pod (or (kubect--pod-for-resource kind name context namespace)
                       (kubect--read-pod context namespace))))
          (kubect--record-session-command "top" (format "pod/%s" pod))
          (kubect--show-report-buffer
           (format "top pod %s" pod)
           (concat
            (kubect--kubectl-output
             "--context" context
             "--namespace" namespace
             "top" "pod" pod "--containers=true")
            "\n")
           context namespace arg
           (format "Top pod: %s/%s" context namespace))))))))

(defun kubect--show-bulk-top-summary (resources &optional arg)
  "Show a consolidated `kubectl top` summary for RESOURCES."
  (let* ((first (car resources))
         (context (plist-get first :context))
         (namespace (plist-get first :namespace))
         (buffer (get-buffer-create
                  (kubect--compilation-buffer-name "bulk top summary" context namespace))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (resource resources)
          (pcase-let* ((`(:kind ,kind :name ,name :context ,ctx :namespace ,ns) resource)
                       (pod (or (and (member (kubect--singular-kind kind) '("pod" "pods")) name)
                                (kubect--pod-for-resource kind name ctx ns))))
            (insert (format "== %s ==\n\n" (kubect--bulk-resource-label resource)))
            (if pod
                (insert
                 (kubect--kubectl-output
                  "--context" ctx
                  "--namespace" ns
                  "top" "pod" pod "--containers=true")
                 "\n")
              (insert "No pod could be resolved for this resource\n"))
            (insert "\n")))
        (goto-char (point-min)))
      (kubect-report-mode))
    (let ((kubect--display-buffer-action-override
           (kubect--display-action-from-prefix arg)))
      (kubect--display-buffer buffer))))

(provide 'kubect-reports)
;;; kubect-reports.el ends here
