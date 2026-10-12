;;; test-session.el --- kubect tests -*- lexical-binding: t; -*-

(require 'test-support)

(ert-deftest kubect-session-line-face-highlights-unhealthy-states ()
  (should (eq (kubect--session-line-face "api 0/1 CrashLoopBackOff 7 1m")
              'kubect-critical-face))
  (should (eq (kubect--session-line-face "api 0/1 Pending 0 10s")
              'kubect-warning-face))
  (should-not (kubect--session-line-face "api 1/1 Running 0 1h")))

(ert-deftest kubect-restart-trouble-line-p-detects-restarty-states ()
  (should (kubect--restart-trouble-line-p "api 0/1 CrashLoopBackOff 7 1m"))
  (should (kubect--restart-trouble-line-p "api 0/1 Error 3 20s"))
  (should-not (kubect--restart-trouble-line-p "api 1/1 Running 0 1h")))

(ert-deftest kubect-confirm-write-prompts-for-every-context-by-default ()
  (let ((prompts '()))
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (prompt)
                 (push prompt prompts)
                 nil)))
      (should-not (kubect--confirm-write "Apply" "dev-cluster" "sandbox"))
      (should-not (kubect--confirm-write "Apply" "prod-eu-1" "payments"))
      (should (equal prompts
                     '("Apply against prod-eu-1/payments [production context]? "
                       "Apply against dev-cluster/sandbox? "))))))

(ert-deftest kubect-confirm-write-keeps-production-protection-when-opted-out ()
  (let ((kubect-confirm-mutating-commands nil)
        prompts)
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (prompt) (push prompt prompts) t)))
      (should (kubect--confirm-write "Apply" "dev-cluster" "sandbox"))
      (should (kubect--confirm-write "Apply" "prod-eu-1" "payments"))
      (should (equal prompts
                     '("Apply against prod-eu-1/payments [production context]? "))))))

(ert-deftest kubect-exec-shell-does-not-open-when-confirmation-is-refused ()
  (let (opened)
    (cl-letf (((symbol-function 'kubect--confirm-write) (lambda (&rest _) nil))
              ((symbol-function 'kubect--open-exec-buffer)
               (lambda (&rest args) (setq opened args))))
      (kubect-exec-shell "api-123" "app" "dev" "team-a" nil)
      (should-not opened))))

(ert-deftest kubect-port-forward-does-not-start-when-confirmation-is-refused ()
  (let (started)
    (cl-letf (((symbol-function 'kubect--confirm-write) (lambda (&rest _) nil))
              ((symbol-function 'kubect--start-stream)
               (lambda (&rest args) (setq started args))))
      (kubect-port-forward "service/api" "8080" "80" "dev" "team-a" nil)
      (should-not started))))

(ert-deftest kubect-table-output-filters-raw-cli-rows ()
  (let ((session (kubect-session-create
                  :name "ctx/ns/pods"
                  :context "ctx"
                  :namespace "ns"
                  :resource "pods"
                  :filter "api")))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args)
                 (should (equal args
                                '("--context" "ctx"
                                  "--namespace" "ns"
                                  "get" "pods")))
                 (string-join
                  '("NAME        READY   STATUS    RESTARTS   AGE"
                    "api-7f6d9   1/1     Running   0          1h"
                    "worker-1    1/1     Running   0          30m")
                  "\n"))))
      (should
       (equal (kubect--table-output session)
              (string-join
               '("NAME        READY   STATUS    RESTARTS   AGE"
                 "api-7f6d9   1/1     Running   0          1h")
               "\n"))))))

(ert-deftest kubect-table-output-filters-by-named-column-case-insensitively ()
  (let ((session (kubect-session-create
                  :name "ctx/ns/pods"
                  :context "ctx"
                  :namespace "ns"
                  :resource "pods"
                  :column-filter-column "STATUS"
                  :column-filter-pattern "running")))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest _)
                 (string-join
                  '("NAME        READY   STATUS             RESTARTS   AGE"
                    "api-7f6d9   1/1     Running            0          1h"
                    "worker-1    0/1     CrashLoopBackOff   7          30m")
                  "\n"))))
      (should (equal (kubect--table-output session)
                     (string-join
                      '("NAME        READY   STATUS             RESTARTS   AGE"
                        "api-7f6d9   1/1     Running            0          1h")
                      "\n"))))))

(ert-deftest kubect-column-filter-composes-with-text-filter ()
  (let ((session (kubect-session-create
                  :name "ctx/ns/pods"
                  :context "ctx"
                  :namespace "ns"
                  :resource "pods"
                  :filter "api"
                  :column-filter-column "STATUS"
                  :column-filter-pattern "Running")))
    (should (kubect--session-row-matches-p
             session "NAME  STATUS" "api  Running"))
    (should-not (kubect--session-row-matches-p
                 session "NAME  STATUS" "worker  Running"))
    (should-not (kubect--session-row-matches-p
                 session "NAME  STATUS" "api  Pending"))))

(ert-deftest kubect-view-refresh-retains-its-captured-scope ()
  (with-temp-buffer
    (kubect-view-mode)
    (setq-local kubect--view-target
                '(:kind "pod" :name "api" :context "ctx" :namespace "team"))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args)
                 (should (equal args
                                '("--context" "ctx" "--namespace" "team"
                                  "get" "pod" "api" "-o" "yaml")))
                 "apiVersion: v1\nkind: Pod")))
      (kubect-view-refresh)
      (should (string-match-p "kind: Pod" (buffer-string)))
      (should (string-match-p "context=ctx namespace=team resource=pod"
                              header-line-format)))))

(ert-deftest kubect-table-output-uses-literal-kubectl-get ()
  (let ((session (kubect-session-create
                  :name "ctx/ns/pods"
                  :context "ctx"
                  :namespace "ns"
                  :resource "pods")))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args)
                 (should (equal args
                                (list "--context" "ctx"
                                      "--namespace" "ns"
                                      "get" "pods")))
                 "NAME   READY   STATUS\napi-1  1/1     Running")))
      (should (equal (kubect--table-output session)
                     "NAME   READY   STATUS\napi-1  1/1     Running")))))

(ert-deftest kubect-table-output-adds-wide-when-session-demands-it ()
  (let ((session (kubect-session-create
                  :name "ctx/ns/pods"
                  :context "ctx"
                  :namespace "ns"
                  :resource "pods"
                  :wide t)))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args)
                 (should (equal args
                                (list "--context" "ctx"
                                      "--namespace" "ns"
                                      "get" "pods" "-o" "wide")))
                 "NAME   READY   STATUS")))
      (should (equal (kubect--table-output session)
                     "NAME   READY   STATUS")))))

(ert-deftest kubect-table-output-supports_all_namespaces_sessions ()
  (let ((session (kubect-session-create
                  :name "ctx/all/pods"
                  :context "ctx"
                  :namespace kubect-all-namespaces-token
                  :resource "pods")))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args)
                 (should (equal args
                                (list "--context" "ctx"
                                      "--all-namespaces=true"
                                      "get" "pods")))
                 "NAMESPACE NAME READY STATUS\ndefault api 1/1 Running")))
      (should (string-match-p "default api" (kubect--table-output session))))))

(ert-deftest kubect-table-output-applies-session-field-selector ()
  (let ((session (kubect-session-create
                  :name "ctx/all/pods [node:node-a]"
                  :context "ctx"
                  :namespace kubect-all-namespaces-token
                  :resource "pods"
                  :field-selector "spec.nodeName=node-a"
                  :scope-label "node:node-a")))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args)
                 (should (equal args
                                (list "--context" "ctx" "--all-namespaces=true"
                                      "get" "pods" "--field-selector"
                                      "spec.nodeName=node-a")))
                 "NAMESPACE NAME\ndefault api")))
      (should (equal (kubect--table-output session) "NAMESPACE NAME\ndefault api")))))

(ert-deftest kubect-resource-name-at-point-uses-first-cli-column ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"))
    (let ((inhibit-read-only t))
      (insert "NAME        READY   STATUS\napi-7f6d9   1/1     Running\n"))
    (goto-char (point-min))
    (forward-line 1)
    (should (equal (kubect--resource-name-at-point) "api-7f6d9"))))

(ert-deftest kubect-resource-name-at-point-uses_second_column_for_all_namespaces ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/all/pods"
                 :context "ctx"
                 :namespace kubect-all-namespaces-token
                 :resource "pods"))
    (let ((inhibit-read-only t))
      (insert "NAMESPACE NAME READY STATUS\npayments api-7f6d9 1/1 Running\n"))
    (goto-char (point-min))
    (forward-line 1)
    (should (equal (kubect--resource-name-at-point) "api-7f6d9"))
    (should (equal (kubect--namespace-at-point) "payments"))))

(ert-deftest kubect-session-mode-binds-question-mark-to-dispatch ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "?")) #'kubect-session-dispatch))))

(ert-deftest kubect-session-mode-binds-k-to-help ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "K")) #'kubect-help))))

(ert-deftest kubect-session-mode-binds-x-and-i-to-direct-actions ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "x")) #'kubect-describe-resource))
    (should (eq (key-binding (kbd "I")) #'kubect-investigation-profile))))

(ert-deftest kubect-session-mode-keeps-global-navigation-shortcuts-useful ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "N")) #'kubect-all-namespaces))
    (should (eq (key-binding (kbd "P")) #'kubect-pods-all-namespaces))
    (should (eq (key-binding (kbd "B")) #'kubect-switch-session))
    (should (eq (key-binding (kbd "T")) #'kubect-top-nodes))
    (should (eq (key-binding (kbd "C-c N")) #'kubect-nodes))))

(ert-deftest kubect-prefix-map-binds-n-to-all-namespaces-browser ()
  (should (eq (lookup-key kubect-prefix-map (kbd "N"))
              #'kubect-all-namespaces)))

(ert-deftest kubect-prefix-map-binds-control-n-to-node-browser ()
  (should (eq (lookup-key kubect-prefix-map (kbd "C-c N")) #'kubect-nodes)))

(ert-deftest kubect-prefix-map-binds-uppercase-i-to-investigation-profile ()
  (should (eq (lookup-key kubect-prefix-map (kbd "I"))
              #'kubect-investigation-profile)))

(ert-deftest kubect-prefix-map-binds-dot-to-home ()
  (should (eq (lookup-key kubect-prefix-map (kbd "."))
              #'kubect-home)))

(ert-deftest kubect-session-mode-binds-uppercase-s-to-filter-presets ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "S")) #'kubect-session-apply-filter-preset))))

(ert-deftest kubect-session-mode-binds-control-c-f-to-column-filter ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "C-c f")) #'kubect-session-set-column-filter))))

(ert-deftest kubect-session-mode-binds-comma-to-sort-presets ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd ",")) #'kubect-session-apply-sort-preset))))

(ert-deftest kubect-session-mode-binds-bracket-shortcuts-to-common-sorts ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "[")) #'kubect-session-sort-by-age))
    (should (eq (key-binding (kbd "]")) #'kubect-session-sort-by-restarts))
    (should (eq (key-binding (kbd "{")) #'kubect-session-sort-by-status))))

(ert-deftest kubect-session-mode-binds-v-to-events ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "v")) #'kubect-events))))

(ert-deftest kubect-session-mode-binds-xray-and-timeline-keys ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "X")) #'kubect-xray))
    (should (eq (key-binding (kbd "y")) #'kubect-timeline))
    (should (eq (key-binding (kbd "Y")) #'kubect-timeline-for-resource))))

(ert-deftest kubect-all-namespaces-opens_requested_resource ()
  (let (opened)
    (cl-letf (((symbol-function 'kubect-current-context)
               (lambda () "ctx"))
              ((symbol-function 'kubect-open)
               (lambda (context namespace resource filter display-action)
                 (setq opened (list context namespace resource filter display-action)))))
      (kubect-all-namespaces '(4) "deployments" "api")
      (should (equal opened
                     '("ctx" "*all*" "deployments" "api" pop-up))))))

(ert-deftest kubect-session-apply-filter-preset-uses_regex_and_label ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/all/pods"
                 :context "ctx"
                 :namespace kubect-all-namespaces-token
                 :resource "pods"))
    (cl-letf (((symbol-function 'kubect-refresh) (lambda () nil)))
      (kubect-session-apply-filter-preset "crashing"))
    (should (equal (kubect-session-filter-label kubect-session) "crashing"))
    (should (eq (kubect-session-filter-mode kubect-session) 'regexp))
    (should (string-match-p "CrashLoopBackOff"
                            (kubect-session-filter kubect-session)))
    (should (equal (kubect-session-sort-label kubect-session) "status"))))

(ert-deftest kubect-session-apply-sort-preset-sets_sort_state ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/all/pods"
                 :context "ctx"
                 :namespace kubect-all-namespaces-token
                 :resource "pods"))
    (cl-letf (((symbol-function 'kubect-refresh) (lambda () nil)))
      (kubect-session-apply-sort-preset "restarts"))
    (should (equal (kubect-session-sort-label kubect-session) "restarts"))
    (should (equal (kubect-session-sort-column kubect-session) "RESTARTS"))
    (should (eq (kubect-session-sort-parser kubect-session) 'integer))
    (should (kubect-session-sort-descending kubect-session))))

(ert-deftest kubect-session-sort-shortcuts-apply_expected_presets ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/all/pods"
                 :context "ctx"
                 :namespace kubect-all-namespaces-token
                 :resource "pods"))
    (cl-letf (((symbol-function 'kubect-refresh) (lambda () nil)))
      (kubect-session-sort-by-status)
      (should (equal (kubect-session-sort-label kubect-session) "status"))
      (kubect-session-sort-by-age)
      (should (equal (kubect-session-sort-label kubect-session) "age"))
      (kubect-session-sort-by-restarts)
      (should (equal (kubect-session-sort-label kubect-session) "restarts")))))

(ert-deftest kubect-investigation-profile-opens_session_and_applies_presets ()
  (let (opened session profile-actions)
    (setq session (kubect-session-create
                   :name "ctx/*all*/pods"
                   :context "ctx"
                   :namespace kubect-all-namespaces-token
                   :resource "pods"))
    (cl-letf (((symbol-function 'kubect--investigation-profile-spec)
               (lambda (_name)
                 '(:resource "pods" :all-namespaces t :filter-preset "crashing" :sort-preset "status" :wide t
                   :after-open (incident-debug top))))
              ((symbol-function 'kubect-current-context) (lambda () "ctx"))
              ((symbol-function 'kubect-current-namespace) (lambda () "default"))
              ((symbol-function 'kubect-current-resource) (lambda () "pods"))
              ((symbol-function 'kubect-open)
               (lambda (context namespace resource filter display-action)
                 (setq opened (list context namespace resource filter display-action))
                 (setf (kubect-session-buffer session) (current-buffer))
                 session))
              ((symbol-function 'kubect--run-profile-action)
               (lambda (action)
                 (push action profile-actions)))
              ((symbol-function 'kubect-refresh) (lambda () nil)))
      (with-temp-buffer
        (setq-local kubect-session session)
        (kubect-investigation-profile "crashing-pods" '(4))
        (should (equal opened '("ctx" "*all*" "pods" nil pop-up)))
        (should (equal (kubect-session-filter-label session) "crashing"))
        (should (equal (kubect-session-sort-label session) "status"))
        (should (kubect-session-wide session))
        (should (equal (nreverse profile-actions) '(incident-debug top)))))))

(ert-deftest kubect-session-mode-binds-z-to-watch-events ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "z")) #'kubect-watch-events))))

(ert-deftest kubect-session-mode-binds-uppercase-z-to-watch-events-for-resource ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "Z")) #'kubect-watch-events-for-resource))))

(ert-deftest kubect-session-mode-binds-h-to-session-history ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "H")) #'kubect-session-history))))

(ert-deftest kubect-session-mode-binds-t-to-top-resource ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "t")) #'kubect-top-resource))))

(ert-deftest kubect-session-mode-binds-c-to-selector-logs ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "C")) #'kubect-logs-selector-resource))))

(ert-deftest kubect-session-mode-binds-o-to-occur ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "o")) #'kubect-occur))))

(ert-deftest kubect-session-mode-binds-w-to-watch-toggle ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "w")) #'kubect-toggle-watch))))

(ert-deftest kubect-session-mode-binds-bang-to-debug-restarts ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "!")) #'kubect-debug-restarts-resource))))

(ert-deftest kubect-session-mode-binds-i-to-incident-dispatch ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "i")) #'kubect-incident-dispatch))))

(ert-deftest kubect-session-mode-binds-j-to-related-jump ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "j")) #'kubect-jump-to-related-resource))))

(ert-deftest kubect-session-mode-binds-b-to-resource-urls ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "b")) #'kubect-resource-urls))))

(ert-deftest kubect-session-mode-binds-equals-to-rollout-diff ()
  (with-temp-buffer
    (kubect-session-mode)
    (should (eq (key-binding (kbd "=")) #'kubect-rollout-diff-resource))))

(ert-deftest kubect-session-mark-unmark-and-clear-update-session-state ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"))
    (cl-letf (((symbol-function 'kubect--resource-identifiers-at-point)
               (lambda () '("pod/api-123")))
              ((symbol-function 'kubect--session-apply-highlights) (lambda () nil)))
      (kubect-session-mark)
      (should (equal (kubect-session-marked-resources kubect-session)
                     '("pod/api-123")))
      (kubect-session-unmark)
      (should-not (kubect-session-marked-resources kubect-session))
      (setf (kubect-session-marked-resources kubect-session) '("pod/api-123" "pod/api-456"))
      (kubect-session-clear-marks)
      (should-not (kubect-session-marked-resources kubect-session)))))

(ert-deftest kubect-session-bulk-action-describe-uses-one-consolidated-buffer ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"
                 :marked-resources '("pod/api-123" "pod/api-456")))
    (let (displayed)
      (cl-letf (((symbol-function 'kubect--kubectl-output)
                 (lambda (&rest args)
                   (pcase args
                     (`("--context" "ctx" "--namespace" "ns" "describe" "pod" "api-123")
                      "describe api-123")
                     (`("--context" "ctx" "--namespace" "ns" "describe" "pod" "api-456")
                      "describe api-456")
                     (_ (error "Unexpected args: %S" args)))))
                ((symbol-function 'kubect--display-buffer)
                 (lambda (buffer)
                   (setq displayed buffer))))
        (kubect-session-bulk-action "describe")
        (with-current-buffer displayed
          (should (eq major-mode 'kubect-report-mode))
          (should (string-match-p "== pod/api-123 ==" (buffer-string)))
          (should (string-match-p "describe api-123" (buffer-string)))
          (should (string-match-p "== pod/api-456 ==" (buffer-string)))
          (should (string-match-p "describe api-456" (buffer-string))))))))

(ert-deftest kubect-session-bulk-action-rollout-status-uses-one-consolidated-buffer ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/deployments"
                 :context "ctx"
                 :namespace "ns"
                 :resource "deployments"
                 :marked-resources '("deployment/api" "statefulset/db" "pod/ignored")))
    (let (displayed)
      (cl-letf (((symbol-function 'kubect--kubectl-output)
                 (lambda (&rest args)
                   (pcase args
                     (`("--context" "ctx" "--namespace" "ns" "rollout" "status" "deployment/api")
                      "deployment status ok")
                     (`("--context" "ctx" "--namespace" "ns" "rollout" "status" "statefulset/db")
                      "statefulset status ok")
                     (_ (error "Unexpected args: %S" args)))))
                ((symbol-function 'kubect--display-buffer)
                 (lambda (buffer)
                   (setq displayed buffer))))
        (kubect-session-bulk-action "rollout-status")
        (with-current-buffer displayed
          (should (eq major-mode 'kubect-report-mode))
          (should (string-match-p "== deployment/api ==" (buffer-string)))
          (should (string-match-p "deployment status ok" (buffer-string)))
          (should (string-match-p "== statefulset/db ==" (buffer-string)))
          (should (string-match-p "statefulset status ok" (buffer-string)))
          (should-not (string-match-p "ignored" (buffer-string))))))))

(ert-deftest kubect-session-bulk-action-rollout-status-errors-without-supported-marks ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"
                 :marked-resources '("pod/api-123")))
    (should-error (kubect-session-bulk-action "rollout-status")
                  :type 'user-error)))

(ert-deftest kubect-session-bulk-action-logs-opens-review-buffer ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"
                 :marked-resources '("pod/api-123" "pod/api-456")))
    (let (displayed)
      (cl-letf (((symbol-function 'kubect--display-buffer)
                 (lambda (buffer)
                   (setq displayed buffer))))
        (kubect-session-bulk-action "logs")
        (with-current-buffer displayed
          (should (eq major-mode 'kubect-bulk-review-mode))
          (should (equal (plist-get kubect-bulk-review-state :action) "logs"))
          (should (string-match-p "pod/api-123" (buffer-string)))
          (should (string-match-p "pod/api-456" (buffer-string))))))))

(ert-deftest kubect-session-bulk-action-top-summary-uses_one_consolidated_buffer ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"
                 :marked-resources '("pod/api-123" "pod/api-456")))
    (let (displayed)
      (cl-letf (((symbol-function 'kubect--kubectl-output)
                 (lambda (&rest args)
                   (pcase args
                     (`("--context" "ctx" "--namespace" "ns" "top" "pod" "api-123" "--containers=true")
                      "api-123 10m 30Mi")
                     (`("--context" "ctx" "--namespace" "ns" "top" "pod" "api-456" "--containers=true")
                      "api-456 12m 32Mi")
                     (_ (error "Unexpected args: %S" args)))))
                ((symbol-function 'kubect--display-buffer)
                 (lambda (buffer)
                   (setq displayed buffer))))
        (kubect-session-bulk-action "top-summary")
        (with-current-buffer displayed
          (should (eq major-mode 'kubect-report-mode))
          (should (string-match-p "== pod/api-123 ==" (buffer-string)))
          (should (string-match-p "api-123 10m 30Mi" (buffer-string)))
          (should (string-match-p "== pod/api-456 ==" (buffer-string))))))))

(ert-deftest kubect-bulk-review-visit-opens-current-resource-action ()
  (with-temp-buffer
    (kubect-bulk-review-mode)
    (setq-local kubect-bulk-review-state
                (list :action "logs"
                      :resources
                      '((:kind "pod" :name "api-123" :context "ctx" :namespace "ns")
                        (:kind "pod" :name "api-456" :context "ctx" :namespace "ns"))))
    (kubect--bulk-review-render)
    (goto-char (point-min))
    (search-forward "pod/api-456")
    (beginning-of-line)
    (let (opened)
      (cl-letf (((symbol-function 'kubect--bulk-open-resource)
                 (lambda (_action resource &optional _arg)
                   (setq opened resource))))
        (kubect-bulk-review-visit)
        (should (equal (plist-get opened :name) "api-456"))))))

(ert-deftest kubect-bulk-review-visit-all-opens-all-resources ()
  (with-temp-buffer
    (kubect-bulk-review-mode)
    (setq-local kubect-bulk-review-state
                (list :action "events"
                      :resources
                      '((:kind "pod" :name "api-123" :context "ctx" :namespace "ns")
                        (:kind "pod" :name "api-456" :context "ctx" :namespace "ns"))))
    (let (opened)
      (cl-letf (((symbol-function 'kubect--bulk-open-resource)
                 (lambda (_action resource &optional _arg)
                   (push (plist-get resource :name) opened))))
        (kubect-bulk-review-visit-all)
        (should (equal opened '("api-456" "api-123")))))))

(ert-deftest kubect-bulk-review-filter-restricts-visible-resources ()
  (with-temp-buffer
    (kubect-bulk-review-mode)
    (setq-local kubect-bulk-review-state
                (list :action "logs"
                      :resources
                      '((:kind "pod" :name "api-123" :context "ctx" :namespace "ns")
                        (:kind "pod" :name "worker-1" :context "ctx" :namespace "ns"))
                      :all-resources
                      '((:kind "pod" :name "api-123" :context "ctx" :namespace "ns")
                        (:kind "pod" :name "worker-1" :context "ctx" :namespace "ns"))))
    (kubect-bulk-review-filter "api")
    (should (equal (length (plist-get kubect-bulk-review-state :resources)) 1))
    (should (string-match-p "pod/api-123" (buffer-string)))
    (should-not (string-match-p "worker-1" (buffer-string)))))

(ert-deftest kubect-bulk-review-remove-drops-current-entry ()
  (with-temp-buffer
    (kubect-bulk-review-mode)
    (setq-local kubect-bulk-review-state
                (list :action "logs"
                      :resources
                      '((:kind "pod" :name "api-123" :context "ctx" :namespace "ns")
                        (:kind "pod" :name "worker-1" :context "ctx" :namespace "ns"))
                      :all-resources
                      '((:kind "pod" :name "api-123" :context "ctx" :namespace "ns")
                        (:kind "pod" :name "worker-1" :context "ctx" :namespace "ns"))))
    (kubect--bulk-review-render)
    (goto-char (point-min))
    (search-forward "pod/api-123")
    (beginning-of-line)
    (kubect-bulk-review-remove)
    (should-not (string-match-p "pod/api-123" (buffer-string)))
    (should (string-match-p "worker-1" (buffer-string)))))

(ert-deftest kubect-session-bulk-action-event-summary-uses-one-consolidated-buffer ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"
                 :marked-resources '("pod/api-123" "pod/api-456")))
    (let (displayed)
      (cl-letf (((symbol-function 'kubect--event-summary-lines-for-resource)
                 (lambda (resource)
                   (list (format "summary for %s" (plist-get resource :name)))))
                ((symbol-function 'kubect--display-buffer)
                 (lambda (buffer)
                   (setq displayed buffer))))
        (kubect-session-bulk-action "event-summary")
        (with-current-buffer displayed
          (should (eq major-mode 'kubect-report-mode))
          (should (string-match-p "== pod/api-123 ==" (buffer-string)))
          (should (string-match-p "summary for api-123" (buffer-string)))
          (should (string-match-p "== pod/api-456 ==" (buffer-string))))))))

(ert-deftest kubect-session-bulk-action-log-snapshot-uses-one-consolidated-buffer ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"
                 :marked-resources '("pod/api-123" "pod/api-456")))
    (let (displayed)
      (cl-letf (((symbol-function 'kubect--pod-for-resource)
                 (lambda (_kind name _context _namespace)
                   name))
                ((symbol-function 'kubect--read-container)
                 (lambda (&rest _args) nil))
                ((symbol-function 'kubect--kubectl-output)
                 (lambda (&rest args)
                   (pcase args
                     (`("--context" "ctx" "--namespace" "ns" "logs" "--tail=200" "api-123")
                      "logs api-123")
                     (`("--context" "ctx" "--namespace" "ns" "logs" "--tail=200" "api-456")
                      "logs api-456")
                     (_ (error "Unexpected args: %S" args)))))
                ((symbol-function 'kubect--display-buffer)
                 (lambda (buffer)
                   (setq displayed buffer))))
        (kubect-session-bulk-action "log-snapshot")
        (with-current-buffer displayed
          (should (eq major-mode 'kubect-report-mode))
          (should (string-match-p "== pod/api-123 -> pod/api-123 ==" (buffer-string)))
          (should (string-match-p "logs api-123" (buffer-string)))
          (should (string-match-p "== pod/api-456 -> pod/api-456 ==" (buffer-string)))
          (should (string-match-p "logs api-456" (buffer-string))))))))

(ert-deftest kubect-session-bulk-action-log-snapshot-last-5m-adds_since_option ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"
                 :marked-resources '("pod/api-123")))
    (let (seen)
      (cl-letf (((symbol-function 'kubect--pod-for-resource)
                 (lambda (_kind name _context _namespace)
                   name))
                ((symbol-function 'kubect--read-container)
                 (lambda (&rest _args) nil))
                ((symbol-function 'kubect--bulk-log-snapshot-output)
                 (lambda (_pod _container _context _namespace options)
                   (setq seen options)
                   "logs"))
                ((symbol-function 'kubect--display-buffer)
                 (lambda (_buffer) nil)))
        (kubect-session-bulk-action "log-snapshot-last-5m")
        (should (equal (plist-get seen :since) "5m"))))))

(ert-deftest kubect-session-toggle-wide-flips-session-state ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"
                 :wide nil))
    (cl-letf (((symbol-function 'kubect-refresh) (lambda () nil)))
      (kubect-session-toggle-wide)
      (should (kubect-session-wide kubect-session))
      (kubect-session-toggle-wide)
      (should-not (kubect-session-wide kubect-session)))))

(ert-deftest kubect-stream-mode-binds-o-to-occur ()
  (with-temp-buffer
    (kubect-stream-mode)
    (should (eq (key-binding (kbd "o")) #'kubect-occur))))

(ert-deftest kubect-stream-mode-binds-f-to-preset-occur ()
  (with-temp-buffer
    (kubect-stream-mode)
    (should (eq (key-binding (kbd "F")) #'kubect-stream-occur-preset))))

(ert-deftest kubect-stream-mode-binds-t-to-timestamps-toggle ()
  (with-temp-buffer
    (kubect-stream-mode)
    (should (eq (key-binding (kbd "t")) #'kubect-stream-toggle-timestamps))))

(ert-deftest kubect-stream-mode-binds-q-to-stop-and-dismiss ()
  (with-temp-buffer
    (kubect-stream-mode)
    (should (eq (key-binding (kbd "q")) #'kubect-quit-stream))))

(ert-deftest kubect-quit-stream-stops-its-process ()
  (with-temp-buffer
    (kubect-stream-mode)
    (let ((process (make-process :name "kubect-test-stream-quit"
                                 :buffer (current-buffer)
                                 :command '("/bin/cat")
                                 :noquery t)))
      (unwind-protect
          (cl-letf (((symbol-function 'quit-window) #'ignore))
            (kubect-quit-stream)
            (should-not (process-live-p process)))
        (when (process-live-p process) (delete-process process))))))

(ert-deftest kubect-static-browser-modes-bind-q-explicitly ()
  (with-temp-buffer
    (kubect-file-browser-mode)
    (should (eq (key-binding (kbd "q")) #'quit-window)))
  (with-temp-buffer
    (kubect-bulk-review-mode)
    (should (eq (key-binding (kbd "q")) #'quit-window))))

(ert-deftest kubect-stream-mode-binds-question-mark-to-dispatch ()
  (with-temp-buffer
    (kubect-stream-mode)
    (should (eq (key-binding (kbd "?")) #'kubect-stream-dispatch))))

(ert-deftest kubect-stream-toggle-timestamps-restarts_log_stream ()
  (with-temp-buffer
    (kubect-stream-mode)
    (setq-local kubect-stream-state
                '(:mode logs
                  :name "logs api-123"
                  :pod "api-123"
                  :container "app"
                  :context "ctx"
                  :namespace "ns"
                  :previous nil
                  :all-containers nil
                  :timestamps nil))
    (let (restarted)
      (cl-letf (((symbol-function 'kubect--restart-stream)
                 (lambda ()
                   (setq restarted (plist-get kubect-stream-state :timestamps)))))
        (kubect-stream-toggle-timestamps)
        (should restarted)
        (should (plist-get kubect-stream-state :timestamps))))))

(ert-deftest kubect-stream-occur-preset-updates_header_and_runs_occur ()
  (with-temp-buffer
    (kubect-stream-mode)
    (setq-local kubect-stream-state '(:mode logs :timestamps nil))
    (let (seen)
      (cl-letf (((symbol-function 'kubect--completing-read)
                 (lambda (&rest _args) "errors"))
                ((symbol-function 'occur)
                 (lambda (regexp)
                   (setq seen regexp))))
        (kubect-stream-occur-preset)
        (should (equal seen "\\b\\(ERROR\\|FATAL\\|Error\\|panic\\|exception\\)\\b"))
        (should (equal (plist-get kubect-stream-state :last-filter-preset) "errors"))
        (should (string-match-p "preset=errors" header-line-format))))))

(ert-deftest kubect-top-resource-resolves_pod_for_deployment ()
  (let (displayed)
    (with-temp-buffer
      (kubect-session-mode)
      (let ((inhibit-read-only t))
        (insert "NAME READY STATUS RESTARTS AGE\napi 1/1 Running 0 1h\n"))
      (goto-char (point-min))
      (forward-line 1)
      (cl-letf (((symbol-function 'kubect--current-line-resource-plist)
                 (lambda ()
                   '(:kind "deployment" :name "api" :context "ctx" :namespace "ns")))
                ((symbol-function 'kubect--pod-for-resource)
                 (lambda (&rest _args) "api-123"))
                ((symbol-function 'kubect--kubectl-output)
                 (lambda (&rest args)
                   (should (equal args
                                  '("--context" "ctx" "--namespace" "ns"
                                    "top" "pod" "api-123" "--containers=true")))
                   "POD CPU MEMORY"))
                ((symbol-function 'kubect--display-buffer)
                 (lambda (buffer)
                   (setq displayed buffer))))
        (kubect-top-resource)
        (with-current-buffer displayed
          (should (string-match-p "POD CPU MEMORY" (buffer-string))))))))

;;; test-session.el ends here
