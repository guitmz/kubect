;;; test-reliability.el --- Lifecycle regressions -*- lexical-binding: t; -*-

(require 'test-support)

(ert-deftest kubect-title-survives-refontification ()
  (dolist (title '("OVERVIEW" "XRAY" "TIMELINE"))
    (with-temp-buffer
      (kubect-report-mode)
      (let ((inhibit-read-only t))
        (insert title "  context:dev\n=====\n"))
      (kubect--report-style-buffer)
      (font-lock-flush)
      (font-lock-ensure)
      (should (eq (get-text-property 1 'face) 'kubect-report-title-face))
      (should (eq (get-text-property (+ 3 (length title)) 'face)
                  'kubect-report-subject-face)))))

(ert-deftest kubect-namespace-dashboard-renders-and-opens-namespace-pods ()
  (let (displayed opened)
    (cl-letf (((symbol-function 'kubect-current-context) (lambda () "dev"))
              ((symbol-function 'kubect--namespace-dashboard-data)
               (lambda (_) (list '(:namespace "payments" :pods 4 :unhealthy 1
                                               :pending 0 :restarts 3 :warnings 7))))
              ((symbol-function 'kubect--display-buffer) (lambda (buffer) (setq displayed buffer)))
              ((symbol-function 'kubect-open) (lambda (&rest args) (setq opened args))))
      (kubect-namespace-dashboard)
      (with-current-buffer displayed
        (should (string-match-p "payments" (buffer-string)))
        (goto-char (point-min))
        (search-forward "payments")
        (kubect-report-visit)))
    (should (equal opened '("dev" "payments" "pods" nil nil)))))

(ert-deftest kubect-resource-graph-renders_targets_and_visits_a_pod ()
  (let (displayed visited)
    (cl-letf (((symbol-function 'kubect--resource-for-command)
               (lambda () '(:kind "deployments" :name "api" :context "dev" :namespace "payments")))
              ((symbol-function 'kubect--resource-basic-summary)
               (lambda (&rest _) '(:data ((metadata . ((ownerReferences . nil))) (spec . nil)) :spec nil)))
              ((symbol-function 'kubect--selector-for-resource) (lambda (&rest _) "app=api"))
              ((symbol-function 'kubect--pod-names-for-selector) (lambda (&rest _) '("api-123")))
              ((symbol-function 'kubect--display-buffer) (lambda (buffer) (setq displayed buffer)))
              ((symbol-function 'kubect--view-known-resource)
               (lambda (&rest args) (setq visited args))))
      (kubect-resource-graph)
      (with-current-buffer displayed
        (goto-char (point-min))
        (search-forward "pod/api-123")
        (kubect-report-visit)))
    (should (equal visited '("pods" "api-123" "dev" "payments" nil)))))

(ert-deftest kubect-alerts-render_configured_pod_and_namespace_alerts ()
  (let* ((pod '((metadata . ((name . "api") (namespace . "payments")))
                (status . ((phase . "Running")
                           (containerStatuses . (((restartCount . 4)
                                                  (state . ((waiting . ((reason . "CrashLoopBackOff"))))))))))))
         displayed)
    (cl-letf (((symbol-function 'kubect-current-context) (lambda () "dev"))
              ((symbol-function 'kubect--namespace-dashboard-data)
               (lambda (_) (list '(:namespace "payments" :warnings 11))))
              ((symbol-function 'kubect--kubectl-json)
               (lambda (&rest _) (list (cons 'items (list pod)))))
              ((symbol-function 'kubect--display-buffer) (lambda (buffer) (setq displayed buffer))))
      (let ((kubect-alert-rules
             '(("unhealthy" :type pod-status :severity critical)
               ("restarts" :type pod-restarts :minimum 3 :severity warning)
               ("warnings" :type warning-events :minimum 10 :severity warning))))
        (kubect-alerts)))
    (with-current-buffer displayed
      (should (string-match-p "unhealthy" (buffer-string)))
      (should (string-match-p "restarts" (buffer-string)))
      (should (string-match-p "warnings" (buffer-string))))))

(ert-deftest kubect-report-export-copies-portable-text ()
  (let (copied)
    (with-temp-buffer
      (kubect-report-mode)
      (let ((inhibit-read-only t))
        (insert "OVERVIEW  dev\n\n## Context\n"))
      (cl-letf (((symbol-function 'kill-new) (lambda (text &rest _) (setq copied text))))
        (kubect-export-report-markdown)))
    (should (string-match-p "## Context" copied))))

(ert-deftest kubect-crd-view-builds-all-namespace-custom-columns-command ()
  (let (args displayed)
    (cl-letf (((symbol-function 'kubect-current-context) (lambda () "dev"))
              ((symbol-function 'kubect--kubectl-output)
               (lambda (&rest received) (setq args received) "NAME\nwidget\n"))
              ((symbol-function 'kubect--display-buffer) (lambda (buffer) (setq displayed buffer))))
      (let ((kubect-crd-views '(("widgets" :resource "widgets.example.io"
                                            :columns "NAME:.metadata.name"))))
        (kubect-crd-view "widgets")))
    (should (member "--all-namespaces=true" args))
    (should (member "widgets.example.io" args))
    (should (member "custom-columns=NAME:.metadata.name" args))
    (with-current-buffer displayed
      (should (string-match-p "widget" (buffer-string))))))

(ert-deftest kubect-rbac-inspect-renders-can-i-decision ()
  (let (args displayed)
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest received) (setq args received) "yes"))
              ((symbol-function 'kubect--display-buffer) (lambda (buffer) (setq displayed buffer))))
      (kubect-rbac-inspect "get" "pods" "alice" "dev" "payments"))
    (should (member "auth" args))
    (should (member "--as" args))
    (with-current-buffer displayed
      (should (string-match-p "yes" (buffer-string))))))

(ert-deftest kubect-network-explorer-prompt-uses-session-scope ()
  "The resource picker must receive context before namespace."
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create :context "dev-cluster" :namespace "team-a"
                                       :resource "pods"))
    (let (picker-args)
      (cl-letf (((symbol-function 'kubect--resource-for-command)
                 (lambda (&rest args)
                   (setq picker-args args)
                   '(:kind "pods" :name "api" :context "dev-cluster" :namespace "team-a")))
                ((symbol-function 'kubect--network-explorer-body) (lambda (_) "body"))
                ((symbol-function 'kubect--show-report-buffer) (lambda (&rest _) nil)))
        (kubect-network-explorer))
      (should (equal picker-args '("dev-cluster" "team-a"))))))

(ert-deftest kubect-compare-resource-contexts-fetches-both-manifests ()
  (let (seen)
    (cl-letf (((symbol-function 'kubect--resource-for-command)
               (lambda () '(:kind "deployments" :name "api" :namespace "payments")))
              ((symbol-function 'kubect--resource-json)
               (lambda (_kind _name context _namespace) (push context seen) `((context . ,context))))
              ((symbol-function 'kubect--rollout-diff-buffer) (lambda (&rest _) :shown)))
      (kubect-compare-resource-contexts "dev" "prod"))
    (should (equal (sort seen #'string-lessp) '("dev" "prod")))))

(ert-deftest kubect-cost-signals-flags-missing-limits-and-high-request ()
  (let* ((pod '((metadata . ((name . "api") (namespace . "payments")))
                (spec . ((containers . (((resources . ((requests . ((cpu . "1000m")
                                                                    (memory . "1Gi")))
                                                     (limits . ((cpu . "2"))))))))))))
         (lines nil) json-args)
    (cl-letf (((symbol-function 'kubect--kubectl-json)
               (lambda (&rest args)
                 (setq json-args args)
                 `((items . (,pod)))))
              ((symbol-function 'kubect--kubectl-output)
               (lambda (&rest _) "NAMESPACE NAME CPU(cores) MEMORY(bytes)\npayments api 10m 10Mi\n")))
      (setq lines (kubect--cost-signal-lines "dev")))
    (should (equal (last json-args 2) '("-o" "json")))
    (should (string-match-p "LIMITS" (string-join lines "\n")))
    (should (string-match-p "CPU" (string-join lines "\n")))))

(ert-deftest kubect-policy-guardrails-detects-privileged-host-and-limit-risks ()
  (let* ((container '((name . "api")
                      (image . "api:latest")
                      (securityContext . ((privileged . t)))
                      (resources . ((limits . ((cpu . "1")))))))
         (volume '((name . "host") (hostPath . ((path . "/")))))
         (data `((spec . ((hostNetwork . t)
                           (volumes . (,volume))
                           (containers . (,container))))))
         (text (string-join (kubect--policy-guardrail-lines data) "\n")))
    (should (string-match-p "hostNetwork" text))
    (should (string-match-p "hostPath" text))
    (should (string-match-p "privileged" text))
    (should (string-match-p "lacks CPU or memory limits" text))))

(ert-deftest kubect-prometheus-result-lines-renders-vector-labels ()
  (let* ((data '((data . ((result . (((metric . ((alertname . "DiskFull")))
                                     (value . (0 "1")))))))))
         (text (string-join (kubect--prometheus-result-lines data) "\n")))
    (should (string-match-p "DiskFull" text))
    (should (string-match-p "1" text))))

(ert-deftest kubect-saved-query-applies-configured-scope-and-filter ()
  (let ((buffer (generate-new-buffer " *kubect saved query test*")) opened)
    (unwind-protect
        (cl-letf (((symbol-function 'kubect-current-context) (lambda () "dev"))
                  ((symbol-function 'kubect-current-namespace) (lambda () "default"))
                  ((symbol-function 'kubect-current-resource) (lambda () "pods"))
                  ((symbol-function 'kubect-refresh) (lambda () nil))
                  ((symbol-function 'kubect-open)
                   (lambda (&rest args)
                     (setq opened args)
                     (kubect-session-create :buffer buffer))))
          (with-current-buffer buffer (kubect-session-mode))
          (let ((kubect-saved-queries
                 '(("failing" :resource "pods" :all-namespaces t
                              :filter "CrashLoopBackOff" :field-selector "status.phase=Running"))))
            (kubect-saved-query "failing"))
          (should (equal (nth 1 opened) kubect-all-namespaces-token))
          (should (equal (nth 3 opened) "CrashLoopBackOff")))
      (kill-buffer buffer))))

(ert-deftest kubect-read-cache-excludes-auth-can-i-commands ()
  (let ((noninteractive nil))
    (should (kubect--cacheable-read-p '("--context" "dev" "get" "pods")))
    (should-not (kubect--cacheable-read-p '("get" "pods")))
    (should-not (kubect--cacheable-read-p '("--context" "dev" "describe" "pod" "api")))
    (should-not (kubect--cacheable-read-p
                 '("--context" "dev" "auth" "can-i" "get" "pods")))))

(ert-deftest kubect-report-refresh-keeps-configured-header ()
  (with-temp-buffer
    (kubect-report-mode)
    (setq-local kubect-report-state
                (list :type 'plain :header "Cost signals | g refresh" :body "old"
                      :refresh-fn (lambda (state)
                                    (plist-put (copy-sequence state) :body "new"))))
    (kubect-report-refresh)
    (should (equal header-line-format "Cost signals | g refresh"))
    (should (equal (buffer-string) "new"))))

(ert-deftest kubect-policy-finds-cronjob-pod-template ()
  (let* ((container '((name . "job") (image . "job:latest")))
         (data `((spec . ((jobTemplate . ((spec . ((template . ((spec . ((containers . (,container)))))))))))))))
    (should (equal (alist-get 'containers (kubect--resource-pod-spec data))
                   (list container)))))

(ert-deftest kubect-report-resource-keeps-row-namespace-in-all-namespace-session ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create :context "dev" :namespace kubect-all-namespaces-token))
    (let ((resource '(:kind "pods" :name "api" :context "wrong" :namespace "payments")))
      (should (equal (plist-get (kubect--report-resource-with-session-scope resource) :context) "dev"))
      (should (equal (plist-get (kubect--report-resource-with-session-scope resource) :namespace) "payments")))))

(ert-deftest kubect-report-resource-uses-session-namespace-in-scoped-session ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session (kubect-session-create :context "dev" :namespace "payments"))
    (let ((resource '(:kind "pods" :name "api" :context "wrong" :namespace "wrong-ns")))
      (should (equal (plist-get (kubect--report-resource-with-session-scope resource) :context) "dev"))
      (should (equal (plist-get (kubect--report-resource-with-session-scope resource) :namespace) "payments")))))

(ert-deftest kubect-report-resource-uses-report-scope ()
  (with-temp-buffer
    (kubect-report-mode)
    (setq-local kubect-report-state '(:context "dev" :namespace "payments"))
    (let ((resource '(:kind "pods" :name "api" :context "wrong" :namespace "wrong-ns")))
      (should (equal (plist-get (kubect--report-resource-with-session-scope resource) :context) "dev"))
      (should (equal (plist-get (kubect--report-resource-with-session-scope resource) :namespace) "payments")))))

(ert-deftest kubect-missing-node-metrics-are-not-zero ()
  (let* ((nodes '((items . (((metadata . ((name . "n1")))
                             (status . ((allocatable . ((cpu . "4")
                                                        (memory . "8Gi")
                                                        (pods . "60"))))))))))
         (rows (kubect--node-capacity-rows nodes '((items)) "")))
    (should (equal (cdr (assoc "CPU UTIL" (car rows))) "N/A (partial)"))
    (should (equal (cdr (assoc "MEMORY UTIL" (cadr rows))) "N/A"))))

(ert-deftest kubect-stream-reopening-replaces-old-process ()
  (let (buffer old)
    (unwind-protect
        (cl-letf (((symbol-function 'kubect--ensure-kubectl) (lambda () "/bin/cat"))
                  ((symbol-function 'kubect--display-buffer)
                   (lambda (value) (setq buffer value))))
          (kubect--start-stream "test lifecycle" nil "test" "test")
          (setq old (get-buffer-process buffer))
          (should (process-live-p old))
          (kubect--start-stream "test lifecycle" nil "test" "test")
          (should-not (process-live-p old))
          (should (process-live-p (get-buffer-process buffer)))
          (should-not (eq old (get-buffer-process buffer))))
      (when (buffer-live-p buffer)
        (when-let* ((process (get-buffer-process buffer)))
          (set-process-query-on-exit-flag process nil)
          (delete-process process))
        (kill-buffer buffer)))))

(defmacro kubect-test-with-async (&rest body)
  `(with-temp-buffer
     (kubect-report-mode)
     (let ((noninteractive nil))
       (cl-letf (((symbol-function 'kubect-current-context) (lambda () "dev"))
                 ((symbol-function 'kubect-current-namespace) (lambda () "default"))
                 ((symbol-function 'kubect-current-resource) (lambda () "pods")))
         ,@body))))

(defun kubect-test-await-refresh ()
  (let ((deadline (+ (float-time) 5)))
    (while (and kubect--async-job (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should-not kubect--async-job)))

(ert-deftest kubect-async-session-scope-keeps-context-and-namespace-distinct ()
  "A queued browser refresh must not treat the namespace as its context."
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create :context "dev-cluster" :namespace "team-a"
                                       :resource "pods"))
    (let ((noninteractive nil) captured)
      (cl-letf (((symbol-function 'kubect--async-step)
                 (lambda (job) (setq captured job))))
        (kubect--async-command #'ignore))
      (should (equal (plist-get captured :context) "dev-cluster"))
      (should (equal (plist-get captured :namespace) "team-a"))
      (should (equal (plist-get captured :resource) "pods")))))

(ert-deftest kubect-async-report-scope-keeps-context-and-namespace-distinct ()
  "Reports retain their own scope when queuing a follow-up action."
  (with-temp-buffer
    (kubect-report-mode)
    (setq-local kubect-report-state '(:context "dev-cluster" :namespace "team-a"))
    (let ((noninteractive nil) captured)
      (cl-letf (((symbol-function 'kubect-current-resource) (lambda () "pods"))
                ((symbol-function 'kubect--async-step)
                 (lambda (job) (setq captured job))))
        (kubect--async-command #'ignore))
      (should (equal (plist-get captured :context) "dev-cluster"))
      (should (equal (plist-get captured :namespace) "team-a")))))

(ert-deftest kubect-async-fetch-caches-and-finishes ()
  (kubect-test-with-async
   (let ((make (symbol-function 'make-process)) (count 0) result)
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest options)
                  (cl-incf count)
                  (apply make (plist-put options :command '("/bin/echo" "response"))))))
       (kubect--async-command
        (lambda ()
          (setq result (list (kubect--kubectl-output "first")
                             (kubect--kubectl-output "second")))))
       (should kubect--async-job)
       (kubect-test-await-refresh)
       (should (= count 2))
       (should (equal result '("response" "response")))
       (should (string-match-p "Updated" header-line-format))
       (should (equal kubect--last-action "refresh"))
       (should (string-match-p "last=refresh" header-line-format))))))

(ert-deftest kubect-async-failure-retains-output ()
  (kubect-test-with-async
   (let ((make (symbol-function 'make-process)) (inhibit-read-only t))
     (insert "previous report")
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest options)
                  (apply make (plist-put options :command '("/usr/bin/false"))))))
       (kubect--async-command (lambda () (kubect--kubectl-output "fail")))
       (kubect-test-await-refresh)
       (should (equal (buffer-string) "previous report"))
       (should (string-match-p "Refresh failed" header-line-format))))))

(ert-deftest kubect-async-cancel-and-overlap ()
  (kubect-test-with-async
   (let ((make (symbol-function 'make-process)) (count 0))
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest options)
                  (cl-incf count)
                  (apply make (plist-put options :command '("/bin/cat"))))))
       (kubect--async-command (lambda () (kubect--kubectl-output "wait")))
       (let ((process (plist-get kubect--async-job :process)))
         (should (processp process))
         (should (process-live-p process))
         (kubect--async-command (lambda () (error "overlapped")))
         (should (= count 1))
         (kubect-cancel-refresh)
         (should-not kubect--async-job)
         (should-not (process-live-p process)))))))

(ert-deftest kubect-async-failure-records-literal-request ()
  (kubect-test-with-async
   (let ((make (symbol-function 'make-process)))
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest options)
                  (apply make (plist-put options :command '("/usr/bin/false"))))))
       (kubect--async-command (lambda () (kubect--kubectl-output "get" "pods")))
       (kubect-test-await-refresh)
       (should (equal kubect--last-refresh-request '("get" "pods")))
       (should (string-match-p "Command: kubectl get pods" kubect--last-refresh-error))))))

(ert-deftest kubect-selector-logs-configurable-concurrency ()
  (let ((kubect-max-log-requests 17))
    (should (member "--max-log-requests=17"
                    (kubect--logs-args nil nil "dev" "default" nil nil nil "app=api")))
    (should-not (member "--max-log-requests=17"
                        (kubect--logs-args "api" nil "dev" "default" nil nil nil)))))

(ert-deftest kubect-session-unmark-key-is-not-shadowed ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding "u") #'kubect-session-unmark))))

(ert-deftest kubect-node-refresh-preserves-context-without-metrics ()
  (let (seen)
    (cl-letf (((symbol-function 'kubect-current-context) (lambda () "other"))
              ((symbol-function 'kubect--kubectl-json)
               (lambda (&rest args) (push args seen) '((items))))
              ((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args) (push args seen) (error "Metrics unavailable"))))
      (let ((state (kubect--node-capacity-state "dev")))
        (funcall (plist-get state :refresh-fn) state)
        (should (= (length seen) 6))
        (should (cl-every (lambda (args) (equal (cadr args) "dev")) seen))))))

(ert-deftest kubect-node-drilldown-uses-context-and-node-selector ()
  (with-temp-buffer
    (kubect-report-mode)
    (let ((inhibit-read-only t)) (insert "node-a  10m\n"))
    (goto-char (point-min))
    (setq kubect-report-state '(:node-capacity t :context "dev"
                               :rows ((("NODE" . "node-a")))))
    (let (seen)
      (cl-letf (((symbol-function 'kubect-open)
                 (lambda (&rest args) (setq seen args))))
        (kubect-report-visit)
        (should (equal seen '("dev" "*all*" "pods" nil nil
                              "spec.nodeName=node-a" "node:node-a")))))))

(ert-deftest kubect-async-timeout-stops-process ()
  (kubect-test-with-async
   (let ((make (symbol-function 'make-process)) (kubect-request-timeout 0.03))
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest options)
                  (apply make (plist-put options :command '("/bin/cat"))))))
       (kubect--async-command (lambda () (kubect--kubectl-output "wait")))
       (let ((process (plist-get kubect--async-job :process)))
         (should (processp process))
         (kubect-test-await-refresh)
         (should-not (process-live-p process))
         (should (string-match-p "timed out" header-line-format)))))))

(ert-deftest kubect-async-does-not-render-stale-buffer ()
  (kubect-test-with-async
   (let ((make (symbol-function 'make-process)) rendered)
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest options)
                  (apply make (plist-put options :command '("/bin/echo" "result"))))))
       (kubect--async-command (lambda () (kubect--kubectl-output "get") (setq rendered t)))
       (let ((inhibit-read-only t)) (insert "changed scope"))
       (kubect-test-await-refresh)
       (should-not rendered)))))

(ert-deftest kubect-output-prefix-displays-real-other-window ()
  (save-window-excursion
    (delete-other-windows)
    (let ((kubect-display-buffer-action 'same-window) output)
      (unwind-protect
          (progn
            (kubect--show-output-buffer "window test" "body" "dev" "default")
            (setq output (current-buffer))
            (should (= (length (window-list)) 1))
            (kubect--show-output-buffer "window test split" "body" "dev" "default" '(4))
            (should (= (length (window-list)) 2))
            (should-not (eq (current-buffer) output))
            (kill-buffer (current-buffer)))
        (when (buffer-live-p output) (kill-buffer output))))))

(ert-deftest kubect-terminal-backends-pass-literal-arguments ()
  (dolist (backend '(eat ghostel))
    (let (seen buffer)
      (unwind-protect
          (cl-letf (((symbol-function 'kubect--ensure-kubectl) (lambda () "/bin/kubectl"))
                    ((symbol-function 'kubect--display-buffer) #'ignore)
                    ((symbol-function 'eat-mode) #'ignore)
                    ((symbol-function 'eat-exec)
                     (lambda (target _name program _start args)
                       (setq seen (list program args) buffer target)))
                    ((symbol-function 'ghostel-exec)
                     (lambda (target program args)
                       (setq seen (list program args) buffer target))))
            (funcall (if (eq backend 'eat) #'kubect--open-eat-exec-buffer
                       #'kubect--open-ghostel-exec-buffer)
                     "*kubect backend test*" "unused shell command"
                     '("--context" "dev" "exec" "pod" "--" "sh") 'same-window)
            (should (equal seen '("/bin/kubectl" ("--context" "dev" "exec" "pod" "--" "sh"))))
            (should (buffer-live-p buffer)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest kubect-session-header-includes-filter-and-all-namespaces ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq kubect-session (kubect-session-create :context "dev" :resource "pods"
                                               :namespace kubect-all-namespaces-token
                                               :filter "crash" :filter-mode 'substring))
    (cl-letf (((symbol-function 'kubect--table-output) (lambda (_) "NAME\n")))
      (kubect-refresh)
      (should (string-match-p "crash" header-line-format))
      (should (string-match-p "all-namespaces" header-line-format)))))

(ert-deftest kubect-menu-namespace-change-and-g-use-new-namespace ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq kubect-session (kubect-session-create :context "dev" :namespace "old"
                                               :resource "pods"))
    (let (requests)
      (cl-letf (((symbol-function 'kubect--set-project-state) #'ignore)
                ((symbol-function 'kubect--kubectl-output)
                 (lambda (&rest args)
                   (push args requests)
                   "NAME STATUS\nnew-pod Running\n")))
        (kubect-set-namespace "new")
        (call-interactively (key-binding "g"))
        (should (equal (kubect-session-namespace kubect-session) "new"))
        (should (= (length requests) 2))
        (should (cl-every (lambda (args) (equal (cadr (member "--namespace" args)) "new"))
                          requests))
        (should (string-match-p "ns=new" header-line-format))
        (should (string-match-p "new-pod" (buffer-string)))))))

(ert-deftest kubect-session-scope-overrides-project-defaults ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq kubect-session (kubect-session-create :context "dev" :namespace "selected"
                                               :resource "deployments"))
    (cl-letf (((symbol-function 'kubect--project-default) (lambda (_) "wrong")))
      (should (equal (kubect-current-context) "dev"))
      (should (equal (kubect-current-namespace) "selected"))
      (should (equal (kubect-current-resource) "deployments")))))

(ert-deftest kubect-namespace-key-cancels-old-fetch-and-clears-stale-marks ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq kubect-session (kubect-session-create :context "dev" :namespace "old"
                                               :resource "pods" :marked-resources '("pod/old")))
    (let ((old-job (list :cancelled nil :timer nil :process nil))
          (other (kubect-session-create :context "dev" :namespace "untouched")))
      (setq kubect--async-job old-job)
      (cl-letf (((symbol-function 'kubect--list-namespaces) (lambda (_) '("old" "new")))
                ((symbol-function 'kubect--completing-read) (lambda (&rest _) "new"))
                ((symbol-function 'kubect--kubectl-output)
                 (lambda (&rest args)
                   (should (equal (cadr (member "--namespace" args)) "new"))
                   "NAME\nnew-pod\n")))
        (call-interactively (key-binding "n"))
        (call-interactively (key-binding "g"))
        (should (plist-get old-job :cancelled))
        (should-not kubect--async-job)
        (should-not (kubect-session-marked-resources kubect-session))
        (should (equal (kubect-current-namespace) "new"))
        (should (equal (kubect-session-namespace other) "untouched"))))))

(ert-deftest kubect-scope-failure-does-not-leave-old-actionable-rows ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq kubect-session (kubect-session-create :context "old" :namespace "ns"
                                               :resource "pods" :marked-resources '("pod/old")))
    (let ((inhibit-read-only t)) (insert "NAME\nold-pod\n"))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest _) (error "Forbidden"))))
      (should-error (kubect--session-change-scope "new" "ns" "deployments" "context" "new"))
      (should (equal (buffer-string) ""))
      (should-not (kubect-session-marked-resources kubect-session))
      (should (equal (kubect-session-name kubect-session) "new/ns/deployments"))
      (should (string-match-p "Forbidden" header-line-format)))))

(ert-deftest kubect-menu-context-and-resource-update-active-session ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq kubect-session (kubect-session-create :context "old" :namespace "ns"
                                               :resource "pods" :marked-resources '("pod/old")))
    (cl-letf (((symbol-function 'kubect--set-project-state) #'ignore)
              ((symbol-function 'kubect--kubectl-output) (lambda (&rest _) "NAME\n")))
      (kubect-set-context "new")
      (should (equal (kubect-current-context) "new"))
      (should-not (kubect-session-marked-resources kubect-session))
      (setf (kubect-session-marked-resources kubect-session) '("pod/new"))
      (kubect-set-resource "services")
      (should (equal (kubect-current-resource) "services"))
      (should-not (kubect-session-marked-resources kubect-session)))))

(ert-deftest kubect-namespace-config-failure-falls-back-to-default ()
  (with-temp-buffer
    (let ((kubect--project-state (make-hash-table :test #'equal)))
      (cl-letf (((symbol-function 'kubect--project-default) (lambda (_) nil))
                ((symbol-function 'kubect--kubectl-output) (lambda (&rest _) (error "No config"))))
        (should (equal (kubect-current-namespace) "default"))))))

(ert-deftest kubect-command-timeout-keeps-emacs-from-waiting-on-kubectl ()
  (let ((kubect-kubectl-command "sh")
        (kubect-command-timeout 0.02)
        (started (float-time)))
    (let ((err (should-error (kubect--kubectl-output "-c" "sleep 1"))))
      (should (string-match-p "kubectl timed out" (error-message-string err)))
      (should (< (- (float-time) started) 0.5)))))

(ert-deftest kubect-async-quit-does-not-block-next-refresh ()
  (kubect-test-with-async
   (condition-case nil
       (kubect--async-command (lambda () (signal 'quit nil)))
     (quit nil))
   (should-not kubect--async-job)
   (let (ran)
     (kubect--async-command (lambda () (setq ran t)))
     (should ran))))

(ert-deftest kubect-context-key-preserves-namespace ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq kubect-session (kubect-session-create :context "old" :namespace "team"
                                               :resource "pods"))
    (cl-letf (((symbol-function 'kubect--list-contexts) (lambda () '("old" "new")))
              ((symbol-function 'kubect--completing-read) (lambda (&rest _) "new"))
              ((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args)
                 (should (equal (cadr (member "--context" args)) "new"))
                 (should (equal (cadr (member "--namespace" args)) "team"))
                 "NAME\n")))
      (call-interactively (key-binding "c"))
      (should (equal (kubect-current-namespace) "team")))))

(ert-deftest kubect-report-watch-cleaned-on-kill-and-mode-reset ()
  (dolist (action '(kill-buffer kubect-report-mode))
    (let ((buffer (generate-new-buffer " *kubect timer test*")) timer)
      (unwind-protect
          (with-current-buffer buffer
            (kubect-report-mode)
            (setq kubect-report-state '(:refresh-fn ignore))
            (let ((kubect-watch-interval 999)) (kubect-report-toggle-watch))
            (setq timer kubect--report-watch-timer)
            (should (memq timer timer-list))
            (funcall action)
            (should-not (memq timer timer-list)))
        (when timer (cancel-timer timer))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest kubect-browser-refresh-is-asynchronous-and-renders-fresh-table ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq kubect-session (kubect-session-create :context "dev" :namespace "default"
                                               :resource "pods"))
    (let ((inhibit-read-only t) (noninteractive nil) (make (symbol-function 'make-process)))
      (insert "NAME\nold-pod\n")
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest options)
                   (apply make (plist-put options :command
                                           '("/bin/echo" "NAME STATUS\nnew-pod Running"))))))
        (kubect-refresh)
        (should kubect--async-job)
        (should (string-match-p "old-pod" (buffer-string)))
        (kubect-test-await-refresh)
        (should (string-match-p "new-pod" (buffer-string)))
        (should-not (string-match-p "old-pod" (buffer-string)))
        (should (string-match-p "Updated" header-line-format))))))

(ert-deftest kubect-browser-refresh-failure-keeps-table-and-error-details ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq kubect-session (kubect-session-create :context "dev" :namespace "default"
                                               :resource "pods"))
    (let ((inhibit-read-only t) (noninteractive nil) (make (symbol-function 'make-process)) error-buffer)
      (insert "NAME\nold-pod\n")
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest options)
                   (apply make (plist-put options :command '("/usr/bin/false"))))))
        (kubect-refresh)
        (kubect-test-await-refresh)
        (should (string-match-p "old-pod" (buffer-string)))
        (should (string-match-p "Stale | Refresh failed" header-line-format))
        (should (string-match-p "kubectl exited" kubect--last-refresh-error))
        (cl-letf (((symbol-function 'kubect--display-buffer)
                   (lambda (buffer) (setq error-buffer buffer))))
          (kubect-show-refresh-error))
        (with-current-buffer error-buffer
          (should (derived-mode-p 'special-mode))
          (should (string-match-p "kubectl exited" (buffer-string))))
        (kill-buffer error-buffer)))))

(ert-deftest kubect-scope-change-replaces-inflight-browser-refresh ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq kubect-session (kubect-session-create :context "dev" :namespace "old"
                                               :resource "pods"))
    (let ((noninteractive nil) (make (symbol-function 'make-process)) old-process)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest options)
                   (apply make (plist-put options :command '("/bin/cat"))))))
        (kubect-refresh)
        (setq old-process (plist-get kubect--async-job :process))
        (should (process-live-p old-process))
        (kubect--session-change-namespace "new")
        (should-not (process-live-p old-process))
        (kubect-cancel-refresh)))))

;;; test-reliability.el ends here
