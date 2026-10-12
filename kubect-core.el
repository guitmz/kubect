;;; kubect-core.el --- Kubernetes workflows inside Emacs -*- lexical-binding: t; -*-

(require 'ansi-color)
(require 'cl-lib)
(require 'compile)
(require 'json)
(require 'project)
(require 'subr-x)
(require 'term)
(require 'browse-url)

(require 'consult nil t)
(require 'transient nil t)

(declare-function vterm "vterm" (&optional arg))
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function vterm-send-return "vterm" ())
(declare-function eat-mode "eat" ())
(declare-function eat-exec "eat" (buffer name command startfile switches))
(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))

(defgroup kubect nil
  "Cluster-aware Kubernetes workflows."
  :group 'tools
  :prefix "kubect-")

(defcustom kubect-kubectl-command "kubectl"
  "Name or path of the kubectl executable.
When `default-directory' is remote, Kubect runs this command on that remote
host through Tramp.  This variable can be set with a connection local profile
to select a different kubectl executable for a particular remote host."
  :type 'string
  :group 'kubect)

(defcustom kubect-max-log-requests 50
  "Maximum concurrent streams for selector logs."
  :type 'natnum
  :group 'kubect)

(defcustom kubect-default-shell "/bin/sh"
  "Shell used by `kubect-exec-shell'."
  :type 'string
  :group 'kubect)

(defcustom kubect-exec-backend 'term
  "Backend used by `kubect-exec-shell'.
`term' preserves the current behavior.  Other supplied options can use
`vterm', `eat', or `ghostel' when those packages are available.  For
full control, set `kubect-exec-open-function' instead."
  :type '(choice (const :tag "term" term)
                 (const :tag "vterm" vterm)
                 (const :tag "eat" eat)
                 (const :tag "ghostel" ghostel))
  :group 'kubect)

(defcustom kubect-exec-open-function nil
  "Optional function used to open kubectl exec sessions.
When non-nil, it is called with
  (BUFFER-NAME COMMAND ARGS DISPLAY-ACTION)
and should create and display the interactive buffer itself."
  :type '(choice (const :tag "Use kubect backend" nil)
                 (function :tag "Custom exec opener"))
  :group 'kubect)

(defcustom kubect-prod-context-regexp
  "\\(prod\\|production\\|live\\|main\\)"
  "Contexts matching this regexp require extra confirmation for writes."
  :type 'regexp
  :group 'kubect)

(defcustom kubect-confirm-mutating-commands t
  "When non-nil, require confirmation before Kubect changes cluster state.
This applies to manifest apply, remote file changes, rollout restarts, exec
sessions, and port forwards.  Production-like contexts are labelled in the
prompt using `kubect-prod-context-regexp'.  Set this to nil only when another
trusted policy layer provides an equivalent safeguard."
  :type 'boolean
  :group 'kubect)

(defcustom kubect-project-markers
  '("Chart.yaml" "skaffold.yaml" "Tiltfile" "kustomization.yaml" ".k8s-locals.el")
  "Files that mark a project as Kubernetes-related."
  :type '(repeat string)
  :group 'kubect)

(defcustom kubect-auto-enable-modes
  '(yaml-mode helm-mode conf-mode sh-mode)
  "Modes where `kubect-ops-mode' may auto-enable."
  :type '(repeat symbol)
  :group 'kubect)

(defcustom kubect-default-resource "pods"
  "Default resource collection shown in session buffers."
  :type 'string
  :group 'kubect)

(defcustom kubect-default-log-tail 200
  "Default number of log lines to tail."
  :type 'integer
  :group 'kubect)

(defcustom kubect-command-timeout 8
  "Maximum seconds a foreground Kubect command may run.
Commands remain interruptible with `C-g'; this bound prevents an unreachable
cluster or stalled credential helper from freezing Emacs indefinitely."
  :type 'number
  :group 'kubect)

(defcustom kubect-read-cache-ttl 2
  "Seconds to reuse safe kubectl read responses in interactive Kubect views."
  :type 'number
  :group 'kubect)

(defcustom kubect-credential-refresh-command nil
  "Optional shell command shown when Kubect detects authentication failure.
For example, GKE users can set this to `gcloud auth login'."
  :type '(choice (const :tag "Show generic guidance" nil) string)
  :group 'kubect)

(defcustom kubect-graph-depth 'full
  "Default relationship depth used by `kubect-resource-graph'."
  :type '(choice (const owners) (const workload) (const full))
  :group 'kubect)

(defcustom kubect-log-filter-presets
  '(("errors" . "\\b\\(ERROR\\|FATAL\\|Error\\|panic\\|exception\\)\\b")
    ("warnings" . "\\b\\(WARN\\|WARNING\\|Warning\\|deprecated\\)\\b")
    ("timeouts" . "\\b\\(timeout\\|timed out\\|deadline exceeded\\)\\b"))
  "Named regexp presets for searching kubect log stream buffers."
  :type '(alist :key-type string :value-type regexp)
  :group 'kubect)

(defcustom kubect-filter-presets
  '(("crashing" :mode regexp
     :pattern "CrashLoopBackOff\\|ImagePullBackOff\\|ErrImagePull\\|OOMKilled\\|BackOff\\|Error\\|Failed"
     :sort-preset "status")
    ("pending" :mode regexp
     :pattern "Pending\\|ContainerCreating\\|Terminating"
     :sort-preset "status")
    ("image-pull" :mode regexp
     :pattern "ImagePullBackOff\\|ErrImagePull"
     :sort-preset "status")
    ("restarting" :mode regexp
     :pattern "CrashLoopBackOff\\|OOMKilled\\|BackOff"
     :sort-preset "restarts")
    ("warning-events" :mode regexp
     :pattern "Warning"
     :sort-preset "age"))
  "Named presets for kubect session/browser filters.

Each preset is a list of the form (NAME :mode MODE :pattern PATTERN).
MODE is either `substring' or `regexp'."
  :type '(alist :key-type string
                :value-type (plist :options ((:mode symbol) (:pattern string) (:sort-preset string))))
  :group 'kubect)

(defcustom kubect-sort-presets
  '(("restarts" :column "RESTARTS" :parser integer :descending t)
    ("status" :column "STATUS" :parser status :descending t)
    ("age" :column "AGE" :parser age :descending nil)
    ("name" :column "NAME" :parser string :descending nil)
    ("namespace" :column "NAMESPACE" :parser string :descending nil))
  "Named presets for kubect session sorting.

Each preset has the form
  (NAME :column COLUMN :parser PARSER :descending BOOL).
PARSER is one of `string', `integer', `age', or `status'."
  :type '(alist :key-type string
                :value-type (plist :options ((:column string) (:parser symbol) (:descending boolean))))
  :group 'kubect)

(defcustom kubect-resource-default-sort-presets
  '(("pods" . "status")
    ("events" . "age"))
  "Default sort preset name to use for a resource when no manual sort is active."
  :type '(alist :key-type string :value-type string)
  :group 'kubect)

(defcustom kubect-investigation-profiles
  '(("crashing-pods"
     :resource "pods"
     :all-namespaces t
     :filter-preset "crashing"
     :sort-preset "status"
     :after-open incident-debug)
    ("recent-events"
     :resource "events"
     :all-namespaces nil
     :sort-preset "age"
     :after-open watch-events))
  "Named investigation profiles for opening kubect sessions quickly.

Each profile is a list of the form
 (NAME :resource RESOURCE :all-namespaces BOOL :namespace NAMESPACE
       :filter-preset FILTER :sort-preset SORT :wide BOOL
       :prompts PROMPTS
       :after-open ACTION-OR-ACTIONS)."
  :type '(alist :key-type string :value-type plist)
  :group 'kubect)

(defcustom kubect-restart-log-padding-seconds 300
  "Seconds of log history to include before a detected restart timestamp."
  :type 'integer
  :group 'kubect)

(defcustom kubect-watch-interval 5
  "Default refresh interval in seconds for watched session buffers."
  :type 'number
  :group 'kubect)

(defcustom kubect-timeline-default-limit 100
  "Default maximum number of events to show in timeline-style reports."
  :type 'integer
  :group 'kubect)

(defcustom kubect-alert-rules
  '(("unhealthy pod" :type pod-status :severity critical)
    ("restarting pod" :type pod-restarts :minimum 3 :severity warning)
    ("warning event burst" :type warning-events :minimum 10 :severity warning))
  "Rules evaluated by `kubect-alerts'.
Each rule is (NAME :type TYPE :severity SEVERITY :minimum NUMBER).  TYPE is
`pod-status', `pod-restarts', or `warning-events'."
  :type '(repeat (cons string plist))
  :group 'kubect)

(defcustom kubect-crd-views nil
  "Named custom-resource views.
Each entry is (NAME :resource RESOURCE :columns COLUMNS), where COLUMNS is a
kubectl custom-columns string."
  :type '(repeat (cons string plist))
  :group 'kubect)

(defcustom kubect-cost-request-usage-ratio 4
  "Minimum request-to-observed ratio that `kubect-cost-signals' reports.
The report is a capacity-triage aid, not a cloud-cost estimate."
  :type 'number
  :group 'kubect)

(defcustom kubect-saved-queries nil
  "Named reusable browser queries.
Each entry is (NAME :resource RESOURCE :all-namespaces BOOL :namespace NAME
:filter TEXT :filter-mode MODE :field-selector SELECTOR :sort-preset SORT
:wide BOOL)."
  :type '(alist :key-type string :value-type plist)
  :group 'kubect)

(defcustom kubect-prometheus-url nil
  "Optional Prometheus HTTP API base URL, without a trailing slash."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'kubect)

(defcustom kubect-prometheus-query-function nil
  "Optional function that executes PromQL and returns decoded API data.
It receives one PromQL string and must return an alist compatible with the
Prometheus /api/v1/query response body."
  :type '(choice (const :tag "Use configured HTTP API" nil) function)
  :group 'kubect)

(defcustom kubect-prometheus-alert-query "ALERTS{alertstate=\"firing\"}"
  "PromQL query used by `kubect-prometheus-alerts'."
  :type 'string
  :group 'kubect)

(defcustom kubect-display-buffer-action 'same-window
  "How kubect should display its interactive buffers.
Use `same-window' to reuse the current window or `pop-up' to let Emacs split."
  :type '(choice (const :tag "Reuse current window" same-window)
                 (const :tag "Pop up / split using Emacs defaults" pop-up))
  :group 'kubect)

(defcustom kubect-file-browser-default-path "/"
  "Default starting directory for the pod file browser."
  :type 'string
  :group 'kubect)

(defcustom kubect-resource-shortcuts
  '("pods" "deployments" "services" "statefulsets" "jobs" "cronjobs" "ingresses"
    "configmaps" "secrets" "events")
  "Common Kubernetes resources to browse."
  :type '(repeat string)
  :group 'kubect)

(defconst kubect-all-namespaces-token "*all*"
  "Special namespace token used for cluster-wide kubect sessions.")

(defcustom kubect-session-persist-file
  (locate-user-emacs-file "kubect-sessions.el")
  "File used to persist kubect sessions across Emacs restarts."
  :type 'file
  :group 'kubect)

(defcustom kubect-persist-sessions nil
  "When non-nil, persist kubect sessions across Emacs restarts."
  :type 'boolean
  :group 'kubect)

(defface kubect-warning-face
  '((t :inherit warning))
  "Face used for warning-like Kubernetes rows."
  :group 'kubect)

(defface kubect-critical-face
  '((t :inherit error))
  "Face used for unhealthy Kubernetes rows."
  :group 'kubect)

(defface kubect-mark-face
  '((t :inherit highlight))
  "Face used for marked kubect rows."
  :group 'kubect)

(defface kubect-report-header-face
  '((t :foreground "#7fd0da" :weight bold :height 1.14))
  "Face used for section headers in kubect report buffers."
  :group 'kubect)

(defface kubect-report-subtle-face
  '((t :inherit shadow))
  "Face used for subtle helper text in kubect report buffers."
  :group 'kubect)

(defface kubect-report-good-face
  '((t :inherit success :weight bold))
  "Face used for good-looking values in kubect reports."
  :group 'kubect)

(defface kubect-report-warn-face
  '((t :inherit warning :weight bold))
  "Face used for warning values in kubect reports."
  :group 'kubect)

(defface kubect-report-bad-face
  '((t :inherit error :weight bold))
  "Face used for unhealthy values in kubect reports."
  :group 'kubect)

(defface kubect-report-title-face
  '((t :inherit mode-line-buffer-id :weight bold :height 1.2))
  "Face used for top-level kubect report titles."
  :group 'kubect)

(defface kubect-report-subject-face
  '((t :inherit default :weight semi-bold))
  "Face used for top-level kubect report subjects."
  :group 'kubect)

(defconst kubect--report-rule
  "======================================================================="
  "Shared rule line for overview-style kubect reports.")

(defvar kubect--project-state (make-hash-table :test #'equal))
(defvar kubect--sessions nil)
(defvar kubect--display-buffer-action-override nil)
(defvar kubect--sessions-restored nil)

(defconst kubect--resource-kind-map
  '(("ConfigMap" . "configmaps")
    ("CronJob" . "cronjobs")
    ("DaemonSet" . "daemonsets")
    ("Deployment" . "deployments")
    ("Ingress" . "ingresses")
    ("Job" . "jobs")
    ("Namespace" . "namespaces")
    ("Pod" . "pods")
    ("Secret" . "secrets")
    ("Service" . "services")
    ("StatefulSet" . "statefulsets"))
  "Map YAML kinds to kubectl collection names.")

(defconst kubect--collection-singular-map
  '(("configmaps" . "configmap")
    ("cronjobs" . "cronjob")
    ("daemonsets" . "daemonset")
    ("deployments" . "deployment")
    ("events" . "event")
    ("ingresses" . "ingress")
    ("jobs" . "job")
    ("namespaces" . "namespace")
    ("pods" . "pod")
    ("replicasets" . "replicaset")
    ("secrets" . "secret")
    ("services" . "service")
    ("statefulsets" . "statefulset"))
  "Map kubectl collections to singular explain-friendly names.")

(defvar kubect-prefix-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "k") #'kubect-dispatch)
    (define-key map (kbd "i") #'kubect-incident-dispatch)
    (define-key map (kbd "b") #'kubect)
    (define-key map (kbd ".") #'kubect-home)
    (define-key map (kbd "I") #'kubect-investigation-profile)
    (define-key map (kbd "N") #'kubect-all-namespaces)
    (define-key map (kbd "P") #'kubect-pods-all-namespaces)
    (define-key map (kbd "v") #'kubect-events)
    (define-key map (kbd "V") #'kubect-events-for-resource-at-point)
    (define-key map (kbd "z") #'kubect-watch-events)
    (define-key map (kbd "Z") #'kubect-watch-events-for-resource)
    (define-key map (kbd "X") #'kubect-xray)
    (define-key map (kbd "G") #'kubect-resource-graph)
    (define-key map (kbd "J") #'kubect-namespace-dashboard)
    (define-key map (kbd "Q") #'kubect-alerts)
    (define-key map (kbd "y") #'kubect-timeline)
    (define-key map (kbd "Y") #'kubect-timeline-for-resource)
    (define-key map (kbd "B") #'kubect-switch-session)
    (define-key map (kbd "c") #'kubect-set-context)
    (define-key map (kbd "n") #'kubect-set-namespace)
    (define-key map (kbd "R") #'kubect-set-resource)
    (define-key map (kbd "W") #'kubect-session-toggle-wide)
    (define-key map (kbd "a") #'kubect-apply-buffer)
    (define-key map (kbd "d") #'kubect-diff-buffer)
    (define-key map (kbd "l") #'kubect-logs)
    (define-key map (kbd "L") #'kubect-logs-previous)
    (define-key map (kbd "A") #'kubect-logs-all-containers)
    (define-key map (kbd "C") #'kubect-logs-selector)
    (define-key map (kbd "t") #'kubect-top-pods)
    (define-key map (kbd "T") #'kubect-top-nodes)
    (define-key map (kbd "C-c N") #'kubect-nodes)
    (define-key map (kbd "o") #'kubect-occur)
    (define-key map (kbd "w") #'kubect-toggle-watch)
    (define-key map (kbd "e") #'kubect-exec-shell)
    (define-key map (kbd "F") #'kubect-browse-files)
    (define-key map (kbd "!") #'kubect-debug-restarts-resource)
    (define-key map (kbd "r") #'kubect-rollout-restart)
    (define-key map (kbd "h") #'kubect-rollout-history)
    (define-key map (kbd "=") #'kubect-rollout-diff)
    (define-key map (kbd "p") #'kubect-port-forward)
    (define-key map (kbd "j") #'kubect-jump-to-related-resource)
    (define-key map (kbd "u") #'kubect-resource-urls)
    (define-key map (kbd "O") #'kubect-resource-open-url)
    (define-key map (kbd "x") #'kubect-describe-resource-at-point)
    (define-key map (kbd "?") #'kubect-explain-resource-at-point)
    (define-key map (kbd "K") #'kubect-help)
    (define-key map (kbd "s") #'kubect-status)
    map)
  "Prefix map for Kubernetes commands.")

(defvar kubect-session-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'kubect-refresh)
    (define-key map (kbd "RET") #'kubect-view-resource)
    (define-key map (kbd "D") #'kubect-describe-resource)
    (define-key map (kbd "x") #'kubect-describe-resource)
    (define-key map (kbd "E") #'kubect-edit-resource)
    (define-key map (kbd "m") #'kubect-session-mark)
    (define-key map (kbd "u") #'kubect-session-unmark)
    (define-key map (kbd "U") #'kubect-session-clear-marks)
    (define-key map (kbd "M") #'kubect-session-bulk-action)
    (define-key map (kbd "l") #'kubect-logs-resource)
    (define-key map (kbd "L") #'kubect-logs-previous-resource)
    (define-key map (kbd "A") #'kubect-logs-all-containers-resource)
    (define-key map (kbd "C") #'kubect-logs-selector-resource)
    (define-key map (kbd "t") #'kubect-top-resource)
    (define-key map (kbd "e") #'kubect-exec-resource)
    (define-key map (kbd "F") #'kubect-browse-files)
    (define-key map (kbd "!") #'kubect-debug-restarts-resource)
    (define-key map (kbd "p") #'kubect-port-forward-resource)
    (define-key map (kbd "r") #'kubect-rollout-restart-resource)
    (define-key map (kbd "h") #'kubect-rollout-history-resource)
    (define-key map (kbd "=") #'kubect-rollout-diff-resource)
    (define-key map (kbd "i") #'kubect-incident-dispatch)
    (define-key map (kbd "j") #'kubect-jump-to-related-resource)
    (define-key map (kbd "O") #'kubect-resource-open-url)
    (define-key map (kbd "b") #'kubect-resource-urls)
    (define-key map (kbd "c") #'kubect-session-set-context)
    (define-key map (kbd "n") #'kubect-session-set-namespace)
    (define-key map (kbd "R") #'kubect-session-set-resource)
    (define-key map (kbd "H") #'kubect-session-history)
    (define-key map (kbd ".") #'kubect-home)
    (define-key map (kbd "W") #'kubect-session-toggle-wide)
    (define-key map (kbd ",") #'kubect-session-apply-sort-preset)
    (define-key map (kbd "[") #'kubect-session-sort-by-age)
    (define-key map (kbd "]") #'kubect-session-sort-by-restarts)
    (define-key map (kbd "{") #'kubect-session-sort-by-status)
    (define-key map (kbd "f") #'kubect-session-set-filter)
    (define-key map (kbd "/") #'kubect-session-set-filter)
    (define-key map (kbd "C-c f") #'kubect-session-set-column-filter)
    (define-key map (kbd "S") #'kubect-session-apply-filter-preset)
    (define-key map (kbd "o") #'kubect-occur)
    (define-key map (kbd "w") #'kubect-toggle-watch)
    (define-key map (kbd "?") #'kubect-session-dispatch)
    (define-key map (kbd "s") #'kubect-switch-session)
    (define-key map (kbd "v") #'kubect-events)
    (define-key map (kbd "V") #'kubect-events-for-resource)
    (define-key map (kbd "X") #'kubect-xray)
    (define-key map (kbd "G") #'kubect-resource-graph)
    (define-key map (kbd "J") #'kubect-namespace-dashboard)
    (define-key map (kbd "Q") #'kubect-alerts)
    (define-key map (kbd "y") #'kubect-timeline)
    (define-key map (kbd "Y") #'kubect-timeline-for-resource)
    (define-key map (kbd "z") #'kubect-watch-events)
    (define-key map (kbd "Z") #'kubect-watch-events-for-resource)
    (define-key map (kbd "K") #'kubect-help)
    (define-key map (kbd "I") #'kubect-investigation-profile)
    (define-key map (kbd "N") #'kubect-all-namespaces)
    (define-key map (kbd "P") #'kubect-pods-all-namespaces)
    (define-key map (kbd "B") #'kubect-switch-session)
    (define-key map (kbd "T") #'kubect-top-nodes)
    (define-key map (kbd "C-c N") #'kubect-nodes)
    map)
  "Keymap for Kubernetes session buffers.")

(defvar-local kubect-session nil)
(defvar-local kubect--watch-timer nil)
 (defvar-local kubect-stream-state nil)

(defvar kubect-file-browser-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'kubect-file-browser-refresh)
    (define-key map (kbd "RET") #'kubect-file-browser-visit)
    (define-key map (kbd "^") #'kubect-file-browser-up)
    (define-key map (kbd "+") #'kubect-file-browser-create)
    (define-key map (kbd "D") #'kubect-file-browser-delete)
    (define-key map (kbd "R") #'kubect-file-browser-rename)
    (define-key map (kbd "e") #'kubect-file-browser-edit-file)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "o") #'kubect-occur)
    (define-key map (kbd "?") #'kubect-file-browser-dispatch)
    map)
  "Keymap for the kubect pod file browser.")

(defvar-local kubect-file-browser-state nil)
(defvar-local kubect--remote-file-target nil)
(defvar-local kubect-bulk-review-state nil)
(defvar-local kubect-report-state nil)
 (defvar-local kubect--report-watch-timer nil)
(defvar-local kubect-output-state nil)
(defvar-local kubect--last-refresh-error nil)
(defvar-local kubect--last-action nil)

(defvar kubect-bulk-review-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'kubect-bulk-review-visit)
    (define-key map (kbd "o") #'kubect-bulk-review-visit-other-window)
    (define-key map (kbd "v") #'kubect-bulk-review-visit-other-window)
    (define-key map (kbd "a") #'kubect-bulk-review-visit-all)
    (define-key map (kbd "m") #'kubect-bulk-review-remove)
    (define-key map (kbd "f") #'kubect-bulk-review-filter)
    (define-key map (kbd "g") #'kubect-bulk-review-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'kubect-bulk-review-dispatch)
    map)
  "Keymap for bulk review buffers.")

(defvar kubect-report-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "o") #'occur)
    (define-key map (kbd "O") #'kubect-report-open-url)
    (define-key map (kbd "A") #'kubect-report-open-all-urls)
    (define-key map (kbd "w") #'kubect-report-copy-url)
    (define-key map (kbd "W") #'kubect-report-copy-all-urls)
    (define-key map (kbd "RET") #'push-button)
    (define-key map (kbd "g") #'kubect-report-refresh)
    (define-key map (kbd "t") #'kubect-report-toggle-watch)
    (define-key map (kbd "c") #'kubect-report-sort-top-by-cpu)
    (define-key map (kbd "m") #'kubect-report-sort-top-by-memory)
    (define-key map (kbd "?") #'kubect-report-dispatch)
    (define-key map (kbd "l") #'kubect-report-target-logs)
    (define-key map (kbd "D") #'kubect-report-target-describe)
    (define-key map (kbd "V") #'kubect-report-target-events)
    map)
  "Keymap for kubect report buffers.")

(defvar kubect-output-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'kubect-output-refresh)
    (define-key map (kbd "o") #'occur)
    (define-key map (kbd "?") #'kubect-output-dispatch)
    map)
  "Keymap for plain kubect output buffers.")

(defconst kubect--keymap-contracts
  '((kubect-session-mode-map
     ("g" . kubect-refresh) ("q" . kubect-quit-report)
     ("." . kubect-home) ("X" . kubect-xray) ("y" . kubect-timeline)
     ("G" . kubect-resource-graph) ("J" . kubect-namespace-dashboard)
     ("Q" . kubect-alerts)
     ("Y" . kubect-timeline-for-resource) ("v" . kubect-events)
     ("V" . kubect-events-for-resource) ("z" . kubect-watch-events)
     ("Z" . kubect-watch-events-for-resource) ("w" . kubect-toggle-watch)
     ("W" . kubect-session-toggle-wide) ("H" . kubect-session-history)
     ("s" . kubect-switch-session) ("B" . kubect-switch-session)
     ("I" . kubect-investigation-profile) ("N" . kubect-all-namespaces)
     ("P" . kubect-pods-all-namespaces) ("T" . kubect-top-nodes)
     ("C-c N" . kubect-nodes)
     ("o" . kubect-occur) ("K" . kubect-help) ("?" . kubect-session-dispatch)
     ("c" . kubect-session-set-context) ("n" . kubect-session-set-namespace)
     ("R" . kubect-session-set-resource) ("i" . kubect-incident-dispatch)
     ("j" . kubect-jump-to-related-resource) ("b" . kubect-resource-urls)
     ("O" . kubect-resource-open-url) ("m" . kubect-session-mark)
     ("u" . kubect-session-unmark) ("U" . kubect-session-clear-marks)
     ("M" . kubect-session-bulk-action) ("RET" . kubect-view-resource)
     ("D" . kubect-describe-resource) ("x" . kubect-describe-resource)
     ("E" . kubect-edit-resource) ("l" . kubect-logs-resource)
     ("L" . kubect-logs-previous-resource) ("A" . kubect-logs-all-containers-resource)
     ("t" . kubect-top-resource) ("e" . kubect-exec-resource)
     ("F" . kubect-browse-files) ("p" . kubect-port-forward-resource)
     ("r" . kubect-rollout-restart-resource) ("h" . kubect-rollout-history-resource)
     ("=" . kubect-rollout-diff-resource) ("!" . kubect-debug-restarts-resource)
     ("C-c C-k" . kubect-cancel-refresh) ("C-c C-e" . kubect-show-refresh-error))
    (kubect-report-mode-map
     ("g" . kubect-report-refresh) ("t" . kubect-report-toggle-watch)
     ("?" . kubect-report-dispatch))
    (kubect-output-mode-map
     ("g" . kubect-output-refresh) ("o" . occur) ("?" . kubect-output-dispatch))
    (kubect-file-browser-mode-map
     ("g" . kubect-file-browser-refresh) ("RET" . kubect-file-browser-visit)
     ("?" . kubect-file-browser-dispatch))
    (kubect-bulk-review-mode-map
     ("g" . kubect-bulk-review-refresh) ("RET" . kubect-bulk-review-visit)
     ("?" . kubect-bulk-review-dispatch)))
  "Documented direct key bindings that Kubect guarantees to keep stable.")

(defun kubect-verify-keymaps ()
  "Signal an error when a documented Kubect key binding has drifted."
  (interactive)
  ;; The stream map installs its keys when the derived mode is initialized.
  (with-temp-buffer (kubect-stream-mode))
  (dolist (contract kubect--keymap-contracts)
    (let ((map (symbol-value (car contract))))
      (dolist (binding (cdr contract))
        (unless (eq (lookup-key map (kbd (car binding))) (cdr binding))
          (error "Kubect key drift: %s %s is not %s"
                 (car contract) (car binding) (cdr binding))))))
  (unless (eq (lookup-key kubect-stream-mode-map (kbd "?"))
              #'kubect-stream-dispatch)
    (error "Kubect key drift: stream ? is not kubect-stream-dispatch"))
  t)

(defun kubect--project-root ()
  "Return the current project root, if any."
  (when-let* ((project (project-current nil)))
    (expand-file-name (project-root project))))

(defun kubect--project-key ()
  "Return the project key used for state lookup."
  (or (kubect--project-root)
      default-directory))

(defun kubect--project-defaults ()
  "Return project-local defaults from `.k8s-locals.el', if present.
The file should contain a single plist form, for example:
\(:context \"my-cluster\" :namespace \"payments\" :resource \"pods\"\)."
  (when-let* ((root (kubect--project-root))
              (file (expand-file-name ".k8s-locals.el" root))
              ((file-exists-p file)))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents file)
          (let ((value (read (current-buffer))))
            (when (listp value)
              value)))
      (error
       (message "kubect: could not read %s: %s" file (error-message-string err))
       nil))))

(defun kubect--project-default (prop)
  "Return project-local default PROP from `.k8s-locals.el'."
  (plist-get (kubect--project-defaults) prop))

(defun kubect--merge-named-presets (project-presets global-presets)
  "Merge PROJECT-PRESETS over GLOBAL-PRESETS by preset name."
  (let ((merged (copy-tree (or global-presets '()))))
    (dolist (preset (or project-presets '()))
      (setf (alist-get (car preset) merged nil nil #'equal) (cdr preset)))
    merged))

(defun kubect--effective-filter-presets ()
  "Return effective filter presets, including project-local overrides."
  (kubect--merge-named-presets
   (kubect--project-default :filter-presets)
   kubect-filter-presets))

(defun kubect--effective-sort-presets ()
  "Return effective sort presets, including project-local overrides."
  (kubect--merge-named-presets
   (kubect--project-default :sort-presets)
   kubect-sort-presets))

(defun kubect--effective-investigation-profiles ()
  "Return effective investigation profiles, including project-local overrides."
  (kubect--merge-named-presets
   (kubect--project-default :investigation-profiles)
   kubect-investigation-profiles))

(defun kubect--project-defaults-file ()
  "Return the current project's `.k8s-locals.el` path."
  (when-let* ((root (kubect--project-root)))
    (expand-file-name ".k8s-locals.el" root)))

(defun kubect--resource-default-sort-preset (resource)
  "Return the default sort preset for RESOURCE, if any."
  (or (alist-get resource
                  (or (kubect--project-default :resource-default-sorts) '())
                  nil nil #'equal)
      (alist-get resource kubect-resource-default-sort-presets nil nil #'equal)))

(defun kubect--run-profile-action (action)
  "Run investigation profile ACTION in the current kubect session buffer."
  (pcase action
    ('browser nil)
    ('logs (kubect-logs-resource))
    ('top (kubect-top-resource))
    ('events (kubect-events-for-resource))
    ('watch-events (kubect-watch-events))
    ('watch-events-for-resource (kubect-watch-events-for-resource))
    ('incident (call-interactively #'kubect-incident-dispatch))
    ('incident-logs (kubect-incident-logs-resource))
    ('incident-events (kubect-incident-events-for-resource))
    ('incident-watch-events (kubect-incident-watch-events-for-resource))
    ('incident-debug (kubect-incident-debug-restarts-resource))
    ('incident-describe (kubect-incident-describe-resource))
    ('top-report (kubect-top-resource))
    ('urls (kubect-resource-urls))
    ('view (kubect-view-resource))
    ('edit (kubect-edit-resource))
    ('bulk-event-summary
     (kubect--show-bulk-event-summary (kubect--visible-session-resources)))
    ('bulk-log-snapshot
     (kubect--show-bulk-log-snapshot (kubect--visible-session-resources)))
    ('bulk-top-summary
     (kubect--show-bulk-top-summary (kubect--visible-session-resources)))
    ('bulk-describe
     (kubect--show-bulk-describe (kubect--visible-session-resources)))
    ('timeline (kubect-timeline))
    ('timeline-resource (kubect-timeline-for-resource))
    ('xray (kubect-xray))
    (_ (user-error "Unknown kubect profile action: %s" action))))

(defun kubect--project-state ()
  "Return project state plist."
  (or (gethash (kubect--project-key) kubect--project-state)
      (let ((state (list :context (or (kubect--project-default :context)
                                      (string-trim (kubect--kubectl-output "config" "current-context")))
                         :namespace (or (kubect--project-default :namespace)
                                        (let ((namespace
                                               (ignore-errors
                                                 (kubect--kubectl-output
                                                  "config" "view" "--minify" "-o"
                                                  "jsonpath={..namespace}"))))
                                          (if (string-empty-p (or namespace ""))
                                              "default"
                                            namespace)))
                         :resource (or (kubect--project-default :resource)
                                       kubect-default-resource)
                         :wide (and (kubect--project-default :wide) t))))
        (puthash (kubect--project-key) state kubect--project-state)
        state)))

(defun kubect--set-project-state (prop value)
  "Set PROP to VALUE in the current project state."
  (let* ((key (kubect--project-key))
         (state (copy-sequence (kubect--project-state))))
    (puthash key (plist-put state prop value) kubect--project-state)))

(defun kubect--remember-recent (prop value)
  "Remember VALUE in project-local PROP history."
  (when (and value (not (string-empty-p value)))
    (let* ((state (copy-sequence (kubect--project-state)))
           (existing (plist-get state prop))
           (updated (cons value (delete value (copy-sequence existing)))))
      (kubect--set-project-state prop (cl-subseq updated 0 (min 20 (length updated)))))))

(defun kubect--recent-values (prop)
  "Return project-local recent values for PROP."
  (plist-get (kubect--project-state) prop))

(defun kubect-current-context ()
  "Return the active session context, falling back to project defaults."
  (or (and kubect-session (kubect-session-context kubect-session))
      (plist-get (gethash (kubect--project-key) kubect--project-state) :context)
      (kubect--project-default :context)
      (string-trim (kubect--kubectl-output "config" "current-context"))))

(defun kubect-current-namespace ()
  "Return the active session namespace, falling back to project defaults."
  (or (and kubect-session (kubect-session-namespace kubect-session))
      (plist-get (gethash (kubect--project-key) kubect--project-state) :namespace)
      (kubect--project-default :namespace)
      (let ((namespace
             (ignore-errors
               (kubect--kubectl-output
                "config" "view" "--minify" "-o"
                "jsonpath={..namespace}"))))
        (if (string-empty-p (or namespace ""))
            "default"
          namespace))))

(defun kubect-current-resource ()
  "Return the active session resource, falling back to project defaults."
  (or (and kubect-session (kubect-session-resource kubect-session))
      (plist-get (kubect--project-state) :resource)
      (kubect--project-default :resource)
      kubect-default-resource))

(defun kubect-current-wide-p ()
  "Return non-nil when the current project prefers a wide browser view."
  (or (plist-get (kubect--project-state) :wide)
      (kubect--project-default :wide)))

(defun kubect--display-action-from-prefix (arg)
  "Return a temporary display action derived from prefix ARG."
  (when arg
    'pop-up))

(defun kubect--current-display-buffer-action ()
  "Return the active display action for kubect buffers."
  (or kubect--display-buffer-action-override
      (kubect--project-default :display-buffer-action)
      kubect-display-buffer-action))

(defun kubect--mode-line ()
  "Return mode line lighter text."
  (let* ((context (kubect-current-context))
         (namespace (kubect-current-namespace))
         (short-context
          (if (> (length context) 22)
              (concat (substring context 0 19) "...")
            context)))
    (format " K8s[%s/%s]" short-context namespace)))

(defun kubect--scope-summary (context namespace resource)
  "Return a concise, unambiguous description of Kubernetes scope.
CONTEXT, NAMESPACE, and RESOURCE are passed separately so asynchronous work
can retain the scope it captured when the request began."
  (format "context=%s namespace=%s resource=%s" context namespace resource))

(defun kubect--project-kubernetes-p ()
  "Return non-nil when the current project appears to use Kubernetes."
  (or (when-let* ((root (kubect--project-root)))
        (cl-some (lambda (marker)
                   (file-exists-p (expand-file-name marker root)))
                 kubect-project-markers))
      (when buffer-file-name
        (string-match-p
         (rx "/" (or "k8s" "kubernetes" "helm" "charts" "templates") "/")
         buffer-file-name))))

(defun kubect--auto-enable-p ()
  "Return non-nil when the current buffer should enable `kubect-ops-mode'."
  (and (apply #'derived-mode-p kubect-auto-enable-modes)
       (kubect--project-kubernetes-p)))

(defun kubect--maybe-enable ()
  "Enable Kubernetes support when the current buffer looks relevant."
  (when (kubect--auto-enable-p)
    (kubect-ops-mode 1)))

(defun kubect--display-buffer (buffer)
  "Display BUFFER according to `kubect-display-buffer-action'."
  (pcase (kubect--current-display-buffer-action)
    ('silent buffer)
    ('same-window (switch-to-buffer buffer))
    (_ (pop-to-buffer buffer))))

(defun kubect--prepare-edit-buffer-keymap ()
  "Ensure the current buffer has a writable local keymap copy."
  (use-local-map
   (copy-keymap (or (current-local-map)
                    (make-sparse-keymap)))))

(defun kubect--json-pretty-string (object)
  "Return OBJECT as pretty-printed JSON text."
  (with-temp-buffer
    (insert (json-encode object))
    (json-pretty-print-buffer)
    (buffer-string)))

(defun kubect--json-selector-string (selector)
  "Convert SELECTOR alist to a kubectl label selector string."
  (when selector
    (string-join
     (cl-loop for (key . value) in selector
              collect (format "%s=%s" key value))
     ",")))

(defun kubect--completing-read (prompt candidates &optional initial)
  "Read a candidate from CANDIDATES using Consult when available."
  (cond
   ((null candidates)
    (user-error "No candidates available for %s" prompt))
   ((and (featurep 'consult) (fboundp 'consult--read))
    (consult--read candidates
                   :prompt prompt
                   :require-match t
                   :sort nil
                   :initial initial))
   (t
    (completing-read prompt candidates nil t initial))))

(defun kubect--confirm-write (action &optional context namespace)
  "Confirm ACTION in CONTEXT and NAMESPACE before it can change state.
When `kubect-confirm-mutating-commands' is nil, confirmation remains required
for a context matching `kubect-prod-context-regexp'."
  (let ((context (or context (kubect-current-context)))
        (namespace (or namespace (kubect-current-namespace))))
    (if (or kubect-confirm-mutating-commands
            (and (stringp context)
                 (string-match-p kubect-prod-context-regexp context)))
        (yes-or-no-p
         (format "%s against %s/%s%s? "
                 action context namespace
                 (if (and (stringp context)
                          (string-match-p kubect-prod-context-regexp context))
                     " [production context]"
                   "")))
      t)))

(defun kubect--list-contexts ()
  "Return available kube contexts."
  (split-string
   (kubect--kubectl-output "config" "get-contexts" "-o" "name")
   "\n" t))

(defun kubect--list-namespaces (&optional context)
  "Return namespaces for CONTEXT, or nil when listing is not allowed.
Kubect asks the API server about the relevant RBAC permission before issuing a
namespace listing.  A nil result lets callers offer a free form namespace
prompt instead of presenting a misleading empty completion list."
  (let ((context (or context (kubect-current-context))))
    (when (condition-case nil
              (equal "yes"
                     (downcase
                      (string-trim
                       (kubect--kubectl-output "--context" context
                                                "auth" "can-i" "list" "namespaces"))))
            (error nil))
      (cons kubect-all-namespaces-token
            (split-string
             (apply #'kubect--kubectl-output
                    (append (kubect--kubectl-base-args context "")
                            '("get" "namespaces" "-o"
                              "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")))
             "\n" t)))))

(defun kubect--read-namespace (&optional context initial)
  "Read a namespace for CONTEXT, using free form input when RBAC requires it."
  (let ((namespaces (kubect--list-namespaces context)))
    (if namespaces
        (kubect--completing-read "Namespace: " namespaces initial)
      (let ((fallback (or initial (kubect-current-namespace))))
        (message "Kubect cannot list namespaces for %s; enter one manually."
                 (or context (kubect-current-context)))
        (read-string "Namespace: " fallback)))))

(defun kubect--list-resources (&optional context namespace)
  "Return common resources for CONTEXT and NAMESPACE."
  (let* ((base (delete-dups (append kubect-resource-shortcuts '("pods"))))
         (extra
          (ignore-errors
            (split-string
             (apply #'kubect--kubectl-output
                    (append (kubect--kubectl-base-args context namespace)
                            '("api-resources" "--verbs=list" "-o" "name")))
             "\n" t))))
    (delete-dups (append base extra))))

(defun kubect--list-namespaced-resources (&optional context)
  "Return namespace-scoped resources for CONTEXT."
  (let* ((base (cl-remove-if (lambda (kind)
                               (member kind '("nodes" "namespaces")))
                             (delete-dups (append kubect-resource-shortcuts '("pods")))))
         (extra
          (ignore-errors
            (split-string
             (apply #'kubect--kubectl-output
                    (append (kubect--kubectl-base-args context "")
                            '("api-resources" "--verbs=list" "--namespaced=true" "-o" "name")))
             "\n" t))))
    (delete-dups (append base extra))))

(defun kubect--list-resource-names (kind &optional context namespace)
  "Return resource names for KIND in CONTEXT and NAMESPACE."
  (split-string
   (apply #'kubect--kubectl-output
          (append (kubect--kubectl-base-args context namespace)
                  (list "get" kind "-o"
                        "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")))
   "\n" t))

(defun kubect--prioritize-recent (candidates recents)
  "Return CANDIDATES with RECENTS moved to the front."
  (let ((seen (make-hash-table :test #'equal))
        ordered)
    (dolist (item recents)
      (when (member item candidates)
        (push item ordered)
        (puthash item t seen)))
    (dolist (item candidates)
      (unless (gethash item seen)
        (push item ordered)))
    (nreverse ordered)))

(defun kubect--list-containers (pod &optional context namespace)
  "Return container names for POD in CONTEXT and NAMESPACE."
  (split-string
   (apply #'kubect--kubectl-output
          (append (kubect--kubectl-base-args context namespace)
                  (list "get" "pod" pod "-o"
                        "jsonpath={.spec.initContainers[*].name} {.spec.containers[*].name}")))
   " " t))

(defun kubect--current-doc-bounds ()
  "Return the current YAML document bounds."
  (save-excursion
    (let ((start (progn
                   (re-search-backward "^---[[:space:]]*$" nil 'move)
                   (if (looking-at-p "^---[[:space:]]*$")
                       (line-beginning-position 2)
                     (point-min))))
          (end (or (save-excursion
                     (when (re-search-forward "^---[[:space:]]*$" nil t)
                       (match-beginning 0)))
                   (point-max))))
      (cons start end))))

(defun kubect--yaml-metadata-value (key)
  "Return metadata KEY from the current document."
  (pcase-let ((`(,start . ,end) (kubect--current-doc-bounds)))
    (save-excursion
      (goto-char start)
      (when (re-search-forward "^metadata:[[:space:]]*$" end t)
        (let ((meta-end
               (save-excursion
                 (forward-line 1)
                 (if (re-search-forward "^[^[:space:]\n]" end t)
                     (line-beginning-position)
                   end))))
          (goto-char (line-beginning-position 2))
          (when (re-search-forward
                 (format "^[[:space:]]+%s:[[:space:]]*\\([^#\n]+\\)$"
                         (regexp-quote key))
                 meta-end t)
            (string-trim (match-string 1) "\"" "\"")))))))

(defun kubect--yaml-line-key ()
  "Return the YAML key on the current line, if any."
  (save-excursion
    (beginning-of-line)
    (when (looking-at "^\\([[:space:]]*\\)\\(-\\)?[[:space:]]*\\([[:alnum:]_.-]+\\):\\(?:[[:space:]]*\\|$\\)")
      (list :indent (length (match-string 1))
            :dash (and (match-string 2) t)
            :key (match-string-no-properties 3)))))

(defun kubect--yaml-field-path-at-point ()
  "Return a dotted YAML field path for the current point."
  (pcase-let ((`(,start . ,_) (kubect--current-doc-bounds)))
    (save-excursion
      (let ((stack nil)
            (current-line (line-number-at-pos)))
        (goto-char start)
        (while (<= (line-number-at-pos) current-line)
          (when-let* ((entry (kubect--yaml-line-key)))
            (let ((indent (plist-get entry :indent))
                  (key (plist-get entry :key))
                  (dash (plist-get entry :dash)))
              (while (and stack
                          (>= (caar stack) indent))
                (pop stack))
              (when (or (not dash)
                        (= (line-number-at-pos) current-line))
                (push (cons indent key) stack))))
          (forward-line 1))
        (string-join (mapcar #'cdr (nreverse stack)) ".")))))

(defun kubect--resource-at-point ()
  "Return a plist describing the resource in the current YAML document."
  (when-let* ((kind (kubect--yaml-top-level-value "kind"))
              (name (kubect--yaml-metadata-value "name")))
    (list :kind (or (cdr (assoc kind kubect--resource-kind-map))
                    (downcase kind))
          :name name
          :namespace (or (kubect--yaml-metadata-value "namespace")
                         (kubect-current-namespace))
          :context (kubect-current-context))))

(defun kubect--singular-kind (kind)
  "Return singular explain-friendly KIND."
  (or (cdr (assoc kind kubect--collection-singular-map))
      kind))

(defun kubect--read-kind (&optional initial)
  "Prompt for a kubectl resource kind, optionally with INITIAL."
  (kubect--completing-read
   "Kind: "
   (kubect--list-resources)
   initial))

(defun kubect--resource-from-prompt (&optional kind context namespace)
  "Prompt for resource KIND in CONTEXT and NAMESPACE."
  (let* ((kind (or kind (kubect--read-kind)))
         (name (kubect--completing-read
                (format "%s: " (capitalize kind))
                (kubect--list-resource-names kind context namespace))))
    (list :kind kind
          :name name
          ;; Report commands destructure resources in this canonical order.
          :context (or context (kubect-current-context))
          :namespace (or namespace (kubect-current-namespace)))))

(defun kubect--resource-for-command (&optional context namespace)
  "Return a resource plist from point or prompts.
When prompting, CONTEXT and NAMESPACE make the picker scope explicit instead
of depending on whichever buffer happens to be current."
  (or (ignore-errors
        (when (derived-mode-p 'kubect-session-mode)
          (kubect--current-line-resource-plist)))
      (kubect--resource-at-point)
      (kubect--resource-from-prompt nil context namespace)))

(defun kubect--compilation-buffer-name (mode &optional context namespace)
  "Return a Kubernetes buffer name for MODE in CONTEXT and NAMESPACE."
  (format "*kubect %s %s/%s*"
          mode
          (or context (kubect-current-context))
          (or namespace (kubect-current-namespace))))

(define-derived-mode kubect-stream-mode special-mode "Kubect-Stream"
  "Mode for streaming kubectl output."
  (setq-local truncate-lines nil)
  (setq-local buffer-read-only t)
  (define-key kubect-stream-mode-map (kbd "o") #'kubect-occur)
  (define-key kubect-stream-mode-map (kbd "F") #'kubect-stream-occur-preset)
  (define-key kubect-stream-mode-map (kbd "t") #'kubect-stream-toggle-timestamps)
  (define-key kubect-stream-mode-map (kbd "q") #'kubect-quit-stream)
  (define-key kubect-stream-mode-map (kbd "?") #'kubect-stream-dispatch))

(defvar kubect-view-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'kubect-view-refresh)
    map)
  "Keymap for `kubect-view-mode'.")

(defvar-local kubect--view-target nil)

(defun kubect-view-refresh ()
  "Reload the manifest in the current Kubect view buffer."
  (interactive)
  (unless kubect--view-target
    (user-error "Current buffer is not a kubect manifest view"))
  (pcase-let ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
               kubect--view-target))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (kubect--kubectl-output
               "--context" context "--namespace" namespace
               "get" kind name "-o" "yaml"))
      (goto-char (point-min)))
    (setq-local header-line-format
                (format "Kubect manifest | %s | g refresh"
                        (kubect--scope-summary context namespace kind)))))

(defun kubect--activate-view-base-mode ()
  "Activate a lightweight major mode for manifest viewing.
This uses YAML syntax when available but delays normal mode hooks so
inspection buffers stay lightweight."
  (delay-mode-hooks
    (if (fboundp 'yaml-mode)
        (yaml-mode)
      (text-mode))))

(defun kubect-view-mode ()
  "Enable a read only manifest viewing mode."
  (kubect--activate-view-base-mode)
  (setq mode-name "Kubect-View")
  (use-local-map
   (make-composed-keymap kubect-view-mode-map (current-local-map)))
  (read-only-mode 1)
  (setq-local truncate-lines nil)
  (when (fboundp 'font-lock-ensure)
    (font-lock-ensure)))

(define-derived-mode kubect-file-browser-mode special-mode "Kubect-Files"
  "Mode for browsing files inside a pod."
  (setq truncate-lines t)
  (setq buffer-read-only t))

(define-derived-mode kubect-bulk-review-mode special-mode "Kubect-Bulk"
  "Mode for reviewing bulk kubect actions before opening buffers."
  (setq truncate-lines t)
  (setq buffer-read-only t))

(define-derived-mode kubect-report-mode special-mode "Kubect-Report"
  "Mode for consolidated kubect report buffers."
  (setq truncate-lines nil)
  (setq buffer-read-only t)
  (font-lock-add-keywords
   nil
   '(("^\\(OVERVIEW\\|XRAY\\|TIMELINE\\)  \\(.*\\)$"
      (1 'kubect-report-title-face t) (2 'kubect-report-subject-face t))
     ("^== .* ==$" . 'kubect-report-header-face)
     ("^## .*" . 'kubect-report-header-face)
     ("^No events$" . 'kubect-report-subtle-face)
     ("^Press .*" . 'kubect-report-subtle-face)
     ("^[[:space:]]*[A-Za-z][A-Za-z /_-]+:" . font-lock-variable-name-face)
     ("\\_<\\(True\\|Running\\|Healthy\\|Succeeded\\)\\_>" . 'kubect-report-good-face)
     ("\\_<\\(Warning\\|Pending\\|BackOff\\|Restarting\\|Partial\\)\\_>" . 'kubect-report-warn-face)
     ("\\_<\\(False\\|Error\\|Failed\\|CrashLoopBackOff\\|ImagePullBackOff\\|ErrImagePull\\|OOMKilled\\)\\_>" . 'kubect-report-bad-face)))
  (when (fboundp 'font-lock-ensure)
    (font-lock-ensure)))

(define-derived-mode kubect-output-mode special-mode "Kubect-Output"
  "Mode for plain-text kubect command output buffers."
  (setq truncate-lines nil)
  (setq buffer-read-only t))

(defun kubect-output-refresh ()
  "Refresh the current kubect output buffer when it has a generator."
  (interactive)
  (unless kubect-output-state
    (user-error "Current buffer is not a kubect output buffer"))
  (let ((refresh-fn (plist-get kubect-output-state :refresh-fn)))
    (unless refresh-fn
      (user-error "Current output buffer is not refreshable"))
    (let* ((state (funcall refresh-fn kubect-output-state))
           (body (plist-get state :body)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert body)
        (goto-char (point-min)))
      (setq-local header-line-format (plist-get state :header))
      (setq-local kubect-output-state state))))

(defun kubect--show-output-buffer (title body context namespace &optional arg header state)
  "Show a read only kubect output buffer with TITLE and BODY."
  (let ((buffer (get-buffer-create
                 (kubect--compilation-buffer-name title context namespace))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert body)
        (goto-char (point-min)))
      (kubect-output-mode)
      (setq-local header-line-format header)
      (setq-local kubect-output-state state))
    (let ((kubect--display-buffer-action-override
           (kubect--display-action-from-prefix arg)))
      (kubect--display-buffer buffer))))

(cl-defstruct
    (kubect-session
     (:constructor kubect-session-create))
  name context namespace resource filter filter-mode filter-label buffer project-root wide
  sort-label sort-column sort-parser sort-descending sort-source
  recent-pods recent-containers command-history event-objects marked-resources
  field-selector scope-label column-filter-column column-filter-pattern)

(defun kubect--filter-preset-names ()
  "Return the available kubect filter preset names."
  (mapcar #'car (kubect--effective-filter-presets)))

(defun kubect--filter-preset-spec (name)
  "Return filter preset plist for NAME."
  (cdr (assoc name (kubect--effective-filter-presets))))

(defun kubect--sort-preset-names ()
  "Return the available kubect sort preset names."
  (mapcar #'car (kubect--effective-sort-presets)))

(defun kubect--sort-preset-spec (name)
  "Return sort preset plist for NAME."
  (cdr (assoc name (kubect--effective-sort-presets))))

(defun kubect--investigation-profile-names ()
  "Return the available kubect investigation profile names."
  (mapcar #'car (kubect--effective-investigation-profiles)))

(defun kubect--investigation-profile-spec (name)
  "Return investigation profile plist for NAME."
  (cdr (assoc name (kubect--effective-investigation-profiles))))

(defun kubect--maybe-apply-default-sort (session)
  "Apply a resource-aware default sort to SESSION when appropriate."
  (when (or (null (kubect-session-sort-label session))
            (eq (kubect-session-sort-source session) 'auto))
    (if-let* ((preset (kubect--resource-default-sort-preset
                       (kubect-session-resource session))))
        (kubect--apply-session-sort-preset session preset 'auto)
      (kubect--clear-session-sort session))))

(defun kubect--age-string-seconds (value)
  "Convert kubectl AGE VALUE into seconds."
  (if (string-match "\\`\\([0-9]+\\)\\(s\\|m\\|h\\|d\\|w\\|mo\\|y\\)\\'" value)
      (let* ((count (string-to-number (match-string 1 value)))
             (unit (match-string 2 value)))
        (* count
           (pcase unit
             ("s" 1)
             ("m" 60)
             ("h" 3600)
             ("d" 86400)
             ("w" (* 7 86400))
             ("mo" (* 30 86400))
             ("y" (* 365 86400))
             (_ 1))))
    most-positive-fixnum))

(defun kubect--status-sort-rank (value)
  "Return a numeric severity rank for kubectl STATUS VALUE."
  (cond
   ((string-match-p
     (rx (or "CrashLoopBackOff" "ImagePullBackOff" "ErrImagePull" "OOMKilled"
             "CreateContainerConfigError" "CreateContainerError"
             "RunContainerError" "Error" "Failed"))
     value)
    3)
   ((string-match-p
     (rx (or "Pending" "ContainerCreating" "Terminating" "BackOff" "Warning"))
     value)
    2)
   ((string-match-p (rx (or "Completed" "Succeeded")) value)
    1)
   ((string-match-p (rx "Running") value)
    0)
   (t 1)))

(defun kubect--parse-sort-value (value parser)
  "Parse VALUE according to PARSER."
  (pcase parser
    ('integer (string-to-number value))
    ('age (kubect--age-string-seconds value))
    ('status (kubect--status-sort-rank value))
    (_ value)))

(defun kubect--sort-value-less-p (left right)
  "Return non-nil when LEFT sorts before RIGHT."
  (if (and (numberp left) (numberp right))
      (< left right)
    (string< (format "%s" left)
             (format "%s" right))))

(defun kubect--split-table-columns (line)
  "Split kubectl table LINE into whitespace-separated columns."
  (split-string (string-trim line) "[[:space:]][[:space:]]*"))

(defun kubect--table-sort-index (header column)
  "Return zero-based COLUMN index from HEADER."
  (cl-position column (kubect--split-table-columns header) :test #'string=))

(defun kubect--sort-table-output (session output)
  "Sort OUTPUT according to SESSION sort settings."
  (let* ((column (kubect-session-sort-column session))
         (parser (kubect-session-sort-parser session))
         (lines (split-string output "\n"))
         (header (car lines))
         (rows (cdr lines))
         (index (and column (kubect--table-sort-index header column))))
    (if (and column parser index (> (length rows) 1))
        (let ((sorted
               (sort
                (copy-sequence rows)
                (lambda (left right)
                  (let* ((left-cols (kubect--split-table-columns left))
                         (right-cols (kubect--split-table-columns right))
                         (left-value (kubect--parse-sort-value
                                      (or (nth index left-cols) "")
                                      parser))
                         (right-value (kubect--parse-sort-value
                                       (or (nth index right-cols) "")
                                       parser)))
                    (if (kubect-session-sort-descending session)
                        (if (equal left-value right-value)
                            (string< left right)
                          (kubect--sort-value-less-p right-value left-value))
                      (if (equal left-value right-value)
                          (string< left right)
                        (kubect--sort-value-less-p left-value right-value))))))))
          (string-join (cons header sorted) "\n"))
      output)))

(defun kubect-open (context namespace &optional resource filter display-action field-selector scope-label)
  "Open a Kubernetes session for CONTEXT, NAMESPACE, RESOURCE, and FILTER."
  (interactive
   (let* ((context (kubect--completing-read "Context: " (kubect--list-contexts)))
          (namespace (kubect--read-namespace context))
          (resource (kubect--read-kind kubect-default-resource)))
     (list context namespace resource nil
           (kubect--display-action-from-prefix current-prefix-arg))))
  (let* ((resource (or resource kubect-default-resource))
         (session (kubect-session-create
                   :name (concat (kubect--session-name context namespace resource)
                                 (if scope-label (format " [%s]" scope-label) ""))
                   :context context
                   :namespace namespace
                   :resource resource
                   :filter filter
                   :filter-mode (and filter 'substring)
                   :field-selector field-selector
                   :scope-label scope-label
                   :project-root (kubect--project-root)
                   :wide (and (kubect-current-wide-p) t)))
         (buffer-name (kubect--session-buffer-name session))
         (buffer (get-buffer-create buffer-name)))
    (kubect--maybe-apply-default-sort session)
    (setf (kubect-session-buffer session) buffer)
    (with-current-buffer buffer
      (kubect-session-mode)
      (setq-local kubect-session session)
      (setq default-directory (or (kubect-session-project-root session)
                                  default-directory))
      (kubect-refresh))
    (kubect--register-session session)
    (with-current-buffer buffer
      (kubect--record-session-command
       "open"
       (format "%s ns=%s resource=%s"
               (kubect-session-context session)
               (kubect-session-namespace session)
               (kubect-session-resource session))))
    (let ((kubect--display-buffer-action-override display-action))
      (kubect--display-buffer buffer))
    session))

(defun kubect-pods-all-namespaces (&optional arg filter)
  "Open a cluster-wide pods session across all namespaces.
Optional FILTER seeds the session substring filter."
  (interactive "P")
  (kubect-open (kubect-current-context)
               kubect-all-namespaces-token
               "pods"
               filter
               (kubect--display-action-from-prefix arg)))

(defun kubect-nodes (&optional arg)
  "Open a cluster-scoped node browser for the current Kubernetes context.
Unlike `kubect-top-nodes', this is the normal resource view: use `RET' to
view a node and `x' or `D' to describe it."
  (interactive "P")
  (kubect-open (kubect-current-context)
               ""
               "nodes"
               nil
               (kubect--display-action-from-prefix arg)
               nil
               "cluster nodes"))

(defun kubect-all-namespaces (&optional arg resource filter)
  "Open RESOURCE across all namespaces for the current context.
Optional FILTER seeds the session substring filter."
  (interactive
   (let* ((context (kubect-current-context))
          (resources (kubect--list-namespaced-resources context))
          (initial (let ((current (kubect-current-resource)))
                     (if (member current resources) current "pods")))
          (resource (kubect--completing-read
                     "All namespaces kind: "
                     resources
                     initial)))
     (list current-prefix-arg resource nil)))
  (kubect-open (kubect-current-context)
               kubect-all-namespaces-token
               (or resource "pods")
               filter
               (kubect--display-action-from-prefix arg)))

(defun kubect-investigation-profile (name &optional arg)
  "Open a kubect session from investigation profile NAME."
  (interactive
   (list (kubect--completing-read
          "Investigation profile: "
          (kubect--investigation-profile-names))
         current-prefix-arg))
  (let* ((spec (kubect--investigation-profile-spec name))
         (context (or (plist-get spec :context) (kubect-current-context)))
         (resource (or (plist-get spec :resource) (kubect-current-resource)))
         (namespace
          (cond
           ((plist-get spec :all-namespaces) kubect-all-namespaces-token)
           ((plist-get spec :namespace) (plist-get spec :namespace))
           (t (kubect-current-namespace))))
         (after-open (plist-get spec :after-open))
         (display-action (kubect--display-action-from-prefix arg))
         (session (kubect-open context namespace resource nil display-action)))
    (when-let* ((wide (plist-get spec :wide)))
      (setf (kubect-session-wide session) (and wide t)))
    (when-let* ((filter-preset (plist-get spec :filter-preset)))
      (with-current-buffer (kubect-session-buffer session)
        (kubect-session-apply-filter-preset filter-preset)))
    (when-let* ((sort-preset (plist-get spec :sort-preset)))
      (with-current-buffer (kubect-session-buffer session)
        (kubect-session-apply-sort-preset sort-preset)))
    (with-current-buffer (kubect-session-buffer session)
      (kubect--record-session-command "profile" name)
      (kubect-refresh)
      (dolist (action (if (listp after-open) after-open (list after-open)))
        (when action
          (kubect--run-profile-action action))))
    session))

(defun kubect-saved-query (name &optional arg)
  "Open the named reusable browser query NAME."
  (interactive
   (list (kubect--completing-read "Saved query: " (mapcar #'car kubect-saved-queries))
         current-prefix-arg))
  (let* ((spec (alist-get name kubect-saved-queries nil nil #'equal))
         (context (or (plist-get spec :context) (kubect-current-context)))
         (namespace (cond ((plist-get spec :all-namespaces) kubect-all-namespaces-token)
                          ((plist-get spec :namespace) (plist-get spec :namespace))
                          (t (kubect-current-namespace))))
         (session (kubect-open context namespace
                               (or (plist-get spec :resource) (kubect-current-resource))
                               (plist-get spec :filter)
                               (kubect--display-action-from-prefix arg)
                               (plist-get spec :field-selector)
                               name)))
    (with-current-buffer (kubect-session-buffer session)
      ;; `kubect-open' may have started a fetch before saved state is installed.
      (when kubect--async-job
        (kubect-cancel-refresh))
      (when-let* ((mode (plist-get spec :filter-mode)))
        (setf (kubect-session-filter-mode session) mode))
      (when-let* ((sort (plist-get spec :sort-preset)))
        (kubect-session-apply-sort-preset sort))
      (when (plist-member spec :wide)
        (setf (kubect-session-wide session) (plist-get spec :wide)))
      (kubect-refresh))
    session))

(defun kubect (&optional arg)
  "Open a kubect session for the current project state."
  (interactive "P")
  (kubect-open (kubect-current-context)
               (kubect-current-namespace)
               (kubect-current-resource)
               nil
               (kubect--display-action-from-prefix arg)))

(defun kubect-help (&optional arg)
  "Open a quick kubect help buffer for the current workflow."
  (interactive "P")
  (let ((body
         (string-join
         '("== Kubect Quick Help =="
            ""
            "Browser entry points"
            "b open browser"
            "I open a saved investigation profile"
            "N open any namespaced resource across all namespaces"
            "P open pods across all namespaces"
            "B switch session   T node capacity"
            "v open namespace events"
            "z watch namespace events"
            ""
            "Session keys"
            "g refresh   q dismiss browser"
            "c change context   n change namespace   R change resource"
            ", apply a named sort preset like restarts or age"
            "[ quick sort by age   ] quick sort by restarts   { quick sort by status"
            "f or / substring filter current view"
            "S apply a named filter preset like crashing or image-pull"
            "o occur regexp search current buffer"
            "b show service or ingress URLs"
            "O open URL directly for service or ingress rows"
            "t top for current row"
            "Z watch events for current row"
            "M bulk actions for marked rows"
            "C-c C-k cancel pending refresh   C-c C-e show refresh error"
            ""
            "Logs and incidents"
            "l logs"
            "L previous logs"
            "A all-container logs"
            "i incident transient"
            "! restart triage"
            ""
            "Reports"
            "g refresh report"
            "t toggle watch when available   q dismiss"
            "c sort top report by CPU"
            "m sort top report by memory"
            "C-c C-k cancel pending refresh   C-c C-e show refresh error"
            ""
            "All namespaces views"
            "Use N to open any namespace-scoped resource across all namespaces."
            "Use P for the pods-only shortcut."
            "Then use f for substring filtering, or o for regex-style occur search."
            "For example, filter CrashLoopBackOff with f, or use o for a richer regexp.")
          "\n")))
    (kubect--show-report-buffer
     "help" (concat body "\n")
     (kubect-current-context)
     (kubect-current-namespace)
     arg
     "Kubect help | q quit")))

(defun kubect-events (&optional arg)
  "Open an events session for the current context and namespace."
  (interactive "P")
  (let* ((session (ignore-errors (kubect--session-at-point)))
         (context (if session
                      (kubect-session-context session)
                    (kubect-current-context)))
         (namespace (if session
                        (kubect-session-namespace session)
                      (kubect-current-namespace))))
    (kubect-open context
                 namespace
                 "events"
                 nil
                 (kubect--display-action-from-prefix arg))))

(define-derived-mode kubect-session-mode special-mode "Kubect"
  "Mode for browsing Kubernetes resources."
  (setq truncate-lines t)
  (setq-local revert-buffer-function
              (lambda (&rest _ignore)
                (kubect-refresh)))
  (add-hook 'kill-buffer-hook #'kubect-stop-watch nil t))

(defun kubect--restart-trouble-line-p (line)
  "Return non-nil when LINE suggests restart-oriented investigation."
  (string-match-p
   (rx (or "CrashLoopBackOff" "OOMKilled" "BackOff" "Error" "Failed"))
   line))

(defun kubect--line-overlay-face (faces)
  "Return a composed overlay face from FACES."
  (cond
   ((null faces) nil)
   ((= (length faces) 1) (car faces))
   (t faces)))

(defun kubect--current-line-resource-plist ()
  "Return a resource plist for the current session line.
For events, this resolves to the involved object."
  (let ((resource (kubect--resource-plist-from-session)))
    (if (member (plist-get resource :kind) '("event" "events"))
        (if-let* ((object (kubect--event-object-at-point)))
            (pcase-let* ((`(,object-kind ,object-name) (split-string object "/" t)))
              (plist-put resource :kind (downcase object-kind))
              (plist-put resource :name object-name))
          (user-error "Could not determine the involved object for this event"))
      resource)))

(defun kubect--resource-identifier (resource)
  "Return a stable identifier string for RESOURCE plist."
  (format "%s/%s"
          (kubect--singular-kind (plist-get resource :kind))
          (plist-get resource :name)))

(defun kubect--resource-identifiers-at-point ()
  "Return resource identifiers represented by the current line."
  (list (kubect--resource-identifier (kubect--current-line-resource-plist))))

(defun kubect--resource-name-at-point ()
  "Return the resource name at point in a session buffer."
  (let* ((session (kubect--session-at-point))
         (line (string-trim-right
                (buffer-substring-no-properties
                 (line-beginning-position)
                 (line-end-position)))))
    (cond
     ((or (string-empty-p line)
          (bobp)
          (= (line-number-at-pos) 1))
      (user-error "No resource at point"))
     ((string= (kubect-session-resource session) "events")
      (user-error "Row actions are not supported for events yet"))
     (t
      (let ((tokens (split-string line "[[:space:]]+" t)))
        (if (equal (kubect-session-namespace session) kubect-all-namespaces-token)
            (cadr tokens)
          (car tokens)))))))

(defun kubect--namespace-at-point ()
  "Return the namespace at point in a session buffer."
  (let* ((session (kubect--session-at-point))
         (line (string-trim-right
                (buffer-substring-no-properties
                 (line-beginning-position)
                 (line-end-position))))
         (tokens (split-string line "[[:space:]]+" t)))
    (if (equal (kubect-session-namespace session) kubect-all-namespaces-token)
        (car tokens)
      (kubect-session-namespace session))))

(defun kubect--event-object-at-point ()
  "Return a best-effort involved object identifier from an events row."
  (or (when-let* ((session (kubect--current-session))
                  ((string= (kubect-session-resource session) "events"))
                  (index (- (line-number-at-pos) 2))
                  ((>= index 0))
                  (objects (kubect-session-event-objects session)))
        (nth index objects))
      (let* ((line (string-trim-right
                    (buffer-substring-no-properties
                     (line-beginning-position)
                     (line-end-position))))
             (tokens (split-string line "[[:space:]]+" t)))
        (cl-find-if (lambda (token)
                      (string-match-p "^[[:alnum:].-]+/[[:alnum:]._:-]+$" token))
                    tokens))))

(defun kubect--pod-names-for-selector (selector context namespace)
  "Return pod names matching label SELECTOR."
  (split-string
   (apply #'kubect--kubectl-output
          (append (kubect--kubectl-base-args context namespace)
                  (list "get" "pods" "-l" selector "-o"
                        "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")))
   "\n" t))

(defun kubect--pods-for-selector (selector context namespace)
  "Return pod alists matching SELECTOR."
  (alist-get 'items
             (apply #'kubect--kubectl-json
                    (append (kubect--kubectl-base-args context namespace)
                            (list "get" "pods" "-l" selector "-o" "json")))))

(defun kubect--pod-priority-score (pod)
  "Return a priority score for POD, preferring unhealthy pods."
  (let* ((status (alist-get 'status pod))
         (phase (or (alist-get 'phase status) ""))
         (statuses (alist-get 'containerStatuses status))
         (restarts (apply #'+ 0 (mapcar (lambda (entry)
                                          (or (alist-get 'restartCount entry) 0))
                                        statuses)))
         (waiting-reason
          (cl-some (lambda (entry)
                     (alist-get 'reason (alist-get 'waiting (alist-get 'state entry))))
                   statuses))
         (ready-count (cl-count-if (lambda (entry) (alist-get 'ready entry)) statuses))
         (total-count (length statuses)))
    (cond
     ((member waiting-reason '("CrashLoopBackOff" "ImagePullBackOff" "ErrImagePull"
                               "CreateContainerConfigError" "CreateContainerError"
                               "RunContainerError"))
      4000)
     ((member phase '("Failed" "Unknown")) 3000)
     ((not (string= phase "Running")) 2000)
     ((and (> total-count 0) (< ready-count total-count)) 1000)
     ((> restarts 0) (+ 100 restarts))
     (t 0))))

(defun kubect--choose-pod-from-items (pods)
  "Choose a pod name from PODS, preferring unhealthy and recent items."
  (when pods
    (let* ((sorted
            (sort (copy-sequence pods)
                  (lambda (left right)
                    (let ((left-score (kubect--pod-priority-score left))
                          (right-score (kubect--pod-priority-score right))
                          (left-created (or (alist-get 'creationTimestamp (alist-get 'metadata left)) ""))
                          (right-created (or (alist-get 'creationTimestamp (alist-get 'metadata right)) "")))
                      (if (/= left-score right-score)
                          (> left-score right-score)
                        (string> left-created right-created))))))
           (names (mapcar (lambda (entry)
                            (alist-get 'name (alist-get 'metadata entry)))
                          sorted)))
      (if (= (length names) 1)
          (car names)
        (kubect--completing-read "Pod: " names)))))

(defun kubect--selector-for-resource (kind name context namespace)
  "Return a label selector string for KIND NAME in CONTEXT and NAMESPACE."
  (cond
   ((member kind '("deployments" "deployment"
                   "statefulsets" "statefulset"
                   "daemonsets" "daemonset"
                   "replicasets" "replicaset"))
    (let* ((data (apply #'kubect--kubectl-json
                        (append (kubect--kubectl-base-args context namespace)
                                (list "get" kind name "-o" "json"))))
           (selector (alist-get 'matchLabels
                                (alist-get 'selector
                                           (alist-get 'spec data)))))
      (kubect--json-selector-string selector)))
   ((member kind '("services" "service"))
    (let* ((data (apply #'kubect--kubectl-json
                        (append (kubect--kubectl-base-args context namespace)
                                (list "get" kind name "-o" "json"))))
           (selector (alist-get 'selector
                                (alist-get 'spec data))))
      (kubect--json-selector-string selector)))
   ((member kind '("jobs" "job"))
    (format "job-name=%s" name))
   (t
    (kubect--project-default :log-selector))))

(defun kubect--pod-for-resource (kind name context namespace)
  "Resolve KIND NAME into a pod name where possible."
  (cond
   ((member kind '("pods" "pod")) name)
   (t
    (when-let* ((selector (kubect--selector-for-resource kind name context namespace))
                (pods (kubect--pods-for-selector selector context namespace))
                (pod (kubect--choose-pod-from-items pods)))
      pod))))

(defun kubect--jobs-for-cronjob (name context namespace)
  "Return job names owned by cronjob NAME."
  (let* ((data (apply #'kubect--kubectl-json
                      (append (kubect--kubectl-base-args context namespace)
                              (list "get" "jobs" "-l" (format "cronjob-name=%s" name) "-o" "json"))))
         (items (alist-get 'items data))
         (sorted
          (sort (copy-sequence items)
                (lambda (left right)
                  (string>
                   (or (alist-get 'creationTimestamp (alist-get 'metadata left)) "")
                   (or (alist-get 'creationTimestamp (alist-get 'metadata right)) ""))))))
    (mapcar (lambda (entry)
              (alist-get 'name (alist-get 'metadata entry)))
            sorted)))

(defun kubect-jump-to-related-resource (&optional arg)
  "Jump to the most useful related resource for the current row."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist)))
    (pcase (downcase kind)
      ((or "pod" "pods")
       (kubect--record-session-command "jump" (format "pod/%s" name))
       (kubect--view-known-resource "pod" name context namespace arg))
      ((or "deployment" "deployments"
           "daemonset" "daemonsets"
           "statefulset" "statefulsets"
           "replicaset" "replicasets"
           "service" "services"
           "job" "jobs")
       (let ((pod (or (kubect--pod-for-resource kind name context namespace)
                      (kubect--read-pod context namespace))))
         (kubect--record-session-command "jump" (format "pod/%s" pod))
         (kubect--view-known-resource "pod" pod context namespace arg)))
      ((or "cronjob" "cronjobs")
       (kubect--record-session-command "jump" (format "jobs/%s" name))
       (kubect-open context namespace "jobs" name
                    (kubect--display-action-from-prefix arg)))
      ((or "ingress" "ingresses")
       (kubect-resource-urls arg))
      (_
       (user-error "No related jump helper for %s" kind)))))

(defun kubect--default-occur-regexp ()
  "Return a sensible default regexp for `kubect-occur'."
  (or (ignore-errors
        (when (derived-mode-p 'kubect-session-mode)
          (kubect--resource-name-at-point)))
      (thing-at-point 'symbol t)
      ""))

(defun kubect-occur (regexp)
  "Run `occur' in the current kubect-related buffer using REGEXP."
  (interactive
   (list
    (read-regexp "Kubect occur regexp: "
                 (kubect--default-occur-regexp))))
  (occur regexp))

(defun kubect--events-for-resource (kind name context namespace &optional arg)
  "Open an events session filtered to KIND NAME in CONTEXT and NAMESPACE."
  (let ((filter (format "%s/%s" (capitalize (kubect--singular-kind kind)) name)))
    (kubect-open context namespace "events" filter
                 (kubect--display-action-from-prefix arg))))

(defun kubect--event-field-selector (kind name)
  "Return a field selector for Kubernetes event KIND and NAME."
  (format "involvedObject.kind=%s,involvedObject.name=%s"
          (capitalize (kubect--singular-kind kind))
          name))

(defun kubect--describe-state (kind name context namespace)
  "Return plain output STATE for describing KIND NAME in CONTEXT and NAMESPACE."
  (let ((kind (kubect--singular-kind kind)))
    (list :title (format "describe %s" name)
          :header (format "Describe: %s/%s  %s/%s | g refresh | o occur | q quit"
                          context namespace kind name)
          :context context
          :namespace namespace
          :body (concat
                 (kubect--kubectl-output
                  "--context" context
                  "--namespace" namespace
                  "describe" kind name)
                 "\n")
          :refresh-fn (lambda (_state)
                        (kubect--describe-state kind name context namespace)))))

(defun kubect--show-describe-resource (kind name context namespace &optional arg)
  "Show `kubectl describe' for KIND NAME in CONTEXT and NAMESPACE."
  (let ((state (kubect--describe-state kind name context namespace)))
    (kubect--show-output-buffer
     (plist-get state :title)
     (plist-get state :body)
     context namespace arg
     (plist-get state :header)
     state)))

(defun kubect--resource-json (kind name context namespace)
  "Return JSON data for KIND NAME in CONTEXT and NAMESPACE."
  (apply #'kubect--kubectl-json
         (append (kubect--kubectl-base-args context namespace)
                 (list "get" kind name "-o" "json"))))

(defun kubect--resource-basic-summary (kind name context namespace)
  "Return a summary plist for KIND NAME in CONTEXT and NAMESPACE."
  (let* ((data (kubect--resource-json kind name context namespace))
         (metadata (alist-get 'metadata data))
         (status (alist-get 'status data))
         (spec (alist-get 'spec data)))
    (list :kind kind
          :name name
          :context context
          :namespace namespace
          :uid (alist-get 'uid metadata)
          :labels (alist-get 'labels metadata)
          :annotations (alist-get 'annotations metadata)
          :owners (alist-get 'ownerReferences metadata)
          :status status
          :spec spec
          :data data)))

(defun kubect--resource-event-items (kind name context namespace &optional limit)
  "Return recent event items for KIND NAME in CONTEXT and NAMESPACE."
  (let* ((data (apply #'kubect--kubectl-json
                      (append (kubect--kubectl-base-args context namespace)
                              (list "get" "events"
                                    "--field-selector"
                                    (kubect--event-field-selector kind name)
                                    "-o" "json"))))
         (items (sort (copy-sequence (alist-get 'items data))
                      (lambda (left right)
                        (string>
                         (or (alist-get 'lastTimestamp left) "")
                         (or (alist-get 'lastTimestamp right) ""))))))
    (if (and limit (> (length items) limit))
        (cl-subseq items 0 limit)
      items)))

(defun kubect--event-item-line (item &optional include-object)
  "Return a readable single-line summary for event ITEM.
When INCLUDE-OBJECT is non-nil, include the involved object label."
  (let* ((obj (alist-get 'involvedObject item))
         (metadata (alist-get 'metadata item))
         (namespace (alist-get 'namespace metadata))
         (object-label (format "%s/%s"
                               (or (alist-get 'kind obj) "?")
                               (or (alist-get 'name obj) "?")))
         (timestamp (or (alist-get 'lastTimestamp item)
                        (alist-get 'eventTime item)
                        (alist-get 'firstTimestamp item)
                        ""))
         (type (or (alist-get 'type item) ""))
         (reason (or (alist-get 'reason item) ""))
         (message (string-trim (or (alist-get 'message item) ""))))
    (string-join
     (delq nil
           (list timestamp
                 (unless (string-empty-p type) type)
                 (unless (string-empty-p reason) reason)
                 (when (and include-object namespace (not (string-empty-p namespace)))
                   namespace)
                 (when include-object object-label)
                 (unless (string-empty-p message) message)))
     "  ")))

(defun kubect--pod-status-string (pod)
  "Return a useful status string for POD item JSON."
  (let* ((status (alist-get 'status pod))
         (phase (or (alist-get 'phase status) "Unknown"))
         (statuses (alist-get 'containerStatuses status))
         (waiting (cl-some (lambda (entry)
                             (alist-get 'reason (alist-get 'waiting
                                                           (alist-get 'state entry))))
                           statuses))
         (terminated (cl-some (lambda (entry)
                                (alist-get 'reason (alist-get 'terminated
                                                              (alist-get 'state entry))))
                              statuses)))
    (or waiting terminated phase)))

(defun kubect--pod-restarts (pod)
  "Return total restart count for POD item JSON."
  (apply #'+ 0
         (mapcar (lambda (entry)
                   (or (alist-get 'restartCount entry) 0))
                 (alist-get 'containerStatuses (alist-get 'status pod)))))

(defun kubect--pods-health-summary (&optional context namespace)
  "Return a health summary plist for pods in CONTEXT and NAMESPACE."
  (let* ((namespace (or namespace kubect-all-namespaces-token))
         (data (apply #'kubect--kubectl-json
                      (append (kubect--kubectl-base-args context namespace)
                              (list "get" "pods" "-o" "json"))))
         (items (alist-get 'items data))
         (total 0)
         (unhealthy 0)
         (pending 0)
         (restarting 0)
         (samples nil))
    (dolist (pod items)
      (setq total (1+ total))
      (let* ((status-text (kubect--pod-status-string pod))
             (restarts (kubect--pod-restarts pod))
             (score (kubect--pod-priority-score pod))
             (name (alist-get 'name (alist-get 'metadata pod)))
             (pod-namespace (alist-get 'namespace (alist-get 'metadata pod))))
        (when (> score 0)
          (setq unhealthy (1+ unhealthy))
          (push (list :namespace pod-namespace
                      :name name
                      :status status-text
                      :restarts restarts
                      :score score)
                samples))
        (when (string-match-p
               (rx (or "Pending" "ContainerCreating" "Terminating" "Unknown"))
               status-text)
          (setq pending (1+ pending)))
        (when (> restarts 0)
          (setq restarting (1+ restarting)))))
    (list :total total
          :unhealthy unhealthy
          :pending pending
          :restarting restarting
          :samples
          (cl-subseq
           (sort samples
                 (lambda (left right)
                   (if (/= (plist-get left :score) (plist-get right :score))
                       (> (plist-get left :score) (plist-get right :score))
                     (> (plist-get left :restarts) (plist-get right :restarts)))))
           0
           (min 8 (length samples))))))

(defun kubect--event-warning-summary (&optional context namespace)
  "Return a warning-event summary plist for CONTEXT and NAMESPACE."
  (let* ((namespace (or namespace kubect-all-namespaces-token))
         (data (apply #'kubect--kubectl-json
                      (append (kubect--kubectl-base-args context namespace)
                              (list "get" "events" "-o" "json"))))
         (items (alist-get 'items data))
         (warnings 0)
         (recent nil))
    (dolist (item items)
      (when (equal (alist-get 'type item) "Warning")
        (setq warnings (1+ warnings))
        (push item recent)))
    (setq recent
          (sort recent
                (lambda (left right)
                  (string>
                   (or (alist-get 'lastTimestamp left) "")
                   (or (alist-get 'lastTimestamp right) "")))))
    (list :warnings warnings
          :recent (mapcar (lambda (item)
                            (kubect--event-item-line item t))
                          (cl-subseq recent 0 (min 8 (length recent)))))))

(defun kubect--pod-config-refs (pod-spec)
  "Return config-like references found inside POD-SPEC."
  (let (refs)
    (dolist (volume (alist-get 'volumes pod-spec))
      (when-let* ((name (alist-get 'name (alist-get 'configMap volume))))
        (push (format "configmap/%s" name) refs))
      (when-let* ((name (alist-get 'secretName (alist-get 'secret volume))))
        (push (format "secret/%s" name) refs)))
    (dolist (container (append (alist-get 'containers pod-spec)
                               (alist-get 'initContainers pod-spec)))
      (dolist (env-from (alist-get 'envFrom container))
        (when-let* ((name (alist-get 'name (alist-get 'configMapRef env-from))))
          (push (format "configmap/%s" name) refs))
        (when-let* ((name (alist-get 'name (alist-get 'secretRef env-from))))
          (push (format "secret/%s" name) refs)))
      (dolist (env (alist-get 'env container))
        (when-let* ((ref (alist-get 'secretKeyRef (alist-get 'valueFrom env)))
                    (name (alist-get 'name ref)))
          (push (format "secret/%s" name) refs))
        (when-let* ((ref (alist-get 'configMapKeyRef (alist-get 'valueFrom env)))
                    (name (alist-get 'name ref)))
          (push (format "configmap/%s" name) refs))))
    (delete-dups (nreverse refs))))

(defun kubect--services-for-pod (pod-summary context namespace)
  "Return service names in NAMESPACE that select POD-SUMMARY."
  (let* ((labels (plist-get pod-summary :labels))
         (data (apply #'kubect--kubectl-json
                      (append (kubect--kubectl-base-args context namespace)
                              (list "get" "services" "-o" "json"))))
         matches)
    (dolist (item (alist-get 'items data))
      (let ((selector (alist-get 'selector (alist-get 'spec item))))
        (when (and selector
                   (cl-every (lambda (pair)
                               (equal (alist-get (car pair) labels nil nil #'equal)
                                      (cdr pair)))
                             selector))
          (push (alist-get 'name (alist-get 'metadata item)) matches))))
    (nreverse matches)))

(defun kubect--ingresses-for-service (service context namespace)
  "Return ingress names in NAMESPACE that point to SERVICE."
  (let* ((data (apply #'kubect--kubectl-json
                      (append (kubect--kubectl-base-args context namespace)
                              (list "get" "ingresses" "-o" "json"))))
         matches)
    (dolist (item (alist-get 'items data))
      (let* ((spec (alist-get 'spec item))
             (rules (alist-get 'rules spec))
             (default-backend (alist-get 'defaultBackend spec))
             (default-service (alist-get 'name (alist-get 'service default-backend)))
             (found default-service))
        (unless found
          (dolist (rule rules)
            (dolist (path (alist-get 'paths (alist-get 'http rule)))
              (when (equal (alist-get 'name (alist-get 'service (alist-get 'backend path)))
                           service)
                (setq found t)))))
        (when found
          (push (alist-get 'name (alist-get 'metadata item)) matches))))
    (delete-dups (nreverse matches))))

(defun kubect--quantity-percent (value total)
  "Return VALUE as a percentage string of TOTAL."
  (format "%d%%"
          (if (<= total 0)
              0
            (truncate (* 100.0 (/ value total))))))

(defun kubect--format-cpu-with-percent (value total)
  "Return CPU VALUE and TOTAL as a formatted millicore string."
  (format "%sm (%s)"
          (truncate value)
          (kubect--quantity-percent value total)))

(defun kubect--format-memory-with-percent (value total)
  "Return memory VALUE and TOTAL as a formatted MiB string."
  (format "%sMi (%s)"
          (truncate value)
          (kubect--quantity-percent value total)))

(defun kubect--pod-limit-total (pod resource parser)
  "Return POD limit RESOURCE total with init-container max semantics using PARSER."
  (let* ((spec (alist-get 'spec pod))
         (containers (alist-get 'containers spec))
         (init-containers (alist-get 'initContainers spec))
         (app-sum
          (cl-loop for container in containers
                   sum (funcall parser
                                (or (alist-get resource (alist-get 'limits (alist-get 'resources container)))
                                    0.0))))
         (init-max
          (cl-loop for container in init-containers
                   maximize (funcall parser
                                     (or (alist-get resource (alist-get 'limits (alist-get 'resources container)))
                                         0.0)) into current
                   finally return (or current 0.0))))
    (max app-sum init-max)))

(defun kubect--shell-command-string (args)
  "Return a shell-safe command string for ARGS."
  (mapconcat #'shell-quote-argument
             (cons (kubect--ensure-kubectl) args)
             " "))

(defun kubect--open-term-exec-buffer (buffer-name _command args display-action)
  "Open kubectl exec using `term' with BUFFER-NAME and ARGS."
  (let ((buffer (apply #'make-term buffer-name (kubect--ensure-kubectl) nil args)))
    (with-current-buffer buffer
      (term-mode)
      (term-char-mode))
    (let ((kubect--display-buffer-action-override display-action))
      (kubect--display-buffer buffer))
    buffer))

(defun kubect--send-command-to-buffer (buffer command send-fn &optional return-fn)
  "Display BUFFER, send COMMAND with SEND-FN, and optionally call RETURN-FN."
  (let ((kubect--display-buffer-action-override kubect--display-buffer-action-override))
    (kubect--display-buffer buffer))
  (with-current-buffer buffer
    (funcall send-fn command)
    (when return-fn
      (funcall return-fn)))
  buffer)

(defun kubect--open-vterm-exec-buffer (buffer-name command _args display-action)
  "Open kubectl exec COMMAND in `vterm'."
  (unless (fboundp 'vterm)
    (user-error "kubect exec backend `vterm' is not available"))
  (let* ((kubect--display-buffer-action-override display-action)
         (buffer (vterm buffer-name)))
    (kubect--send-command-to-buffer
     buffer command #'vterm-send-string #'vterm-send-return)))

(defun kubect--open-eat-exec-buffer (buffer-name _command args display-action)
  "Open kubectl with ARGS in `eat'."
  (unless (or (fboundp 'eat-exec) (require 'eat nil t))
    (user-error "kubect exec backend `eat' is not available"))
  (let ((kubect--display-buffer-action-override display-action)
        (buffer (generate-new-buffer buffer-name)))
    (condition-case err
        (progn
          (with-current-buffer buffer (eat-mode))
          (kubect--display-buffer buffer)
          (eat-exec buffer "kubect" (kubect--ensure-kubectl) nil args)
          buffer)
      (error (kill-buffer buffer) (signal (car err) (cdr err))))))

(defun kubect--open-ghostel-exec-buffer (buffer-name _command args display-action)
  "Open kubectl with ARGS using Ghostel's direct process API."
  (unless (or (fboundp 'ghostel-exec)
              (and (require 'ghostel nil t) (fboundp 'ghostel-exec)))
    (user-error "kubect requires a Ghostel version with ghostel-exec"))
  (let ((kubect--display-buffer-action-override display-action)
        (buffer (generate-new-buffer buffer-name)))
    (condition-case err
        (progn
          (kubect--display-buffer buffer)
          (ghostel-exec buffer (kubect--ensure-kubectl) args)
          buffer)
      (error (kill-buffer buffer) (signal (car err) (cdr err))))))

(defun kubect--open-exec-buffer (buffer-name args display-action)
  "Open kubectl exec BUFFER-NAME using ARGS and DISPLAY-ACTION."
  (let ((command (kubect--shell-command-string args)))
    (if kubect-exec-open-function
        (funcall kubect-exec-open-function buffer-name command args display-action)
      (pcase kubect-exec-backend
        ('term
         (kubect--open-term-exec-buffer buffer-name command args display-action))
        ('vterm
         (kubect--open-vterm-exec-buffer buffer-name command args display-action))
        ('eat
         (kubect--open-eat-exec-buffer buffer-name command args display-action))
        ('ghostel
         (kubect--open-ghostel-exec-buffer buffer-name command args display-action))
        (_
         (user-error "Unsupported kubect exec backend: %s" kubect-exec-backend))))))

(defun kubect--view-known-resource (kind name context namespace &optional arg)
  "View KIND NAME in CONTEXT and NAMESPACE."
  (let* ((kubect--display-buffer-action-override
          (kubect--display-action-from-prefix arg))
         (buffer-name (kubect--compilation-buffer-name (format "view %s" name) context namespace))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (kubect-view-mode)
      (setq-local kubect--view-target
                  (list :kind kind :name name :context context :namespace namespace))
      (setq-local revert-buffer-function
                  (lambda (&rest _ignore) (kubect-view-refresh)))
      (kubect-view-refresh))
    (kubect--display-buffer buffer)))

(defun kubect--service-url-lines (name context namespace)
  "Return best-effort URL lines for service NAME."
  (let* ((data (apply #'kubect--kubectl-json
                      (append (kubect--kubectl-base-args context namespace)
                              (list "get" "service" name "-o" "json"))))
         (ports (alist-get 'ports (alist-get 'spec data)))
         (cluster-host (format "%s.%s.svc.cluster.local" name namespace))
         (lb-ingress (alist-get 'ingress (alist-get 'loadBalancer (alist-get 'status data))))
         (lb-hosts (delq nil
                         (mapcar (lambda (entry)
                                   (or (alist-get 'hostname entry)
                                       (alist-get 'ip entry)))
                                 lb-ingress)))
         (hosts (delete-dups (append lb-hosts (list cluster-host)))))
    (cl-loop for host in hosts
             append
             (cl-loop for port in ports
                      for port-number = (alist-get 'port port)
                      for scheme = (if (member port-number '(443 8443)) "https" "http")
                      collect (format "%s://%s:%s" scheme host port-number)))))

(defun kubect--ingress-url-lines (name context namespace)
  "Return best-effort URL lines for ingress NAME."
  (let* ((data (apply #'kubect--kubectl-json
                      (append (kubect--kubectl-base-args context namespace)
                              (list "get" "ingress" name "-o" "json"))))
         (tls-hosts (delete-dups
                     (cl-mapcan (lambda (entry)
                                  (copy-sequence (alist-get 'hosts entry)))
                                (alist-get 'tls (alist-get 'spec data)))))
         (rules (alist-get 'rules (alist-get 'spec data))))
    (cl-loop for rule in rules
             for host = (or (alist-get 'host rule) "")
             append
             (let ((paths (alist-get 'paths (alist-get 'http rule))))
               (if paths
                   (cl-loop for path-entry in paths
                            for path = (or (alist-get 'path path-entry) "/")
                            collect
                            (format "%s://%s%s"
                                    (if (member host tls-hosts) "https" "http")
                                    host
                                    (if (string-prefix-p "/" path) path (concat "/" path))))
                 (list (format "%s://%s/"
                               (if (member host tls-hosts) "https" "http")
                               host)))))))

(defun kubect--resource-url-lines (kind name context namespace)
  "Return best-effort URL lines for KIND NAME."
  (pcase (downcase kind)
    ((or "service" "services")
     (kubect--service-url-lines name context namespace))
    ((or "ingress" "ingresses")
     (kubect--ingress-url-lines name context namespace))
    (_ nil)))

(defun kubect-resource-urls (&optional arg)
  "Show best-effort URLs for the current service or ingress."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist))
               (lines (kubect--resource-url-lines kind name context namespace)))
    (unless lines
      (user-error "No URL helper for %s" kind))
    (kubect--record-session-command "urls" (format "%s/%s" kind name))
    (kill-new (mapconcat #'identity lines "\n"))
    (kubect--show-report-buffer
     (format "urls %s" name)
     (concat (format "== %s/%s ==\n\n" kind name)
             (string-join lines "\n")
             "\n")
     context namespace arg
     "URLs: O open one, A open all, w copy one, W copy all, q quit"
     (list :urls lines :kind kind :name name))
    (message "Copied %d URL%s to kill-ring"
             (length lines)
             (if (= (length lines) 1) "" "s"))))

(defun kubect-resource-open-url ()
  "Open a best-effort resource URL in a browser."
  (interactive)
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist))
               (lines (kubect--resource-url-lines kind name context namespace)))
    (unless lines
      (user-error "No URL helper for %s" kind))
    (let ((url (or (when-let* ((line (string-trim
                                      (buffer-substring-no-properties
                                       (line-beginning-position)
                                       (line-end-position)))))
                     (and (member line lines) line))
                   (if (= (length lines) 1)
                       (car lines)
                     (kubect--completing-read "Open URL: " lines)))))
      (kubect--record-session-command "open-url" url)
      (browse-url url))))

(defun kubect-view-resource (&optional arg)
  "View the manifest of the resource at point."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist)))
    (kubect--record-session-command "view" (format "%s/%s" kind name))
    (kubect--view-known-resource kind name context namespace arg)))

(defun kubect-events-for-resource-at-point (&optional arg)
  "Open events for the resource at point, or prompt for one."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--resource-for-command)))
    (kubect--events-for-resource kind name context namespace arg)))

(defun kubect-events-for-resource (&optional arg)
  "Open events for the resource at point in the current session."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist)))
    (kubect--record-session-command "events-for" (format "%s/%s" kind name))
    (kubect--events-for-resource kind name context namespace arg)))

(defun kubect--marked-resource-plists (session)
  "Return marked resource plists for SESSION."
  (mapcar
   (lambda (identifier)
     (pcase-let* ((`(,kind ,name) (split-string identifier "/" t)))
       (list :kind kind
             :name name
             :context (kubect-session-context session)
             :namespace (kubect-session-namespace session))))
   (kubect-session-marked-resources session)))

(defun kubect--rollout-resource-p (kind)
  "Return non-nil when KIND supports rollout status."
  (member kind '("deployment" "deployments"
                 "daemonset" "daemonsets"
                 "statefulset" "statefulsets")))

(defun kubect--deployment-replicasets (deployment context namespace)
  "Return ReplicaSets owned by DEPLOYMENT in CONTEXT and NAMESPACE.
The result is sorted by numeric rollout revision."
  (let* ((data (kubect--kubectl-json
                "--context" context
                "--namespace" namespace
                "get" "replicasets" "-o" "json"))
         (items (alist-get 'items data)))
    (sort
     (cl-loop for item in items
              for metadata = (alist-get 'metadata item)
              for owners = (alist-get 'ownerReferences metadata)
              for owner = (cl-find-if
                           (lambda (entry)
                             (and (string= (alist-get 'kind entry) "Deployment")
                                  (string= (alist-get 'name entry) deployment)))
                           owners)
              when owner
              collect (list :name (alist-get 'name metadata)
                            :revision (string-to-number
                                       (or (alist-get 'deployment.kubernetes.io/revision
                                                      (alist-get 'annotations metadata)
                                                      nil nil #'equal)
                                           "0"))))
     (lambda (a b)
       (< (plist-get a :revision) (plist-get b :revision))))))

(defun kubect--rollout-diff-buffer (old-name new-name old-body new-body context namespace &optional arg)
  "Display a diff between OLD-BODY and NEW-BODY for kubect rollout helpers."
  (let* ((old-file (make-temp-file "kubect-rollout-old-"))
         (new-file (make-temp-file "kubect-rollout-new-"))
         (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file old-file
            (insert old-body))
          (with-temp-file new-file
            (insert new-body))
          (setq buffer (diff-no-select old-file new-file "-u" t))
          (with-current-buffer buffer
            (setq-local header-line-format
                        (format "Rollout diff: %s -> %s (%s/%s)"
                                old-name new-name context namespace)))
          (let ((kubect--display-buffer-action-override
                 (kubect--display-action-from-prefix arg)))
            (kubect--display-buffer buffer)))
      (ignore-errors (delete-file old-file))
      (ignore-errors (delete-file new-file)))))

(defun kubect--bulk-resource-label (resource)
  "Return a human-readable label for RESOURCE."
  (format "%s/%s"
          (plist-get resource :kind)
          (plist-get resource :name)))

(defun kubect--bulk-review-buffer-name (action context namespace)
  "Return a buffer name for bulk ACTION in CONTEXT and NAMESPACE."
  (kubect--compilation-buffer-name (format "bulk %s" action) context namespace))

(defun kubect--bulk-review-render ()
  "Render the current bulk review buffer."
  (unless kubect-bulk-review-state
    (user-error "Current buffer is not a kubect bulk review"))
  (let ((action (plist-get kubect-bulk-review-state :action))
        (resources (plist-get kubect-bulk-review-state :resources))
        (filter (plist-get kubect-bulk-review-state :filter)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "Bulk %s review\n\n" action))
      (insert "RET opens entry.  o opens in other window.  a opens all.  m removes.  f filters.\n\n")
      (when filter
        (insert (format "Filter: %s\n\n" filter)))
      (dolist (resource resources)
        (insert (format "%s\n" (kubect--bulk-resource-label resource))))
      (goto-char (point-min))
      (forward-line (if filter 4 3)))))

(defun kubect-bulk-review-refresh ()
  "Refresh the current bulk review buffer."
  (interactive)
  (kubect--bulk-review-render))

(defun kubect--bulk-review-apply-filter (filter)
  "Apply FILTER to the current bulk review state."
  (unless kubect-bulk-review-state
    (user-error "Current buffer is not a kubect bulk review"))
  (let* ((all-resources (or (plist-get kubect-bulk-review-state :all-resources)
                            (plist-get kubect-bulk-review-state :resources)))
         (filtered (if (string-empty-p (or filter ""))
                       all-resources
                     (cl-remove-if-not
                      (lambda (resource)
                        (string-match-p (regexp-quote filter)
                                        (kubect--bulk-resource-label resource)))
                      all-resources))))
    (setf (plist-get kubect-bulk-review-state :all-resources) all-resources
          (plist-get kubect-bulk-review-state :resources) filtered
          (plist-get kubect-bulk-review-state :filter) (unless (string-empty-p (or filter "")) filter))))

(defun kubect-bulk-review-filter (filter)
  "Filter the current bulk review buffer by FILTER."
  (interactive
   (list (read-string "Bulk filter: " nil nil
                      (plist-get kubect-bulk-review-state :filter))))
  (kubect--bulk-review-apply-filter filter)
  (kubect--bulk-review-render))

(defun kubect-bulk-review-remove ()
  "Remove the current entry from this bulk review buffer."
  (interactive)
  (let* ((resource (kubect--bulk-review-resource-at-point))
         (resources (plist-get kubect-bulk-review-state :resources))
         (all-resources (or (plist-get kubect-bulk-review-state :all-resources) resources)))
    (setf (plist-get kubect-bulk-review-state :resources)
          (delete resource (copy-sequence resources))
          (plist-get kubect-bulk-review-state :all-resources)
          (delete resource (copy-sequence all-resources)))
    (kubect--bulk-review-render)
    (message "Removed %s from bulk review" (kubect--bulk-resource-label resource))))

(defun kubect--bulk-review-resource-at-point ()
  "Return the bulk review resource at point."
  (unless kubect-bulk-review-state
    (user-error "Current buffer is not a kubect bulk review"))
  (let ((label (string-trim-right
                (buffer-substring-no-properties
                 (line-beginning-position)
                 (line-end-position)))))
    (or (cl-find-if
         (lambda (resource)
           (equal label (kubect--bulk-resource-label resource)))
         (plist-get kubect-bulk-review-state :resources))
        (user-error "No bulk resource on this line"))))

(defun kubect--bulk-open-resource (action resource &optional arg)
  "Open ACTION for RESOURCE."
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace) resource))
    (pcase action
      ("events"
       (kubect--events-for-resource kind name context namespace arg))
      ("logs"
       (let* ((pod (or (kubect--pod-for-resource kind name context namespace)
                       (kubect--read-pod context namespace)))
              (container (kubect--read-container pod context namespace)))
         (kubect-logs pod container context namespace
                      (kubect--display-action-from-prefix arg))))
      ("debug"
       (let* ((pod (or (kubect--pod-for-resource kind name context namespace)
                       (kubect--read-pod context namespace)))
              (container (kubect--read-container pod context namespace)))
         (kubect--show-describe-resource "pod" pod context namespace arg)
         (kubect-logs-previous pod container context namespace
                               (kubect--display-action-from-prefix arg)))))))

(defun kubect-bulk-review-visit (&optional arg)
  "Open the bulk action for the current review entry."
  (interactive "P")
  (kubect--bulk-open-resource
   (plist-get kubect-bulk-review-state :action)
   (kubect--bulk-review-resource-at-point)
   arg))

(defun kubect-bulk-review-visit-other-window ()
  "Open the current review entry in another window."
  (interactive)
  (kubect-bulk-review-visit '(4)))

(defun kubect-bulk-review-visit-all (&optional arg)
  "Open the bulk action for every entry in the current review buffer."
  (interactive "P")
      (dolist (resource (plist-get kubect-bulk-review-state :resources))
    (kubect--bulk-open-resource
     (plist-get kubect-bulk-review-state :action)
     resource
     arg)))

(defun kubect--show-bulk-review (action resources &optional arg)
  "Show a bulk review buffer for ACTION over RESOURCES."
  (let* ((first (car resources))
         (context (plist-get first :context))
         (namespace (plist-get first :namespace))
         (buffer (get-buffer-create
                  (kubect--bulk-review-buffer-name action context namespace))))
    (with-current-buffer buffer
      (kubect-bulk-review-mode)
      (setq-local kubect-bulk-review-state
                  (list :action action :resources resources :all-resources resources))
      (kubect--bulk-review-render))
    (let ((kubect--display-buffer-action-override
           (kubect--display-action-from-prefix arg)))
      (kubect--display-buffer buffer))))

(defun kubect--event-summary-lines-for-resource (resource)
  "Return formatted event summary lines for RESOURCE."
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace) resource)
               (data (apply #'kubect--kubectl-json
                            (append (kubect--kubectl-base-args context namespace)
                                    '("get" "events" "--sort-by=.lastTimestamp" "-o" "json"))))
               (items (alist-get 'items data)))
    (cl-loop for item in items
             for obj = (alist-get 'involvedObject item)
             when (and (equal (downcase (or (alist-get 'kind obj) "")) (kubect--singular-kind kind))
                       (equal (alist-get 'name obj) name))
             collect
             (format "%s  %s  %s  %s"
                     (or (alist-get 'lastTimestamp item) "")
                     (or (alist-get 'type item) "")
                     (or (alist-get 'reason item) "")
                     (or (alist-get 'message item) "")))))

(defun kubect--show-bulk-event-summary (resources &optional arg)
  "Show a consolidated event summary for RESOURCES."
  (let* ((first (car resources))
         (context (plist-get first :context))
         (namespace (plist-get first :namespace))
         (buffer (get-buffer-create
                  (kubect--compilation-buffer-name "bulk event summary" context namespace))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (resource resources)
          (let ((identifier (kubect--bulk-resource-label resource))
                (lines (kubect--event-summary-lines-for-resource resource)))
            (insert (format "== %s ==\n\n" identifier))
            (if lines
                (dolist (line lines)
                  (insert line "\n"))
              (insert "No events\n"))
            (insert "\n")))
        (goto-char (point-min)))
      (kubect-report-mode))
    (let ((kubect--display-buffer-action-override
           (kubect--display-action-from-prefix arg)))
      (kubect--display-buffer buffer))))

(defun kubect--show-bulk-describe (resources &optional arg)
  "Show a consolidated describe report for RESOURCES."
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

(defun kubect--rfc3339-minus-seconds (timestamp seconds)
  "Return TIMESTAMP minus SECONDS in RFC3339 UTC form."
  (format-time-string
   "%Y-%m-%dT%H:%M:%SZ"
   (time-subtract (date-to-time timestamp) (seconds-to-time seconds))
   t))

(defun kubect--pod-json (pod context namespace)
  "Return JSON data for POD."
  (apply #'kubect--kubectl-json
         (append (kubect--kubectl-base-args context namespace)
                 (list "get" "pod" pod "-o" "json"))))

(defun kubect--pod-container-statuses (pod context namespace)
  "Return container status alists for POD."
  (alist-get 'containerStatuses
             (alist-get 'status (kubect--pod-json pod context namespace))))

(defun kubect--container-status-priority (status)
  "Return a priority score for container STATUS."
  (let* ((restart-count (or (alist-get 'restartCount status) 0))
         (ready (alist-get 'ready status))
         (waiting-reason (alist-get 'reason (alist-get 'waiting (alist-get 'state status))))
         (last-terminated (alist-get 'terminated (alist-get 'lastState status)))
         (terminated-reason (alist-get 'reason last-terminated)))
    (+ (cond
        ((member waiting-reason '("CrashLoopBackOff" "ImagePullBackOff" "ErrImagePull"
                                  "CreateContainerConfigError" "CreateContainerError"
                                  "RunContainerError"))
         4000)
        ((member terminated-reason '("OOMKilled" "Error" "ContainerCannotRun"))
         3000)
        ((not ready) 1000)
        (t 0))
       restart-count)))

(defun kubect--best-container-name (pod context namespace)
  "Return the most suspicious container name for POD."
  (when-let* ((statuses (kubect--pod-container-statuses pod context namespace)))
    (alist-get
     'name
     (car (sort (copy-sequence statuses)
                (lambda (left right)
                  (> (kubect--container-status-priority left)
                     (kubect--container-status-priority right))))))))

(defun kubect--pod-container-status (pod container context namespace)
  "Return the most relevant container status alist for POD."
  (let ((statuses (kubect--pod-container-statuses pod context namespace)))
    (or (and container
             (cl-find-if (lambda (entry)
                           (equal (alist-get 'name entry) container))
                         statuses))
        (car statuses))))

(defun kubect--select-container-for-pod (pod context namespace &optional incident)
  "Return a container name for POD.
When INCIDENT is non-nil, prefer the most suspicious container automatically."
  (let ((containers (kubect--list-containers pod context namespace)))
    (cond
     ((null containers) nil)
     ((= (length containers) 1)
      (kubect--remember-recent :recent-containers (car containers))
      (car containers))
     (incident
      (let ((container (or (kubect--best-container-name pod context namespace)
                           (kubect--project-default :default-container)
                           (car containers))))
        (kubect--session-remember :recent-containers container)
        (kubect--remember-recent :recent-containers container)
        container))
     (t
      (kubect--read-container pod context namespace)))))

(defun kubect--resource-rollout-since-time (kind name context namespace)
  "Return a rollout-related timestamp for KIND NAME when available."
  (when (kubect--rollout-resource-p kind)
    (let* ((data (apply #'kubect--kubectl-json
                        (append (kubect--kubectl-base-args context namespace)
                                (list "get" kind name "-o" "json"))))
           (template-annotations
            (alist-get 'annotations
                       (alist-get 'metadata
                                  (alist-get 'template
                                             (alist-get 'spec data)))))
           (root-annotations
            (alist-get 'annotations (alist-get 'metadata data)))
           (conditions (alist-get 'conditions (alist-get 'status data))))
      (or (alist-get 'kubectl.kubernetes.io/restartedAt template-annotations nil nil #'equal)
          (alist-get 'kubectl.kubernetes.io/restartedAt root-annotations nil nil #'equal)
          (cl-some (lambda (entry)
                     (when (member (alist-get 'type entry)
                                   '("Progressing" "Available" "Ready" "Updated"))
                       (or (alist-get 'lastUpdateTime entry)
                           (alist-get 'lastTransitionTime entry))))
                   conditions)))))

(defun kubect-describe-resource (&optional arg)
  "Describe the resource at point in the current session."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist)))
    (kubect--record-session-command "describe" (format "%s/%s" kind name))
    (kubect--show-describe-resource kind name context namespace arg)))

(defun kubect-edit-resource (&optional arg)
  "Open the YAML for the resource at point in an editable buffer."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--resource-plist-from-session))
               (buffer (get-buffer-create
                        (format "*kubect edit %s/%s*" kind name))))
    (with-current-buffer buffer
      (erase-buffer)
      (insert
       (kubect--kubectl-output
        "--context" context
        "--namespace" namespace
        "get" kind name "-o" "yaml"))
      (if (fboundp 'yaml-mode)
          (yaml-mode)
        (text-mode))
      (kubect-ops-mode 1)
      (setq-local kubect--edit-target
                  (list :kind kind :name name :context context :namespace namespace))
      (kubect--prepare-edit-buffer-keymap)
      (local-set-key (kbd "C-c C-c") #'kubect-apply-edit-buffer)
      (goto-char (point-min)))
    (kubect--record-session-command "edit" (format "%s/%s" kind name))
    (let ((kubect--display-buffer-action-override
           (kubect--display-action-from-prefix arg)))
      (kubect--display-buffer buffer))))

(defvar-local kubect--edit-target nil)

(defun kubect--remote-shell-output (context namespace pod container command)
  "Run shell COMMAND inside POD and return stdout."
  (apply #'kubect--kubectl-output
         (append (kubect--kubectl-base-args context namespace)
                 (list "exec" pod)
                 (when container
                   (list "-c" container))
                 (list "--" "sh" "-lc" command))))

(defun kubect--run-remote-shell-command (context namespace pod container command)
  "Run shell COMMAND inside POD and ignore stdout."
  (apply #'kubect--kubectl-output
         (append (kubect--kubectl-base-args context namespace)
                 (list "exec" pod)
                 (when container
                   (list "-c" container))
                 (list "--" "sh" "-lc" command))))

(defun kubect--file-browser-buffer-name (pod path)
  "Return the buffer name for POD browsing PATH."
  (format "*kubect files %s:%s*" pod path))

(defun kubect--remote-listing-command (path)
  "Return a shell command that lists one level below PATH."
  (format
   "cd %s 2>/dev/null && for item in .* *; do [ \"$item\" = \".\" ] && continue; [ \"$item\" = \"..\" ] && continue; [ ! -e \"$item\" ] && continue; if [ -d \"$item\" ]; then printf 'd\\t%%s\\n' \"$item\"; else printf 'f\\t%%s\\n' \"$item\"; fi; done"
   (shell-quote-argument path)))

(defun kubect-file-browser-refresh ()
  "Refresh the current pod file browser."
  (interactive)
  (unless kubect-file-browser-state
    (user-error "Current buffer is not a kubect file browser"))
  (pcase-let* ((`(:context ,context :namespace ,namespace :pod ,pod :container ,container :path ,path)
                kubect-file-browser-state)
               (output (kubect--remote-shell-output
                        context namespace pod container
                        (kubect--remote-listing-command path))))
    (setq header-line-format
          (format " kubect files  %s/%s  pod=%s%s  path=%s"
                  context namespace pod
                  (if container (format "  container=%s" container) "")
                  path))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "../\n")
      (dolist (line (split-string output "\n" t))
        (pcase-let ((`(,type ,name) (split-string line "\t" t)))
          (insert (if (string= type "d")
                      (format "%s/\n" name)
                    (format "%s\n" name)))))
      (goto-char (point-min))
      (forward-line 1))))

(defun kubect--file-browser-entry ()
  "Return the entry at point in the current file browser."
  (string-trim-right
   (buffer-substring-no-properties
    (line-beginning-position)
    (line-end-position))))

(defun kubect--file-browser-entry-path ()
  "Return the absolute in-pod path for the entry at point."
  (let ((entry (kubect--file-browser-entry))
        (base (plist-get kubect-file-browser-state :path)))
    (unless (string= entry "../")
      (expand-file-name
       (if (string-suffix-p "/" entry)
           (directory-file-name entry)
         entry)
       base))))

(defun kubect-file-browser-up ()
  "Go to the parent directory in the current pod file browser."
  (interactive)
  (unless kubect-file-browser-state
    (user-error "Current buffer is not a kubect file browser"))
  (let ((path (plist-get kubect-file-browser-state :path)))
    (setf (plist-get kubect-file-browser-state :path)
          (if (string= path "/")
              "/"
            (or (file-name-directory (directory-file-name path))
                "/")))
    (kubect-file-browser-refresh)))

(defun kubect--open-remote-file (context namespace pod container path &optional arg)
  "Open remote file PATH from POD."
  (let ((buffer (get-buffer-create
                 (format "*kubect file %s:%s*" pod path))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (apply #'kubect--kubectl-output
                       (append (kubect--kubectl-base-args context namespace)
                               (list "exec" pod)
                               (when container
                                 (list "-c" container))
                               (list "--" "cat" path)))))
      (setq-local kubect--remote-file-target
                  (list :context context :namespace namespace :pod pod
                        :container container :path path
                        :session (kubect--current-history-session)))
      (set-auto-mode)
      (kubect-ops-mode 1)
      (kubect--prepare-edit-buffer-keymap)
      (local-set-key (kbd "C-c C-c") #'kubect-save-remote-file)
      (goto-char (point-min)))
    (kubect--record-session-command "file-open" path)
    (let ((kubect--display-buffer-action-override
           (kubect--display-action-from-prefix arg)))
      (kubect--display-buffer buffer))))

(defun kubect-file-browser-edit-file (&optional arg)
  "Open the file at point from the current browser."
  (interactive "P")
  (unless kubect-file-browser-state
    (user-error "Current buffer is not a kubect file browser"))
  (pcase-let* ((entry (kubect--file-browser-entry))
               (`(:context ,context :namespace ,namespace :pod ,pod :container ,container :path ,path)
                kubect-file-browser-state))
    (cond
     ((string= entry "../")
      (kubect-file-browser-up))
     ((string-suffix-p "/" entry)
      (user-error "Point is on a directory, use RET"))
     (t
      (kubect--open-remote-file context namespace pod container
                                (expand-file-name entry path)
                                arg)))))

(defun kubect-file-browser-visit (&optional arg)
  "Visit the file or directory at point from the current browser."
  (interactive "P")
  (unless kubect-file-browser-state
    (user-error "Current buffer is not a kubect file browser"))
  (let ((entry (kubect--file-browser-entry)))
    (cond
     ((string= entry "../")
      (kubect-file-browser-up))
     ((string-suffix-p "/" entry)
      (setf (plist-get kubect-file-browser-state :path)
            (expand-file-name (directory-file-name entry)
                              (plist-get kubect-file-browser-state :path)))
      (kubect-file-browser-refresh))
     (t
     (kubect-file-browser-edit-file arg)))))

(defun kubect-file-browser-create (name)
  "Create a file or directory NAME in the current pod browser.
Names ending with `/` create directories."
  (interactive
   (list (read-string "Create path (append / for directory): ")))
  (unless kubect-file-browser-state
    (user-error "Current buffer is not a kubect file browser"))
  (pcase-let* ((`(:context ,context :namespace ,namespace :pod ,pod :container ,container :path ,path)
                kubect-file-browser-state)
               (target (expand-file-name
                        (if (string-suffix-p "/" name)
                            (directory-file-name name)
                          name)
                        path))
               (command (if (string-suffix-p "/" name)
                            (format "mkdir -p %s" (shell-quote-argument target))
                          (format "touch %s" (shell-quote-argument target)))))
    (when (kubect--confirm-write (format "Create remote path %s" target) context namespace)
      (kubect--run-remote-shell-command context namespace pod container command)
      (kubect--record-session-command "file-create" target)
      (kubect-file-browser-refresh)
      (message "Created %s" target))))

(defun kubect-file-browser-delete ()
  "Delete the file or directory at point in the pod browser."
  (interactive)
  (unless kubect-file-browser-state
    (user-error "Current buffer is not a kubect file browser"))
  (let* ((entry (kubect--file-browser-entry))
         (target (kubect--file-browser-entry-path)))
    (when (or (null target) (string= entry "../"))
      (user-error "No deletable entry at point"))
    (when (kubect--confirm-write (format "Delete remote path %s" target)
                                 (plist-get kubect-file-browser-state :context)
                                 (plist-get kubect-file-browser-state :namespace))
      (pcase-let* ((`(:context ,context :namespace ,namespace :pod ,pod :container ,container)
                    kubect-file-browser-state))
        (kubect--run-remote-shell-command
         context namespace pod container
         (format "rm -rf %s" (shell-quote-argument target)))
        (kubect--record-session-command "file-delete" target)
        (kubect-file-browser-refresh)
        (message "Deleted %s" target)))))

(defun kubect-file-browser-rename (new-name)
  "Rename the entry at point to NEW-NAME in the pod browser."
  (interactive
   (list (read-string "Rename to: " (kubect--file-browser-entry))))
  (unless kubect-file-browser-state
    (user-error "Current buffer is not a kubect file browser"))
  (let* ((entry (kubect--file-browser-entry))
         (source (kubect--file-browser-entry-path)))
    (when (or (null source) (string= entry "../"))
      (user-error "No renamable entry at point"))
    (pcase-let* ((`(:context ,context :namespace ,namespace :pod ,pod :container ,container :path ,path)
                  kubect-file-browser-state)
                 (target (expand-file-name
                          (if (string-suffix-p "/" new-name)
                              (directory-file-name new-name)
                            new-name)
                          path)))
      (when (kubect--confirm-write (format "Rename remote path %s to %s" source target)
                                   context namespace)
        (kubect--run-remote-shell-command
         context namespace pod container
         (format "mv %s %s"
                 (shell-quote-argument source)
                 (shell-quote-argument target)))
        (kubect--record-session-command "file-rename" (format "%s -> %s" source target))
        (kubect-file-browser-refresh)
        (message "Renamed %s to %s" source target)))))

(defun kubect-save-remote-file ()
  "Save the current remote file buffer back into the pod."
  (interactive)
  (unless kubect--remote-file-target
    (user-error "Current buffer is not a kubect remote file"))
  (pcase-let* ((`(:context ,context :namespace ,namespace :pod ,pod :container ,container :path ,path)
                kubect--remote-file-target)
               (tmp-file (make-temp-file "kubect-remote-file-")))
    (when (kubect--confirm-write (format "Save remote file %s" path) context namespace)
      (write-region nil nil tmp-file nil 'silent)
      (unwind-protect
          (progn
            (apply #'kubect--kubectl-output
                   (append (list "--context" context "cp" tmp-file
                                 (format "%s/%s:%s" namespace pod path))
                           (when container
                             (list "-c" container))))
            (set-buffer-modified-p nil)
            (message "Saved %s back to %s/%s" path namespace pod))
        (ignore-errors (delete-file tmp-file))))))

(defun kubect-browse-files (&optional arg)
  "Browse files inside a pod, using the current session when possible."
  (interactive "P")
  (let* ((resource (ignore-errors (kubect--resource-plist-from-session)))
         (context (or (plist-get resource :context) (kubect-current-context)))
         (namespace (or (plist-get resource :namespace) (kubect-current-namespace)))
         (kind (plist-get resource :kind))
         (name (plist-get resource :name))
         (pod (or (and kind name (kubect--pod-for-resource kind name context namespace))
                  (kubect--read-pod context namespace)))
         (container (kubect--read-container pod context namespace))
         (path (or (kubect--project-default :file-root)
                   kubect-file-browser-default-path))
         (buffer (get-buffer-create (kubect--file-browser-buffer-name pod path))))
    (with-current-buffer buffer
      (kubect-file-browser-mode)
      (setq-local kubect-file-browser-state
                  (list :context context :namespace namespace :pod pod
                        :container container :path path
                        :session (kubect--current-history-session)))
      (kubect-file-browser-refresh))
    (kubect--record-session-command "files" (format "%s:%s" pod path))
    (let ((kubect--display-buffer-action-override
           (kubect--display-action-from-prefix arg)))
      (kubect--display-buffer buffer))))

(defun kubect-apply-edit-buffer ()
  "Apply the current edit buffer back to Kubernetes."
  (interactive)
  (unless kubect--edit-target
    (user-error "Current buffer is not a kubect edit buffer"))
  (pcase-let* ((`(:context ,context :namespace ,namespace :name ,name)
                kubect--edit-target))
    (when (kubect--confirm-write (format "Apply edited resource %s" name) context namespace)
      (let ((tmp-file (make-temp-file "kubect-edit-" nil ".yaml")))
        (write-region nil nil tmp-file nil 'silent)
        (unwind-protect
            (compilation-start
             (kubect--shell-command
              (append (kubect--kubectl-base-args context namespace)
                      (list "apply" "-f" tmp-file)))
             'compilation-mode
             (lambda (_) (kubect--compilation-buffer-name (format "apply %s" name) context namespace)))
          (run-at-time 5 nil (lambda (file) (ignore-errors (delete-file file))) tmp-file))))))

(defun kubect--read-pod (&optional context namespace)
  "Prompt for a pod in CONTEXT and NAMESPACE."
  (let ((pod (kubect--completing-read
              "Pod: "
              (kubect--prioritize-recent
               (kubect--list-resource-names "pods" context namespace)
               (append (when-let* ((session (kubect--current-session)))
                         (kubect-session-recent-pods session))
                       (kubect--recent-values :recent-pods))))))
    (kubect--session-remember :recent-pods pod)
    (kubect--remember-recent :recent-pods pod)
    pod))

(defun kubect--read-container (pod &optional context namespace)
  "Prompt for a POD container if needed."
  (let ((containers (kubect--list-containers pod context namespace)))
    (cond
     ((null containers) nil)
     ((= (length containers) 1)
      (kubect--remember-recent :recent-containers (car containers))
      (car containers))
     (t
      (let ((container
             (kubect--completing-read
              "Container: "
              (kubect--prioritize-recent
               containers
               (append (when-let* ((session (kubect--current-session)))
                         (kubect-session-recent-containers session))
                       (kubect--recent-values :recent-containers)))
              (or (kubect--project-default :default-container)
                  (car containers)))))
        (kubect--session-remember :recent-containers container)
        (kubect--remember-recent :recent-containers container)
        container)))))

(defvar kubect--selector-history nil
  "Minibuffer history for kubect label selectors.")

(defun kubect-set-context (context)
  "Set project-local Kubernetes CONTEXT."
  (interactive
   (list (kubect--completing-read "Context: " (kubect--list-contexts))))
  (kubect--set-project-state :context context)
  (when (and (derived-mode-p 'kubect-session-mode) kubect-session)
    (kubect--session-change-scope context (kubect-session-namespace kubect-session)
                                  (kubect-session-resource kubect-session) "context" context))
  (message "Kubernetes context set to %s" context))

(defun kubect-set-namespace (namespace)
  "Set project-local Kubernetes NAMESPACE and update the active browser."
  (interactive
   (list (kubect--read-namespace)))
  (kubect--set-project-state :namespace namespace)
  (when (and (derived-mode-p 'kubect-session-mode) kubect-session)
    (kubect--session-change-namespace namespace))
  (message "Kubernetes namespace set to %s" namespace))

(defun kubect-set-resource (resource)
  "Set project-local Kubernetes RESOURCE."
  (interactive
   (list (kubect--read-kind (kubect-current-resource))))
  (kubect--set-project-state :resource resource)
  (when (and (derived-mode-p 'kubect-session-mode) kubect-session)
    (kubect--session-change-scope (kubect-session-context kubect-session)
                                  (kubect-session-namespace kubect-session)
                                  resource "resource" resource))
  (message "Kubernetes resource set to %s" resource))

(defun kubect-status ()
  "Show the active Kubernetes project state."
  (interactive)
  (message "Kubect project=%s context=%s namespace=%s resource=%s"
           (or (kubect--project-root) default-directory)
           (kubect-current-context)
           (kubect-current-namespace)
           (kubect-current-resource)))

(defun kubect-apply-buffer ()
  "Apply the current buffer with kubectl."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (when (kubect--confirm-write "Apply current buffer")
    (save-buffer)
    (compilation-start
     (kubect--shell-command
      (append (kubect--kubectl-base-args)
              (list "apply" "-f" buffer-file-name)))
     'compilation-mode
     (lambda (_) (kubect--compilation-buffer-name "apply")))))

(defun kubect-diff-buffer ()
  "Show `kubectl diff` for the current buffer."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (save-buffer)
  (compilation-start
   (kubect--shell-command
    (append (kubect--kubectl-base-args)
            (list "diff" "-f" buffer-file-name)))
   'compilation-mode
   (lambda (_) (kubect--compilation-buffer-name "diff"))))

(defun kubect-describe-resource-at-point (&optional arg)
  "Describe the resource at point, or prompt for one."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--resource-for-command)))
    (kubect--show-describe-resource kind name context namespace arg)))

(defun kubect-explain-resource-at-point ()
  "Explain the resource kind at point, or prompt for one."
  (interactive)
  (let* ((resource (kubect--resource-at-point))
         (yaml-kind (ignore-errors
                      (when-let* ((kind (kubect--yaml-top-level-value "kind")))
                        (downcase kind))))
         (field-path (ignore-errors (kubect--yaml-field-path-at-point)))
         (kind (kubect--singular-kind
                (or yaml-kind
                    (plist-get resource :kind)
                    (kubect--read-kind (kubect-current-resource)))))
         (subject (if (and field-path (not (string-empty-p field-path)))
                      (format "%s.%s" kind field-path)
                    kind)))
    (compilation-start
     (kubect--shell-command
      (append (kubect--kubectl-base-args)
              (list "explain" subject)))
     'compilation-mode
     (lambda (_) (kubect--compilation-buffer-name (format "explain %s" subject))))))

(defun kubect-exec-shell (pod &optional container context namespace display-action)
  "Open an interactive shell into POD and optional CONTAINER."
  (interactive
   (let* ((pod (kubect--read-pod))
          (container (kubect--read-container pod)))
     (list pod container nil nil
           (kubect--display-action-from-prefix current-prefix-arg))))
  (let* ((context (or context (kubect-current-context)))
         (namespace (or namespace (kubect-current-namespace)))
         (buffer-name (format "*kubect exec %s/%s:%s*"
                              context namespace pod))
         (args (append (kubect--kubectl-base-args context namespace)
                       (list "exec" "-it" pod)
                       (when container
                         (list "-c" container))
                       (list "--" kubect-default-shell))))
    (when (kubect--confirm-write (format "Open exec shell in pod %s" pod) context namespace)
      (kubect--record-session-command
       "exec"
       (if container
           (format "%s/%s" pod container)
         pod))
      (kubect--open-exec-buffer buffer-name args display-action))))

(defun kubect-exec-resource (&optional arg)
  "Exec into the pod at point or prompt for a pod in the session."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist))
               (pod (or (kubect--pod-for-resource kind name context namespace)
                        (kubect--read-pod context namespace)))
               (container (kubect--read-container pod context namespace)))
    (kubect-exec-shell pod container context namespace
                       (kubect--display-action-from-prefix arg))))

(defun kubect-rollout-restart (deployment &optional context namespace)
  "Restart DEPLOYMENT in CONTEXT and NAMESPACE."
  (interactive
   (list (kubect--completing-read
          "Deployment: "
          (kubect--list-resource-names "deployments"))))
  (let ((context (or context (kubect-current-context)))
        (namespace (or namespace (kubect-current-namespace))))
    (when (kubect--confirm-write (format "Restart deployment %s" deployment) context namespace)
      (kubect--record-session-command "rollout-restart" deployment)
      (compilation-start
       (kubect--shell-command
        (append (kubect--kubectl-base-args context namespace)
                (list "rollout" "restart" (format "deployment/%s" deployment))))
       'compilation-mode
       (lambda (_) (kubect--compilation-buffer-name (format "restart %s" deployment) context namespace))))))

(defun kubect-rollout-restart-resource ()
  "Restart the deployment at point, if any."
  (interactive)
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--resource-plist-from-session)))
    (unless (member kind '("deployments" "deployment"))
      (user-error "Rollout restart is only available for deployments"))
    (kubect-rollout-restart name context namespace)))

(defun kubect-rollout-history (deployment &optional context namespace)
  "Show rollout history for DEPLOYMENT in CONTEXT and NAMESPACE."
  (interactive
   (list (kubect--completing-read
          "Deployment: "
          (kubect--list-resource-names "deployments"))))
  (compilation-start
   (progn
     (kubect--record-session-command "rollout-history" deployment)
   (kubect--shell-command
    (append (kubect--kubectl-base-args context namespace)
            (list "rollout" "history" (format "deployment/%s" deployment)))))
   'compilation-mode
   (lambda (_) (kubect--compilation-buffer-name (format "history %s" deployment) context namespace))))

(defun kubect-rollout-history-resource ()
  "Show rollout history for the deployment at point."
  (interactive)
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--resource-plist-from-session)))
    (unless (member kind '("deployments" "deployment"))
      (user-error "Rollout history is only available for deployments"))
    (kubect-rollout-history name context namespace)))

(defun kubect-rollout-diff (deployment &optional context namespace arg)
  "Compare the latest two ReplicaSet revisions for DEPLOYMENT."
  (interactive
   (list (kubect--completing-read
          "Deployment: "
          (kubect--list-resource-names "deployments"))
         nil nil current-prefix-arg))
  (let* ((context (or context (kubect-current-context)))
         (namespace (or namespace (kubect-current-namespace)))
         (replicasets (kubect--deployment-replicasets deployment context namespace))
         (latest-two (last replicasets 2)))
    (unless (= (length latest-two) 2)
      (user-error "Need at least two deployment revisions to compare"))
    (pcase-let* ((`(,old ,new) latest-two)
                 (old-name (plist-get old :name))
                 (new-name (plist-get new :name))
                 (old-revision (plist-get old :revision))
                 (new-revision (plist-get new :revision))
                 (old-data (kubect--kubectl-json
                            "--context" context
                            "--namespace" namespace
                            "get" "replicaset" old-name "-o" "json"))
                 (new-data (kubect--kubectl-json
                            "--context" context
                            "--namespace" namespace
                            "get" "replicaset" new-name "-o" "json"))
                 (old-body (kubect--json-pretty-string
                            (alist-get 'template (alist-get 'spec old-data))))
                 (new-body (kubect--json-pretty-string
                            (alist-get 'template (alist-get 'spec new-data)))))
      (kubect--record-session-command
       "rollout-diff"
       (format "%s r%d->r%d" deployment old-revision new-revision))
      (kubect--rollout-diff-buffer
       (format "%s (r%d) pod template" old-name old-revision)
       (format "%s (r%d) pod template" new-name new-revision)
       old-body new-body context namespace arg))))

(defun kubect-rollout-diff-resource (&optional arg)
  "Compare the latest two rollout revisions for the deployment at point."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--resource-plist-from-session)))
    (unless (member kind '("deployments" "deployment"))
      (user-error "Rollout diff is only available for deployments"))
    (kubect-rollout-diff name context namespace arg)))

(defun kubect-port-forward (resource local-port remote-port &optional context namespace display-action)
  "Port-forward RESOURCE from LOCAL-PORT to REMOTE-PORT."
  (interactive
   (let* ((kind (kubect--completing-read "Forward kind: " '("pods" "services" "deployments")))
          (name (kubect--completing-read
                 (format "%s: " (capitalize kind))
                 (kubect--list-resource-names kind)))
          (local (read-string "Local port: " "8080"))
          (remote (read-string "Remote port: " local)))
     (list (format "%s/%s" kind name) local remote nil nil
           (kubect--display-action-from-prefix current-prefix-arg))))
  (let ((kubect--display-buffer-action-override display-action))
    (when (kubect--confirm-write
           (format "Port-forward %s from local %s to remote %s" resource local-port remote-port)
           context namespace)
      (kubect--record-session-command
       "port-forward"
       (format "%s %s:%s" resource local-port remote-port))
      (kubect--start-stream
       (format "port-forward %s" resource)
       (append (kubect--kubectl-base-args context namespace)
               (list "port-forward" resource (format "%s:%s" local-port remote-port)))
       context namespace))))

(defun kubect-port-forward-resource (&optional arg)
  "Port-forward the resource at point when supported."
  (interactive "P")
  (pcase-let* ((`(:kind ,kind :name ,name :context ,context :namespace ,namespace)
                (kubect--current-line-resource-plist)))
    (unless (member kind '("pods" "services" "deployments"))
      (user-error "Port-forward supports pods, services, and deployments"))
    (let* ((local (read-string "Local port: " "8080"))
           (remote (read-string "Remote port: " local)))
      (kubect-port-forward (format "%s/%s" kind name) local remote context namespace
                           (kubect--display-action-from-prefix arg)))))

(when (featurep 'transient)
  (transient-define-prefix kubect-incident-dispatch ()
    "Incident-focused actions for the current resource or event row."
    [["Incident"
     ("l" "Incident logs" kubect-incident-logs-resource)
      ("L" "Previous logs" kubect-logs-previous-resource)
      ("A" "All-container logs" kubect-logs-all-containers-resource)
      ("C" "Selector logs" kubect-logs-selector-resource)
      ("t" "Incident top" kubect-incident-top-resource)
      ("D" "Incident describe" kubect-incident-describe-resource)
      ("!" "Restart triage" kubect-incident-debug-restarts-resource)
      ("V" "Incident events" kubect-incident-events-for-resource)
      ("Z" "Watch incident events" kubect-incident-watch-events-for-resource)
      ("h" "Rollout triage" kubect-incident-rollout-history-resource)
      ("=" "Rollout diff" kubect-rollout-diff-resource)]
     ["Follow-up"
      ("e" "Exec shell" kubect-exec-resource)
      ("F" "Browse files" kubect-browse-files)
     ("p" "Port-forward" kubect-port-forward-resource)
      ("j" "Jump related" kubect-jump-to-related-resource)
      ("u" "Show URLs" kubect-resource-urls)
      ("X" "Xray" kubect-xray)
      ("y" "Timeline" kubect-timeline-for-resource)]])
  (transient-define-prefix kubect-dispatch ()
    "Kubernetes command center."
    [["Sessions"
     ("b" "Open browser" kubect)
      ("I" "Investigation profile" kubect-investigation-profile)
     ("N" "All namespaces" kubect-all-namespaces)
     ("P" "Pods all namespaces" kubect-pods-all-namespaces)
     ("." "Home" kubect-home)
     ("X" "Xray" kubect-xray)
      ("G" "Resource graph" kubect-resource-graph)
      ("J" "Namespace dashboard" kubect-namespace-dashboard)
      ("Q" "Alerts" kubect-alerts)
      ("y" "Timeline" kubect-timeline)
      ("Y" "Timeline for resource" kubect-timeline-for-resource)
      ("," "Sort preset" kubect-session-apply-sort-preset)
      ("S" "Filter preset" kubect-session-apply-filter-preset)
      ("v" "Open events" kubect-events)
     ("V" "Events for resource" kubect-events-for-resource-at-point)
      ("z" "Watch events" kubect-watch-events)
      ("Z" "Watch events for resource" kubect-watch-events-for-resource)
      ("i" "Incident actions" kubect-incident-dispatch)
      ("B" "Switch session" kubect-switch-session)
      ("m" "Mark row" kubect-session-mark)
      ("M" "Bulk action" kubect-session-bulk-action)
     ("F" "Browse files" kubect-browse-files)
      ("H" "Session history" kubect-session-history)
      ("o" "Occur" kubect-occur)
      ("W" "Toggle wide" kubect-session-toggle-wide)
      ("w" "Toggle watch" kubect-toggle-watch)
      ("s" "Status" kubect-status)]
     ["Context"
      ("c" "Set context" kubect-set-context)
      ("n" "Set namespace" kubect-set-namespace)
      ("R" "Set resource" kubect-set-resource)]
     ["Manifest"
      ("a" "Apply buffer" kubect-apply-buffer)
      ("d" "Diff buffer" kubect-diff-buffer)
      ("x" "Describe at point" kubect-describe-resource-at-point)
      ("?" "Explain field/kind" kubect-explain-resource-at-point)]
     ["Runtime"
      ("l" "Logs" kubect-logs)
      ("L" "Previous logs" kubect-logs-previous)
      ("A" "All-container logs" kubect-logs-all-containers)
      ("C" "Selector logs" kubect-logs-selector)
      ("t" "Top pods" kubect-top-pods)
      ("T" "Top nodes" kubect-top-nodes)
      ("C-c N" "Browse nodes" kubect-nodes)
      ("e" "Exec shell" kubect-exec-shell)
      ("!" "Debug restarts" kubect-debug-restarts-resource)
      ("j" "Jump related" kubect-jump-to-related-resource)
      ("u" "Show URLs" kubect-resource-urls)
      ("r" "Rollout restart" kubect-rollout-restart)
      ("h" "Rollout history" kubect-rollout-history)
      ("=" "Rollout diff" kubect-rollout-diff)
      ("p" "Port-forward" kubect-port-forward)]])

  (transient-define-prefix kubect-session-dispatch ()
    "Commands for the current Kubernetes session."
    [["Resource"
      ("x" "Describe" kubect-describe-resource)
      ("E" "Edit manifest" kubect-edit-resource)
      ("l" "Logs" kubect-logs-resource)
      ("t" "Top" kubect-top-resource)
      ("i" "Incident actions" kubect-incident-dispatch)
      ("X" "Xray" kubect-xray)
      ("G" "Resource graph" kubect-resource-graph)
      ("J" "Namespace dashboard" kubect-namespace-dashboard)
      ("Q" "Alerts" kubect-alerts)]
     ["Extended"
      ("C-c s" "Saved query" kubect-saved-query)
      ("C-c p" "Policy guardrails" kubect-policy-guardrails)
      ("C-c n" "Network explorer" kubect-network-explorer)
      ("C-c r" "Rollout watch" kubect-rollout-watch)
     ("C-c a" "Prometheus alerts" kubect-prometheus-alerts)]
     ["Scope"
      ("g" "Refresh" kubect-refresh)
      ("C-c N" "Browse nodes" kubect-nodes)
      ("c" "Context" kubect-session-set-context)
      ("n" "Namespace" kubect-session-set-namespace)
      ("R" "Resource kind" kubect-session-set-resource)
      ("N" "All namespaces" kubect-all-namespaces)
      ("P" "All pods" kubect-pods-all-namespaces)]
     ["Triage"
      ("m" "Mark row" kubect-session-mark)
      ("u" "Unmark row" kubect-session-unmark)
      ("M" "Bulk action" kubect-session-bulk-action)
      ("f" "Filter" kubect-session-set-filter)
      ("C-c f" "Column filter" kubect-session-set-column-filter)
      ("o" "Occur" kubect-occur)
      ("C-c C-k" "Cancel refresh" kubect-cancel-refresh)
      ("C-c C-e" "Refresh error" kubect-show-refresh-error)]])

  (transient-define-prefix kubect-report-dispatch ()
    "Commands for a Kubect report."
    [["Report"
      ("g" "Refresh" kubect-report-refresh)
      ("t" "Toggle watch" kubect-report-toggle-watch)
      ("c" "Sort by CPU" kubect-report-sort-top-by-cpu)
      ("m" "Sort by memory" kubect-report-sort-top-by-memory)
      ("o" "Occur" occur)
      ("C-c C-k" "Cancel refresh" kubect-cancel-refresh)
      ("C-c C-e" "Refresh error" kubect-show-refresh-error)]])

  (transient-define-prefix kubect-output-dispatch ()
    "Commands for a Kubect output buffer."
    [["Output"
      ("g" "Refresh" kubect-output-refresh)
      ("o" "Occur" occur)
      ("C-c C-k" "Cancel refresh" kubect-cancel-refresh)
      ("C-c C-e" "Refresh error" kubect-show-refresh-error)]])

  (transient-define-prefix kubect-stream-dispatch ()
    "Commands for a live Kubect stream."
    [["Stream"
      ("o" "Occur" occur)
      ("F" "Preset search" kubect-stream-occur-preset)
      ("t" "Timestamp mode" kubect-stream-toggle-timestamps)]])

  (transient-define-prefix kubect-file-browser-dispatch ()
    "Commands for the pod file browser."
    [["Files"
      ("g" "Refresh" kubect-file-browser-refresh)
      ("<return>" "Visit" kubect-file-browser-visit)
      ("^" "Parent directory" kubect-file-browser-up)
      ("+" "Create" kubect-file-browser-create)
      ("e" "Edit file" kubect-file-browser-edit-file)
      ("R" "Rename" kubect-file-browser-rename)
      ("D" "Delete" kubect-file-browser-delete)
      ("o" "Occur" kubect-occur)]])

  (transient-define-prefix kubect-bulk-review-dispatch ()
    "Commands for a Kubect bulk review."
    [["Review"
      ("<return>" "Visit" kubect-bulk-review-visit)
      ("o" "Visit other window" kubect-bulk-review-visit-other-window)
      ("a" "Visit all" kubect-bulk-review-visit-all)
      ("m" "Remove row" kubect-bulk-review-remove)
      ("f" "Filter" kubect-bulk-review-filter)
      ("g" "Refresh" kubect-bulk-review-refresh)]]))

(unless (featurep 'transient)
  (dolist (command '(kubect-dispatch kubect-incident-dispatch kubect-session-dispatch
                     kubect-report-dispatch kubect-output-dispatch kubect-stream-dispatch
                     kubect-file-browser-dispatch kubect-bulk-review-dispatch))
    (defalias command #'kubect-help)))

(define-minor-mode kubect-ops-mode
  "Minor mode for Kubernetes operations."
  :lighter (:eval (kubect--mode-line))
  :keymap kubect-prefix-map)

(define-globalized-minor-mode kubect-ops-global-mode
  kubect-ops-mode
  kubect--maybe-enable)

;; Backward-compatible aliases while config catches up.
(defalias 'tmz-k8s-dispatch #'kubect-dispatch)
(defalias 'tmz-k8s-ops-mode #'kubect-ops-mode)
(defalias 'tmz-k8s-ops-global-mode #'kubect-ops-global-mode)

(provide 'kubect-core)

;;; kubect-core.el ends here
