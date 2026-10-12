;;; kubect-browser.el --- Kubect browser -*- lexical-binding: t; -*-

(require 'kubect-core)

(defun kubect--session-name (context namespace resource)
  "Return a default session name for CONTEXT, NAMESPACE, and RESOURCE."
  (format "%s/%s/%s" context namespace resource))

(defun kubect--session-buffer-name (session)
  "Return the session buffer name for SESSION."
  (format "*kubect session: |%s|%s|%s|*"
          (kubect-session-context session)
          (kubect-session-namespace session)
          (concat (kubect-session-resource session)
                  (if-let* ((label (kubect-session-scope-label session)))
                      (format " [%s]" label)
                    ""))))

(defun kubect--register-session (session)
  "Register SESSION in the global session list."
  (setq kubect--sessions
        (cons session
              (cl-remove-if
               (lambda (other)
                 (equal (kubect-session-buffer session)
                        (kubect-session-buffer other)))
               kubect--sessions)))
  session)

(defun kubect--session-filter-regexp (session)
  "Return a line-matching regexp for SESSION, or nil when no filter is active."
  (when-let* ((filter (kubect-session-filter session))
              ((not (string-empty-p filter))))
    (if (eq (kubect-session-filter-mode session) 'regexp)
        filter
      (regexp-quote filter))))

(defun kubect--session-filter-description (session)
  "Return a readable filter description for SESSION."
  (let ((descriptions nil))
    (when-let* ((filter (kubect-session-filter session))
                ((not (string-empty-p filter))))
      (push (if-let* ((label (kubect-session-filter-label session)))
                (format "preset=%s" label)
              (format "filter=%s" filter))
            descriptions))
    (when-let* ((column (kubect-session-column-filter-column session))
                (pattern (kubect-session-column-filter-pattern session)))
      (push (format "%s~%s" column pattern) descriptions))
    (string-join (nreverse descriptions) "  ")))

(defun kubect--session-filter-match-p (session line)
  "Return non-nil when LINE matches SESSION's active filter."
  (if-let* ((regexp (kubect--session-filter-regexp session)))
      (string-match-p regexp line)
    t))

(defun kubect--table-columns (line)
  "Return columns from a kubectl table LINE.
Kubectl separates table fields with at least two spaces, while individual
field values can legitimately contain one space."
  (split-string (string-trim line) "[[:space:]][[:space:]]+" t))

(defun kubect--session-row-matches-p (session header row)
  "Return non-nil when ROW satisfies SESSION filters for HEADER."
  (and (kubect--session-filter-match-p session row)
       (let ((column (kubect-session-column-filter-column session))
             (pattern (kubect-session-column-filter-pattern session)))
         (or (not (and column pattern))
             (let* ((columns (kubect--table-columns header))
                    (index (cl-position column columns :test #'string-equal))
                    (value (and index (nth index (kubect--table-columns row)))))
               (and value
                    (let ((case-fold-search t))
                      (string-match-p (regexp-quote pattern) value))))))))

(defun kubect--apply-session-filter (session filter &optional mode label)
  "Apply FILTER to SESSION using MODE and optional LABEL."
  (let ((empty (string-empty-p (or filter ""))))
    (setf (kubect-session-filter session) (unless empty filter)
          (kubect-session-filter-mode session) (unless empty (or mode 'substring))
          (kubect-session-filter-label session) (unless empty label))))

(defun kubect--session-sort-description (session)
  "Return a readable sort description for SESSION."
  (when-let* ((label (kubect-session-sort-label session)))
    (format "sort=%s%s"
            label
            (if (kubect-session-sort-descending session) " desc" " asc")
            )))

(defun kubect--apply-session-sort (session label column parser descending)
  "Apply sort settings to SESSION."
  (setf (kubect-session-sort-label session) label
        (kubect-session-sort-column session) column
        (kubect-session-sort-parser session) parser
        (kubect-session-sort-descending session) descending))

(defun kubect--apply-session-sort-preset (session name &optional source)
  "Apply named sort preset NAME to SESSION.
SOURCE identifies where the sort came from, such as `manual' or `auto'."
  (let* ((spec (kubect--sort-preset-spec name))
         (column (plist-get spec :column))
         (parser (or (plist-get spec :parser) 'string))
         (descending (and (plist-get spec :descending) t)))
    (unless column
      (user-error "Unknown kubect sort preset: %s" name))
    (kubect--apply-session-sort session name column parser descending)
    (setf (kubect-session-sort-source session) source)))

(defun kubect--clear-session-sort (session)
  "Clear sort settings from SESSION."
  (setf (kubect-session-sort-label session) nil
        (kubect-session-sort-column session) nil
        (kubect-session-sort-parser session) nil
        (kubect-session-sort-descending session) nil
        (kubect-session-sort-source session) nil))

(defun kubect--session-candidates ()
  "Return display candidates for active sessions."
  (mapcar (lambda (session)
            (cons (format "%s  [%s]"
                          (kubect-session-name session)
                          (or (kubect-session-project-root session) "no project"))
                  session))
          (cl-remove-if-not
           (lambda (session)
             (buffer-live-p (kubect-session-buffer session)))
           kubect--sessions)))

(defun kubect--session-at-point ()
  "Return the session associated with the current buffer."
  (or kubect-session
      (user-error "Current buffer is not a kubect session")))

(defun kubect--current-session ()
  "Return the current kubect session, if any."
  (and (boundp 'kubect-session) kubect-session))

(defun kubect--current-history-session ()
  "Return the kubect session that should own history for this buffer."
  (or (kubect--current-session)
      (plist-get kubect-file-browser-state :session)
      (plist-get kubect--remote-file-target :session)))

(defun kubect--session-values (slot session)
  "Return SLOT values from SESSION."
  (pcase slot
    (:recent-pods (kubect-session-recent-pods session))
    (:recent-containers (kubect-session-recent-containers session))
    (:command-history (kubect-session-command-history session))
    (:event-objects (kubect-session-event-objects session))
    (:marked-resources (kubect-session-marked-resources session))
    (_ nil)))

(defun kubect--set-session-values (slot session values)
  "Set SLOT on SESSION to VALUES."
  (pcase slot
    (:recent-pods (setf (kubect-session-recent-pods session) values))
    (:recent-containers (setf (kubect-session-recent-containers session) values))
    (:command-history (setf (kubect-session-command-history session) values))
    (:event-objects (setf (kubect-session-event-objects session) values))
    (:marked-resources (setf (kubect-session-marked-resources session) values))))

(defun kubect--session-remember (slot value)
  "Remember VALUE in current session SLOT."
  (when-let* ((session (kubect--current-session))
              (value value))
    (let* ((existing (copy-sequence (or (kubect--session-values slot session) '())))
           (updated (cons value (delete value existing))))
      (kubect--set-session-values
       slot session (cl-subseq updated 0 (min 20 (length updated)))))))

(defun kubect--record-session-command (command &optional detail)
  "Append COMMAND and DETAIL to the current session history."
  (when-let* ((session (kubect--current-history-session)))
    (let* ((entry (string-trim (format "%s%s" command (if detail (format " %s" detail) ""))))
           (existing (copy-sequence (or (kubect-session-command-history session) '()))))
      (setf (kubect-session-command-history session)
            (cl-subseq (cons entry existing) 0 (min 30 (1+ (length existing))))))))

(defun kubect-switch-session (&optional arg)
  "Switch to an existing kubect session buffer."
  (interactive "P")
  (let* ((candidates (kubect--session-candidates))
         (session
          (cdr (assoc (kubect--completing-read
                       "Session: "
                       (mapcar #'car candidates))
                      candidates))))
    (unless session
      (user-error "No kubect sessions are active"))
    (with-current-buffer (kubect-session-buffer session)
      (kubect--record-session-command "switch-session"))
    (let ((kubect--display-buffer-action-override
           (kubect--display-action-from-prefix arg)))
      (kubect--display-buffer (kubect-session-buffer session)))))

(defun kubect--table-output-with-event-objects (session)
  "Return SESSION output and visible event objects as a plist.
The plist contains :output and :event-objects."
  (let* ((context (kubect-session-context session))
         (namespace (kubect-session-namespace session))
         (filter (kubect-session-filter session))
         (output (apply #'kubect--kubectl-output
                        (append (kubect--kubectl-base-args context namespace)
                                '("get" "events" "--sort-by=.lastTimestamp"))))
         (objects (kubect--event-objects-for-session session)))
    (if (and (string-empty-p (or filter ""))
             (not (kubect-session-column-filter-column session)))
        (list :output output :event-objects objects)
      (let* ((lines (split-string output "\n"))
             (header (car lines))
             (rows (cdr lines))
             (visible-rows nil)
             (visible-objects nil))
        (cl-mapc
         (lambda (row object)
           (when (kubect--session-row-matches-p session header row)
             (push row visible-rows)
             (push object visible-objects)))
         rows
         objects)
        (list :output (string-join (cons header (nreverse visible-rows)) "\n")
              :event-objects (nreverse visible-objects))))))

(defun kubect--table-output (session)
  "Return raw `kubectl get` table output for SESSION."
  (let* ((context (kubect-session-context session))
         (namespace (kubect-session-namespace session))
         (resource (kubect-session-resource session))
         (field-selector (kubect-session-field-selector session))
         (filter (kubect-session-filter session)))
    (if (string= resource "events")
        (pcase-let* ((`(:output ,output :event-objects ,event-objects)
                      (kubect--table-output-with-event-objects session)))
          (setf (kubect-session-event-objects session) event-objects)
          output)
      (let ((output
             (apply #'kubect--kubectl-output
                    (append (kubect--kubectl-base-args context namespace)
                            (list "get" resource)
                            (when field-selector
                              (list "--field-selector" field-selector))
                            (when (kubect-session-wide session)
                              (list "-o" "wide"))))))
        (kubect--sort-table-output
         session
        (if (and (string-empty-p (or filter ""))
                 (not (kubect-session-column-filter-column session)))
             output
           (let* ((lines (split-string output "\n"))
                  (header (car lines))
                  (rows (cdr lines))
                  (matched
                   (cl-remove-if-not
                    (lambda (line)
                      (kubect--session-row-matches-p session header line))
                    rows)))
             (string-join (cons header matched) "\n"))))))))

(defun kubect--event-objects-for-session (session)
  "Return involved object identifiers for events in SESSION order."
  (let* ((context (kubect-session-context session))
         (namespace (kubect-session-namespace session))
         (data (apply #'kubect--kubectl-json
                      (append (kubect--kubectl-base-args context namespace)
                              '("get" "events" "--sort-by=.lastTimestamp" "-o" "json"))))
         (items (alist-get 'items data)))
    (mapcar
     (lambda (item)
       (let ((obj (alist-get 'involvedObject item)))
         (format "%s/%s"
                 (alist-get 'kind obj)
                 (alist-get 'name obj))))
     items)))

(defun kubect-watching-p ()
  "Return non-nil when the current kubect session buffer is auto-refreshing."
  (and (timerp kubect--watch-timer)
       (memq kubect--watch-timer timer-list)))

(defun kubect--watch-refresh (buffer)
  "Refresh BUFFER when it still hosts a live kubect session."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (derived-mode-p 'kubect-session-mode)
                 (kubect-watching-p))
        (ignore-errors
          (kubect-refresh))))))

(defun kubect-start-watch (&optional interval)
  "Start automatic refresh for the current kubect session buffer.
Optional INTERVAL overrides `kubect-watch-interval'."
  (interactive)
  (unless (derived-mode-p 'kubect-session-mode)
    (user-error "Current buffer is not a kubect session"))
  (kubect-stop-watch)
  (setq kubect--watch-timer
        (run-at-time (or interval kubect-watch-interval)
                     (or interval kubect-watch-interval)
                     #'kubect--watch-refresh
                     (current-buffer)))
  (force-mode-line-update)
  (when (called-interactively-p 'interactive)
    (message "Kubect watch enabled (%ss)" (or interval kubect-watch-interval))))

(defun kubect-toggle-watch ()
  "Toggle automatic refresh for the current kubect session buffer."
  (interactive)
  (if (kubect-watching-p)
      (kubect-stop-watch)
    (kubect-start-watch)))

(defun kubect-refresh ()
  "Refresh the current kubect session."
  (interactive)
  (let* ((session (kubect--session-at-point))
         (current-name (ignore-errors (kubect--resource-name-at-point)))
         (output (kubect--table-output session)))
    (setq header-line-format
          (format " kubect%s  %s  ns=%s  resource=%s%s%s%s%s%s"
                  (if (kubect-watching-p)
                      (format " [watch %ss]" kubect-watch-interval)
                    "")
                  (kubect-session-context session)
                  (kubect-session-namespace session)
                  (kubect-session-resource session)
                  (if-let* ((label (kubect-session-scope-label session)))
                      (format "  %s" label)
                    "")
                  (if (kubect-session-wide session) " wide" "")
                  (if-let* ((sort (kubect--session-sort-description session)))
                      (format "  %s" sort)
                    "")
                  (if-let* ((description (kubect--session-filter-description session)))
                      (format "  %s" description)
                    "")
                  (if (equal (kubect-session-namespace session) kubect-all-namespaces-token)
                      "  all-namespaces"
                    "")))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert output)
      (kubect--session-apply-highlights)
      (goto-char (point-min))
      (forward-line 1)
      (when current-name
        (goto-char (point-min))
        (when (re-search-forward
               (format "^%s\\(?:[[:space:]]\\|$\\)" (regexp-quote current-name))
               nil t)
          (beginning-of-line))))))

(defun kubect--session-line-face (line)
  "Return a face for LINE when it indicates an unhealthy state."
  (cond
   ((string-match-p
     (rx (or "CrashLoopBackOff" "ImagePullBackOff" "ErrImagePull" "OOMKilled"
             "CreateContainerConfigError" "CreateContainerError"
             "RunContainerError" "Error" "Failed"))
     line)
    'kubect-critical-face)
   ((string-match-p
     (rx (or "Pending" "ContainerCreating" "Terminating" "BackOff" "Warning"))
     line)
    'kubect-warning-face)))

(defun kubect--current-session-line ()
  "Return the current session row text."
  (string-trim-right
   (buffer-substring-no-properties
    (line-beginning-position)
    (line-end-position))))

(defun kubect--clear-session-overlays ()
  "Remove kubect row overlays from the current session buffer."
  (remove-overlays (point-min) (point-max) 'kubect-row-overlay t))

(defun kubect--session-apply-highlights ()
  "Apply lightweight health highlighting to the current session buffer."
  (kubect--clear-session-overlays)
  (save-excursion
    (let* ((session (kubect--session-at-point))
           (marks (kubect-session-marked-resources session)))
    (goto-char (point-min))
    (forward-line 1)
    (while (not (eobp))
      (let* ((start (line-beginning-position))
             (end (line-end-position))
             (line (buffer-substring-no-properties start end))
             (faces (delq nil
                          (list (kubect--session-line-face line)
                                (when (and marks
                                           (member (car (ignore-errors (kubect--resource-identifiers-at-point)))
                                                   marks))
                                  'kubect-mark-face))))
             (face (kubect--line-overlay-face faces)))
        (when face
          (let ((ov (make-overlay start end)))
            (overlay-put ov 'kubect-row-overlay t)
            (overlay-put ov 'face face))))
      (forward-line 1)))))

(defun kubect--visible-session-resources ()
  "Return resource plists for visible rows in the current session buffer."
  (unless (derived-mode-p 'kubect-session-mode)
    (user-error "Current buffer is not a kubect session"))
  (let (resources)
    (save-excursion
      (goto-char (point-min))
      (forward-line 1)
      (while (not (eobp))
        (condition-case nil
            (push (kubect--current-line-resource-plist) resources)
          (error nil))
        (forward-line 1)))
    (nreverse resources)))

(defun kubect--resource-plist-from-session (&optional kind name)
  "Return a resource plist using current session KIND and NAME."
  (let ((session (kubect--session-at-point)))
    (list :kind (or kind (kubect-session-resource session))
          :name (or name (kubect--resource-name-at-point))
          :context (kubect-session-context session)
          :namespace (kubect--namespace-at-point))))

(defun kubect-watch-events (&optional arg)
  "Open a live event watch stream for the current namespace."
  (interactive "P")
  (let ((context (kubect-current-context))
        (namespace (kubect-current-namespace)))
    (kubect--record-session-command "watch-events" namespace)
    (let ((kubect--display-buffer-action-override
           (kubect--display-action-from-prefix arg)))
      (kubect--start-stream
       "events watch"
       (append (kubect--kubectl-base-args context namespace)
               (list "get" "events" "--watch"))
       context namespace
       (list :mode 'events-watch
             :context context
             :namespace namespace)))))

(defun kubect-watch-events-for-resource (&optional arg)
  "Open a live event watch stream for the resource at point."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--resource-for-command))
               (selector (kubect--event-field-selector kind name)))
    (kubect--record-session-command "watch-events-for" (format "%s/%s" kind name))
    (let ((kubect--display-buffer-action-override
           (kubect--display-action-from-prefix arg)))
      (kubect--start-stream
       (format "events watch %s" name)
       (append (kubect--kubectl-base-args context namespace)
               (list "get" "events" "--watch"
                     (format "--field-selector=%s" selector)))
       context namespace
       (list :mode 'events-watch
             :context context
             :namespace namespace
             :kind kind
             :name name)))))

(defun kubect-session-mark ()
  "Mark the resource represented by the current session row."
  (interactive)
  (let* ((session (kubect--session-at-point))
         (identifier (car (kubect--resource-identifiers-at-point))))
    (setf (kubect-session-marked-resources session)
          (delete-dups (cons identifier (kubect-session-marked-resources session))))
    (kubect--record-session-command "mark" identifier)
    (kubect--session-apply-highlights)
    (message "Marked %s" identifier)))

(defun kubect-session-unmark ()
  "Remove the mark from the current session row."
  (interactive)
  (let* ((session (kubect--session-at-point))
         (identifier (car (kubect--resource-identifiers-at-point))))
    (setf (kubect-session-marked-resources session)
          (delete identifier (copy-sequence (kubect-session-marked-resources session))))
    (kubect--record-session-command "unmark" identifier)
    (kubect--session-apply-highlights)
    (message "Unmarked %s" identifier)))

(defun kubect-session-clear-marks ()
  "Clear all marks from the current session."
  (interactive)
  (let ((session (kubect--session-at-point)))
    (setf (kubect-session-marked-resources session) nil)
    (kubect--record-session-command "clear-marks")
    (kubect--session-apply-highlights)
    (message "Cleared kubect marks")))

(defun kubect-session-bulk-action (action &optional arg)
  "Run ACTION across marked resources in the current session."
  (interactive
   (list
    (kubect--completing-read
     "Bulk action: "
     '("describe" "events" "event-summary" "top-summary" "logs"
       "log-snapshot" "log-snapshot-errors" "log-snapshot-warnings"
       "log-snapshot-previous" "log-snapshot-all-containers"
       "log-snapshot-restart-window"
       "log-snapshot-last-5m" "log-snapshot-last-15m"
       "log-snapshot-last-1h" "log-snapshot-since-rollout"
       "debug" "rollout-status"))
    current-prefix-arg))
  (let* ((session (kubect--session-at-point))
         (resources (kubect--marked-resource-plists session)))
    (unless resources
      (user-error "No marked resources in this session"))
    (kubect--record-session-command "bulk" action)
    (pcase action
      ("describe"
       (let* ((first (car resources))
              (context (plist-get first :context))
              (namespace (plist-get first :namespace))
              (buffer-name (kubect--compilation-buffer-name "bulk describe" context namespace))
              (buffer (get-buffer-create buffer-name)))
         (with-current-buffer buffer
           (let ((inhibit-read-only t))
             (erase-buffer)
             (dolist (resource resources)
               (pcase-let* ((`(:kind ,kind :name ,name :context ,resource-context :namespace ,resource-namespace) resource)
                            (identifier (format "%s/%s" kind name))
                            (output (kubect--kubectl-output
                                     "--context" resource-context
                                     "--namespace" resource-namespace
                                     "describe" kind name)))
                 (insert (format "== %s ==\n\n%s\n\n" identifier output))))
             (goto-char (point-min)))
           (kubect-report-mode))
         (let ((kubect--display-buffer-action-override
                (kubect--display-action-from-prefix arg)))
           (kubect--display-buffer buffer))))
      ("event-summary"
       (kubect--show-bulk-event-summary resources arg))
      ("top-summary"
       (kubect--show-bulk-top-summary resources arg))
      ((or "events" "logs" "debug")
       (kubect--show-bulk-review action resources arg))
      ("log-snapshot"
       (kubect--show-bulk-log-snapshot resources arg))
      ("log-snapshot-errors"
       (kubect--show-bulk-log-snapshot
        resources arg
        '(:title "bulk log snapshot errors"
          :regexp "\\b\\(ERROR\\|FATAL\\|Error\\|panic\\|exception\\)\\b")))
      ("log-snapshot-warnings"
       (kubect--show-bulk-log-snapshot
        resources arg
        '(:title "bulk log snapshot warnings"
          :regexp "\\b\\(WARN\\|Warning\\|warning\\)\\b")))
      ("log-snapshot-previous"
       (kubect--show-bulk-log-snapshot
        resources arg
        '(:title "bulk previous log snapshot"
          :previous t)))
      ("log-snapshot-all-containers"
       (kubect--show-bulk-log-snapshot
        resources arg
        '(:title "bulk all-container log snapshot"
          :all-containers t)))
      ("log-snapshot-restart-window"
       (kubect--show-bulk-log-snapshot
        resources arg
        '(:title "bulk restart-window log snapshot"
          :restart-window t)))
      ("log-snapshot-last-5m"
       (kubect--show-bulk-log-snapshot
        resources arg
        '(:title "bulk last 5m log snapshot"
          :since "5m")))
      ("log-snapshot-last-15m"
       (kubect--show-bulk-log-snapshot
        resources arg
        '(:title "bulk last 15m log snapshot"
          :since "15m")))
      ("log-snapshot-last-1h"
       (kubect--show-bulk-log-snapshot
        resources arg
        '(:title "bulk last 1h log snapshot"
          :since "1h")))
      ("log-snapshot-since-rollout"
       (kubect--show-bulk-log-snapshot
        resources arg
        '(:title "bulk since rollout log snapshot"
          :since-rollout t)))
      ("rollout-status"
       (let* ((rollout-resources
               (cl-remove-if-not
                (lambda (resource)
                  (kubect--rollout-resource-p (plist-get resource :kind)))
                resources)))
         (unless rollout-resources
           (user-error "No marked rollout-capable resources"))
         (let* ((first (car rollout-resources))
                (context (plist-get first :context))
                (namespace (plist-get first :namespace))
                (buffer-name (kubect--compilation-buffer-name "bulk rollout status" context namespace))
                (buffer (get-buffer-create buffer-name)))
           (with-current-buffer buffer
             (let ((inhibit-read-only t))
               (erase-buffer)
               (dolist (resource rollout-resources)
                 (pcase-let* ((`(:kind ,kind :name ,name :context ,resource-context :namespace ,resource-namespace) resource)
                              (identifier (format "%s/%s" kind name))
                              (output (kubect--kubectl-output
                                       "--context" resource-context
                                       "--namespace" resource-namespace
                                       "rollout" "status" (format "%s/%s" kind name))))
                   (insert (format "== %s ==\n\n%s\n\n" identifier output))))
               (goto-char (point-min)))
             (kubect-report-mode))
           (let ((kubect--display-buffer-action-override
                  (kubect--display-action-from-prefix arg)))
             (kubect--display-buffer buffer))))))))

(defun kubect-session-history ()
  "Show recent session commands and selections."
  (interactive)
  (let* ((session (kubect--session-at-point))
         (buffer (get-buffer-create
                  (format "*kubect history %s*" (kubect-session-name session)))))
    (with-current-buffer buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Session: %s\n\n" (kubect-session-name session)))
        (insert "Recent commands:\n")
        (if-let* ((commands (kubect-session-command-history session)))
            (dolist (entry commands)
              (insert (format "- %s\n" entry)))
          (insert "- none yet\n"))
        (insert "\nRecent pods:\n")
        (if-let* ((pods (kubect-session-recent-pods session)))
            (dolist (pod pods)
              (insert (format "- %s\n" pod)))
          (insert "- none yet\n"))
        (insert "\nRecent containers:\n")
        (if-let* ((containers (kubect-session-recent-containers session)))
            (dolist (container containers)
              (insert (format "- %s\n" container)))
          (insert "- none yet\n"))
        (goto-char (point-min))))
    (with-current-buffer (kubect-session-buffer session)
      (kubect--record-session-command "history"))
    (kubect--display-buffer buffer)))

(defun kubect--session-live-p (session)
  "Return non-nil when SESSION has a live buffer."
  (buffer-live-p (kubect-session-buffer session)))

(defun kubect--session-persistable-plist (session)
  "Return a plist representing SESSION for persistence."
  (list :context (kubect-session-context session)
        :namespace (kubect-session-namespace session)
        :resource (kubect-session-resource session)
        :field-selector (kubect-session-field-selector session)
        :scope-label (kubect-session-scope-label session)
        :filter (kubect-session-filter session)
        :filter-mode (kubect-session-filter-mode session)
        :filter-label (kubect-session-filter-label session)
        :column-filter-column (kubect-session-column-filter-column session)
        :column-filter-pattern (kubect-session-column-filter-pattern session)
        :sort-label (kubect-session-sort-label session)
        :sort-column (kubect-session-sort-column session)
        :sort-parser (kubect-session-sort-parser session)
        :sort-descending (kubect-session-sort-descending session)
        :sort-source (kubect-session-sort-source session)
        :project-root (kubect-session-project-root session)
        :wide (kubect-session-wide session)
        :recent-pods (kubect-session-recent-pods session)
        :recent-containers (kubect-session-recent-containers session)
        :command-history (kubect-session-command-history session)
        :marked-resources (kubect-session-marked-resources session)))

(defun kubect-save-sessions ()
  "Persist current kubect sessions to `kubect-session-persist-file'."
  (interactive)
  (when (and kubect-persist-sessions
             (not noninteractive))
    (let ((sessions (mapcar #'kubect--session-persistable-plist
                            (cl-remove-if-not #'kubect--session-live-p kubect--sessions))))
      (make-directory (file-name-directory kubect-session-persist-file) t)
      (with-temp-file kubect-session-persist-file
        (let ((print-length nil)
              (print-level nil))
          (prin1 sessions (current-buffer)))))))

(defun kubect-restore-sessions ()
  "Restore kubect sessions from `kubect-session-persist-file'."
  (interactive)
  (unless kubect--sessions-restored
    (setq kubect--sessions-restored t)
    (when (and kubect-persist-sessions
               (not noninteractive)
               (file-exists-p kubect-session-persist-file))
      (condition-case err
          (let ((sessions (with-temp-buffer
                            (insert-file-contents kubect-session-persist-file)
                            (read (current-buffer)))))
            (dolist (spec sessions)
              (let ((default-directory (or (plist-get spec :project-root) default-directory)))
                (let ((session (kubect-open (plist-get spec :context)
                                            (plist-get spec :namespace)
                                            (plist-get spec :resource)
                                            (plist-get spec :filter)
                                            'silent
                                            (plist-get spec :field-selector)
                                            (plist-get spec :scope-label))))
                  (setf (kubect-session-project-root session) (plist-get spec :project-root)
                        (kubect-session-filter-mode session) (plist-get spec :filter-mode)
                        (kubect-session-filter-label session) (plist-get spec :filter-label)
                        (kubect-session-column-filter-column session) (plist-get spec :column-filter-column)
                        (kubect-session-column-filter-pattern session) (plist-get spec :column-filter-pattern)
                        (kubect-session-sort-label session) (plist-get spec :sort-label)
                        (kubect-session-sort-column session) (plist-get spec :sort-column)
                        (kubect-session-sort-parser session) (plist-get spec :sort-parser)
                        (kubect-session-sort-descending session) (plist-get spec :sort-descending)
                        (kubect-session-sort-source session) (plist-get spec :sort-source)
                        (kubect-session-wide session) (and (plist-get spec :wide) t)
                        (kubect-session-recent-pods session) (plist-get spec :recent-pods)
                        (kubect-session-recent-containers session) (plist-get spec :recent-containers)
                        (kubect-session-command-history session) (plist-get spec :command-history)
                        (kubect-session-marked-resources session) (plist-get spec :marked-resources))
                  (with-current-buffer (kubect-session-buffer session)
                    (kubect-refresh))))))
        (error
         (message "kubect: could not restore sessions: %s" (error-message-string err)))))))

(defun kubect--maybe-restore-sessions ()
  "Restore kubect sessions once when appropriate."
  (when (and kubect-persist-sessions
             (not kubect--sessions-restored)
             (not noninteractive))
    (kubect-restore-sessions)))

(defun kubect-session-toggle-wide ()
  "Toggle wide output for the current session."
  (interactive)
  (let ((session (kubect--session-at-point)))
    (setf (kubect-session-wide session)
          (not (kubect-session-wide session)))
    (kubect--record-session-command
     "wide"
     (if (kubect-session-wide session) "enabled" "disabled"))
    (kubect-refresh)
    (message "Kubect wide view %s"
             (if (kubect-session-wide session) "enabled" "disabled"))))

(defun kubect-session-set-context ()
  "Change the session context."
  (interactive)
  (let* ((session (kubect--session-at-point))
         (context (kubect--completing-read "Context: " (kubect--list-contexts))))
    (kubect--session-change-scope context
                                  (kubect-session-namespace session)
                                  (kubect-session-resource session) "context" context)))

(defun kubect--session-change-scope (context namespace resource command detail)
  "Set session scope and record COMMAND with DETAIL, then refresh.
Invalidate marks and pending work before exposing resources in the new scope."
  (let ((session (kubect--session-at-point)))
    (when (fboundp 'kubect-cancel-refresh) (kubect-cancel-refresh))
    (unless (equal (list context namespace resource)
                   (list (kubect-session-context session)
                         (kubect-session-namespace session)
                         (kubect-session-resource session)))
      (setf (kubect-session-marked-resources session) nil
            (kubect-session-event-objects session) nil
            (kubect-session-recent-pods session) nil
            (kubect-session-recent-containers session) nil
            (kubect-session-field-selector session) nil
            (kubect-session-scope-label session) nil))
    (setf (kubect-session-context session) context
          (kubect-session-namespace session) namespace
          (kubect-session-resource session) resource
          (kubect-session-name session) (kubect--session-name context namespace resource))
    (kubect--maybe-apply-default-sort session)
    (kubect--record-session-command command detail)
    (rename-buffer (kubect--session-buffer-name session) t)
    ;; Failed reads must not leave actionable rows from the previous scope.
    (let ((inhibit-read-only t)) (erase-buffer))
    (setq header-line-format (format "Loading %s/%s %s" context namespace resource))
    (condition-case err
        (kubect-refresh)
      (error
       (setq header-line-format (concat "Refresh failed: " (error-message-string err)))
       (signal (car err) (cdr err))))))

(defun kubect--session-change-namespace (namespace)
  "Switch the active session to NAMESPACE and refresh its contents."
  (let ((session (kubect--session-at-point)))
    (kubect--session-change-scope (kubect-session-context session) namespace
                                  (kubect-session-resource session) "namespace" namespace)))

(defun kubect-session-set-namespace ()
  "Change the session namespace."
  (interactive)
  (let* ((session (kubect--session-at-point))
         (namespace
          (kubect--read-namespace (kubect-session-context session)
                                   (kubect-session-namespace session))))
    (kubect--session-change-namespace namespace)))

(defun kubect-session-set-resource ()
  "Change the session resource collection."
  (interactive)
  (let* ((session (kubect--session-at-point))
         (resource
          (kubect--completing-read
           "Resource: "
           (kubect--list-resources
            (kubect-session-context session)
            (kubect-session-namespace session))
           (kubect-session-resource session))))
    (kubect--session-change-scope (kubect-session-context session)
                                  (kubect-session-namespace session)
                                  resource "resource" resource)))

(defun kubect-session-set-filter (filter)
  "Set a FILTER substring for the current session."
  (interactive
   (let ((session (kubect--session-at-point)))
     (list (read-string "Name filter: " nil nil (kubect-session-filter session)))))
  (let ((session (kubect--session-at-point)))
    (kubect--apply-session-filter session filter 'substring nil)
    (kubect--record-session-command "filter" (or filter "<cleared>"))
    (kubect-refresh)))

(defun kubect-session-set-column-filter (column pattern)
  "Filter the current session by COLUMN containing PATTERN.
An empty PATTERN clears the column filter.  This filter is composed with the
existing text filter or named preset and is reapplied after every refresh."
  (interactive
   (let* ((headers (kubect--table-columns
                    (save-excursion
                      (goto-char (point-min))
                      (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position)))))
          (session (kubect--session-at-point))
          (column (kubect--completing-read
                   "Column: " (append headers '("<clear>"))
                   (kubect-session-column-filter-column session))))
     (if (string= column "<clear>")
         (list nil nil)
       (list column (read-string (format "%s contains: " column) nil nil
                                 (kubect-session-column-filter-pattern session))))))
  (let ((session (kubect--session-at-point)))
    (setf (kubect-session-column-filter-column session) column
          (kubect-session-column-filter-pattern session)
          (unless (string-empty-p (or pattern "")) pattern))
    (unless (kubect-session-column-filter-pattern session)
      (setf (kubect-session-column-filter-column session) nil))
    (kubect--record-session-command
     "column-filter"
     (if column (format "%s~%s" column pattern) "<cleared>"))
    (kubect-refresh)))

(defun kubect-session-apply-filter-preset (name)
  "Apply a named filter preset NAME to the current session."
  (interactive
   (list (kubect--completing-read
          "Filter preset: "
          (append (kubect--filter-preset-names) '("<clear>")))))
  (let ((session (kubect--session-at-point)))
    (if (string= name "<clear>")
        (progn
          (kubect--apply-session-filter session nil)
          (kubect--record-session-command "preset" "<cleared>"))
      (let* ((spec (kubect--filter-preset-spec name))
             (pattern (plist-get spec :pattern))
             (mode (or (plist-get spec :mode) 'regexp))
             (sort-preset (plist-get spec :sort-preset)))
        (unless pattern
          (user-error "Unknown kubect filter preset: %s" name))
        (kubect--apply-session-filter session pattern mode name)
        (when sort-preset
          (kubect--apply-session-sort-preset session sort-preset 'manual))
        (kubect--record-session-command "preset" name)))
    (kubect-refresh)))

(defun kubect-session-apply-sort-preset (name)
  "Apply a named sort preset NAME to the current session."
  (interactive
   (list (kubect--completing-read
          "Sort preset: "
          (append (kubect--sort-preset-names) '("<clear>")))))
  (let ((session (kubect--session-at-point)))
    (if (string= name "<clear>")
        (progn
          (kubect--clear-session-sort session)
          (kubect--record-session-command "sort" "<cleared>"))
      (progn
        (kubect--apply-session-sort-preset session name 'manual)
        (kubect--record-session-command "sort" name)))
    (kubect-refresh)))

(defun kubect-session-sort-by-restarts ()
  "Apply the `restarts' sort preset to the current session."
  (interactive)
  (kubect-session-apply-sort-preset "restarts"))

(defun kubect-session-sort-by-age ()
  "Apply the `age' sort preset to the current session."
  (interactive)
  (kubect-session-apply-sort-preset "age"))

(defun kubect-session-sort-by-status ()
  "Apply the `status' sort preset to the current session."
  (interactive)
  (kubect-session-apply-sort-preset "status"))

(provide 'kubect-browser)
;;; kubect-browser.el ends here
