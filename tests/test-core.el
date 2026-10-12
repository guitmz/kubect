;;; test-core.el --- kubect tests -*- lexical-binding: t; -*-

(require 'test-support)

(ert-deftest kubect-memory-unit-conversions ()
  (dolist (example '(("1048576" . 1.0) ("1024Ki" . 1.0)
                     ("1Gi" . 1024.0) ("1048.576K" . 1.0)
                     ("1.048576M" . 1.0) ("1G" . 953.67431640625)))
    (should (< (abs (- (kubect--memory-mib (car example)) (cdr example)))
               0.000001))))

(ert-deftest kubect-selector-candidates-deduplicate-labels ()
  (cl-letf (((symbol-function 'kubect--kubectl-json)
             (lambda (&rest args)
               (should (equal args '("--context" "ctx" "--namespace" "ns"
                                     "get" "pods" "-o" "json")))
               (let ((json-object-type 'alist) (json-array-type 'list)
                     (json-key-type 'symbol))
                 (json-read-from-string
                  "{\"items\":[{\"metadata\":{\"labels\":{\"app\":\"api\",\"empty\":\"\"}}},{\"metadata\":{\"labels\":{\"app\":\"api\"}}},{\"metadata\":{}}]}")))))
    (should (equal (kubect--log-selector-candidates "ctx" "ns")
                   '("app" "app=api" "empty" "empty=")))))

(ert-deftest kubect-kubectl-output-returns-stdout ()
  (let ((kubect-kubectl-command "sh"))
    (should (equal (kubect--kubectl-output "-c" "printf success")
                   "success"))))

(ert-deftest kubect-ensure-kubectl-uses-remote-host-path-in-tramp-buffers ()
  (let ((kubect-kubectl-command "remote-kubectl"))
    (cl-letf (((symbol-function 'file-remote-p) (lambda (&rest _) t))
              ((symbol-function 'executable-find)
               (lambda (&rest _) (error "Local lookup must not run"))))
      (should (equal (kubect--ensure-kubectl) "remote-kubectl")))))

(ert-deftest kubect-list-namespaces-checks-rbac-before-listing ()
  (let (calls)
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args)
                 (push args calls)
                 (pcase args
                   (`("--context" "team" "auth" "can-i" "list" "namespaces") "yes")
                   (`("--context" "team" "get" "namespaces" "-o" ,_) "default\napps\n")
                   (_ (error "Unexpected command: %S" args))))))
      (should (equal (kubect--list-namespaces "team")
                     (list kubect-all-namespaces-token "default" "apps")))
      (should (equal (nreverse calls)
                     '(("--context" "team" "auth" "can-i" "list" "namespaces")
                       ("--context" "team" "get" "namespaces" "-o"
                        "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")))))))

(ert-deftest kubect-list-namespaces-does-not-list-when-rbac-denies-it ()
  (let (calls)
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args)
                 (push args calls)
                 "no")))
      (should-not (kubect--list-namespaces "team"))
      (should (equal calls
                     '(("--context" "team" "auth" "can-i" "list" "namespaces")))))))

(ert-deftest kubect-read-namespace-allows-manual-entry-without-list-permission ()
  (let (prompt initial)
    (cl-letf (((symbol-function 'kubect--list-namespaces) (lambda (&rest _) nil))
              ((symbol-function 'kubect-current-namespace) (lambda () "default"))
              ((symbol-function 'read-string)
               (lambda (value default &rest _)
                 (setq prompt value initial default)
                 "restricted")))
      (should (equal (kubect--read-namespace "team") "restricted"))
      (should (equal prompt "Namespace: "))
      (should (equal initial "default")))))

(ert-deftest kubect-kubectl-output-includes-stderr-and-stdout-on-failure ()
  (let ((kubect-kubectl-command "sh"))
    (should
     (string-match-p
      (regexp-quote "kubectl failed (exit 7): -c printf out; printf err >&2; exit 7\nstderr:\nerr\nstdout:\nout")
      (condition-case err
          (progn
            (kubect--kubectl-output "-c" "printf out; printf err >&2; exit 7")
            "")
        (error (error-message-string err)))))))

(ert-deftest kubect-display-buffer-uses-switch-to-buffer-in-same-window-mode ()
  (let ((kubect-display-buffer-action 'same-window)
        (switched nil)
        (popped nil))
    (cl-letf (((symbol-function 'switch-to-buffer)
               (lambda (buffer &rest _)
                 (setq switched buffer)))
              ((symbol-function 'pop-to-buffer)
               (lambda (buffer &rest _)
                 (setq popped buffer))))
      (with-temp-buffer
        (kubect--display-buffer (current-buffer))
        (should (bufferp switched))
        (should-not popped)))))

(ert-deftest kubect-display-buffer-uses-pop-to-buffer-in-pop-up-mode ()
  (let ((kubect-display-buffer-action 'pop-up)
        (switched nil)
        (popped nil))
    (cl-letf (((symbol-function 'switch-to-buffer)
               (lambda (buffer &rest _)
                 (setq switched buffer)))
              ((symbol-function 'pop-to-buffer)
               (lambda (buffer &rest _)
                 (setq popped buffer))))
      (with-temp-buffer
        (kubect--display-buffer (current-buffer))
        (should (bufferp popped))
        (should-not switched)))))

(ert-deftest kubect-display-action-from-prefix-forces-pop-up ()
  (should (eq (kubect--display-action-from-prefix '(4)) 'pop-up))
  (should-not (kubect--display-action-from-prefix nil)))

(ert-deftest kubect-kubectl-base-args-supports_all_namespaces ()
  (should (equal (kubect--kubectl-base-args "ctx" kubect-all-namespaces-token)
                 '("--context" "ctx" "--all-namespaces=true"))))

(ert-deftest kubect-list-namespaced-resources-excludes-cluster-scoped-kinds ()
  (cl-letf (((symbol-function 'kubect--kubectl-output)
             (lambda (&rest args)
               (should (equal args
                              '("--context" "ctx"
                                "api-resources" "--verbs=list" "--namespaced=true" "-o" "name")))
               "pods\nservices\nwidgets.example.com\n")))
    (let ((resources (kubect--list-namespaced-resources "ctx")))
      (should (member "pods" resources))
      (should (member "services" resources))
      (should (member "widgets.example.com" resources))
      (should-not (member "nodes" resources))
      (should-not (member "namespaces" resources)))))

(ert-deftest kubect-table-output-uses-regexp-session-filters-for-presets ()
  (let ((session (kubect-session-create
                  :name "ctx/all/pods"
                  :context "ctx"
                  :namespace kubect-all-namespaces-token
                  :resource "pods"
                  :filter "CrashLoopBackOff\\|ImagePullBackOff"
                  :filter-mode 'regexp
                  :filter-label "crashing")))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest _args)
                 (string-join
                  '("NAMESPACE NAME READY STATUS RESTARTS AGE"
                    "default api-1 0/1 CrashLoopBackOff 7 1m"
                    "ops worker-2 0/1 ImagePullBackOff 0 30s"
                    "default web-3 1/1 Running 0 10m")
                  "\n"))))
      (should
       (equal (kubect--table-output session)
              (string-join
               '("NAMESPACE NAME READY STATUS RESTARTS AGE"
                 "default api-1 0/1 CrashLoopBackOff 7 1m"
                 "ops worker-2 0/1 ImagePullBackOff 0 30s")
               "\n"))))))

(ert-deftest kubect-table-output-sorts-by_restarts_descending ()
  (let ((session (kubect-session-create
                  :name "ctx/all/pods"
                  :context "ctx"
                  :namespace kubect-all-namespaces-token
                  :resource "pods"
                  :sort-label "restarts"
                  :sort-column "RESTARTS"
                  :sort-parser 'integer
                  :sort-descending t)))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest _args)
                 (string-join
                  '("NAMESPACE NAME READY STATUS RESTARTS AGE"
                    "default api-1 0/1 Running 2 10m"
                    "ops worker-2 0/1 Running 7 1m"
                    "default web-3 1/1 Running 0 30m")
                  "\n"))))
      (should
       (equal (kubect--table-output session)
              (string-join
               '("NAMESPACE NAME READY STATUS RESTARTS AGE"
                 "ops worker-2 0/1 Running 7 1m"
                 "default api-1 0/1 Running 2 10m"
                 "default web-3 1/1 Running 0 30m")
               "\n"))))))

(ert-deftest kubect-table-output-sorts-by_age_ascending ()
  (let ((session (kubect-session-create
                  :name "ctx/all/pods"
                  :context "ctx"
                  :namespace kubect-all-namespaces-token
                  :resource "pods"
                  :sort-label "age"
                  :sort-column "AGE"
                  :sort-parser 'age
                  :sort-descending nil)))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest _args)
                 (string-join
                  '("NAMESPACE NAME READY STATUS RESTARTS AGE"
                    "default api-1 0/1 Running 2 10m"
                    "ops worker-2 0/1 Running 7 30s"
                    "default web-3 1/1 Running 0 1h")
                  "\n"))))
      (should
       (equal (kubect--table-output session)
              (string-join
               '("NAMESPACE NAME READY STATUS RESTARTS AGE"
                 "ops worker-2 0/1 Running 7 30s"
                 "default api-1 0/1 Running 2 10m"
                 "default web-3 1/1 Running 0 1h")
               "\n"))))))

(ert-deftest kubect-table-output-sorts-by_status_unhealthy_first ()
  (let ((session (kubect-session-create
                  :name "ctx/all/pods"
                  :context "ctx"
                  :namespace kubect-all-namespaces-token
                  :resource "pods"
                  :sort-label "status"
                  :sort-column "STATUS"
                  :sort-parser 'status
                  :sort-descending t)))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest _args)
                 (string-join
                  '("NAMESPACE NAME READY STATUS RESTARTS AGE"
                    "default web-3 1/1 Running 0 1h"
                    "ops worker-2 0/1 Pending 0 30s"
                    "default api-1 0/1 CrashLoopBackOff 7 10m")
                  "\n"))))
      (should
       (equal (kubect--table-output session)
              (string-join
               '("NAMESPACE NAME READY STATUS RESTARTS AGE"
                 "default api-1 0/1 CrashLoopBackOff 7 10m"
                 "ops worker-2 0/1 Pending 0 30s"
                 "default web-3 1/1 Running 0 1h")
               "\n"))))))

(ert-deftest kubect-prepare-edit-buffer-keymap-works-without-existing-local-map ()
  (with-temp-buffer
    (use-local-map nil)
    (kubect--prepare-edit-buffer-keymap)
    (should (keymapp (current-local-map)))))

(ert-deftest kubect-report-mode-binds-q-to-quit-window ()
  (with-temp-buffer
    (kubect-report-mode)
    (should (eq major-mode 'kubect-report-mode))
    (should (eq (key-binding (kbd "q")) #'kubect-quit-report))
    (should (eq (key-binding (kbd "o")) #'occur))
    (should (eq (key-binding (kbd "O")) #'kubect-report-open-url))
    (should (eq (key-binding (kbd "A")) #'kubect-report-open-all-urls))
    (should (eq (key-binding (kbd "w")) #'kubect-report-copy-url))
    (should (eq (key-binding (kbd "W")) #'kubect-report-copy-all-urls))
    (should (eq (key-binding (kbd "g")) #'kubect-report-refresh))
    (should (eq (key-binding (kbd "C-c C-k")) #'kubect-cancel-refresh))
    (should (eq (key-binding (kbd "C-c C-e")) #'kubect-show-refresh-error))
    (should (eq (key-binding (kbd "t")) #'kubect-report-toggle-watch))
    (should (eq (key-binding (kbd "c")) #'kubect-report-sort-top-by-cpu))
    (should (eq (key-binding (kbd "m")) #'kubect-report-sort-top-by-memory))))

(ert-deftest kubect-output-mode-binds_plain_output_keys ()
  (with-temp-buffer
    (kubect-output-mode)
    (should (eq major-mode 'kubect-output-mode))
    (should (eq (key-binding (kbd "q")) #'kubect-quit-report))
    (should (eq (key-binding (kbd "g")) #'kubect-output-refresh))
    (should (eq (key-binding (kbd "C-c C-k")) #'kubect-cancel-refresh))
    (should (eq (key-binding (kbd "C-c C-e")) #'kubect-show-refresh-error))
    (should (eq (key-binding (kbd "o")) #'occur))
    (should (eq (key-binding (kbd "?")) #'kubect-output-dispatch))))

(ert-deftest kubect-keymap-contracts-stay-in-sync-with-documentation ()
  (should (kubect-verify-keymaps)))

(ert-deftest kubect-show-report-buffer-stores_header_and_state ()
  (let (displayed)
    (cl-letf (((symbol-function 'kubect--display-buffer)
               (lambda (buffer)
                 (setq displayed buffer))))
      (kubect--show-report-buffer
       "report" "body" "ctx" "ns" nil
       "Window: test"
       '(:urls ("http://a.example"))))
    (with-current-buffer displayed
      (should (equal header-line-format "Window: test"))
      (should (equal kubect-report-state '(:urls ("http://a.example")))))))

(ert-deftest kubect-show-output-buffer-stores_header_and_state ()
  (let (displayed)
    (cl-letf (((symbol-function 'kubect--display-buffer)
               (lambda (buffer)
                 (setq displayed buffer))))
      (kubect--show-output-buffer
       "describe api" "Name: api\n" "ctx" "ns" nil
       "Describe: ctx/ns  pod/api"
       '(:refresh-fn ignore)))
    (with-current-buffer displayed
      (should (eq major-mode 'kubect-output-mode))
      (should (equal header-line-format "Describe: ctx/ns  pod/api"))
      (should (equal kubect-output-state '(:refresh-fn ignore))))))

(ert-deftest kubect-show-report-buffer-applies_explicit_title_faces ()
  (let (displayed)
    (cl-letf (((symbol-function 'kubect--display-buffer)
               (lambda (buffer)
                 (setq displayed buffer))))
      (kubect--show-report-buffer
       "report"
       (concat "OVERVIEW  ctx\n"
               "================\n"
               "body\n")
       "ctx" "ns" nil
       "Window: test"
       nil))
    (with-current-buffer displayed
      (should (eq (get-text-property (point-min) 'face)
                  'kubect-report-title-face))
      (search-forward "ctx")
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'kubect-report-subject-face)))))

(ert-deftest kubect-home-opens-pulses-report ()
  (let (displayed)
    (cl-letf (((symbol-function 'kubect-current-context) (lambda () "ctx"))
              ((symbol-function 'kubect-current-namespace) (lambda () "default"))
              ((symbol-function 'kubect-current-resource) (lambda () "pods"))
              ((symbol-function 'kubect--pods-health-summary)
               (lambda (_context scope)
                 (should (equal scope "default"))
                 '(:total 10 :unhealthy 2 :pending 1 :restarting 3
                   :samples ((:namespace "default" :name "api-0" :status "CrashLoopBackOff" :restarts 9)))))
              ((symbol-function 'kubect--event-warning-summary)
               (lambda (_context scope)
                 (should (equal scope "default"))
                 '(:warnings 4 :recent ("Warning  pod/api-0  BackOff  boom"))))
              ((symbol-function 'kubect--display-buffer)
               (lambda (buffer)
                 (setq displayed buffer))))
      (kubect-home))
    (with-current-buffer displayed
      (should (eq major-mode 'kubect-report-mode))
      (should (string-match-p "OVERVIEW  ctx" (buffer-string)))
      (should (string-match-p "Pulse scope: default" (buffer-string)))
      (should (string-match-p "Pods:[[:space:]]+10 total" (buffer-string)))
      (should (string-match-p "Unhealthy:[[:space:]]+2" (buffer-string)))
      (should (string-match-p "Warning events:[[:space:]]+4" (buffer-string))))))

(ert-deftest kubect-home-prefix-uses-all-namespaces-scope ()
  (let (displayed)
    (cl-letf (((symbol-function 'kubect-current-context) (lambda () "ctx"))
              ((symbol-function 'kubect-current-namespace) (lambda () "default"))
              ((symbol-function 'kubect-current-resource) (lambda () "pods"))
              ((symbol-function 'kubect--pods-health-summary)
               (lambda (_context scope)
                 (should (equal scope kubect-all-namespaces-token))
                 '(:total 1 :unhealthy 0 :pending 0 :restarting 0 :samples nil)))
              ((symbol-function 'kubect--event-warning-summary)
               (lambda (_context scope)
                 (should (equal scope kubect-all-namespaces-token))
                 '(:warnings 0 :recent nil)))
              ((symbol-function 'kubect--display-buffer)
               (lambda (buffer)
                 (setq displayed buffer))))
      (kubect-home '(4)))
    (with-current-buffer displayed
      (should (string-match-p "Pulse scope: all namespaces" (buffer-string))))))

(ert-deftest kubect-top-nodes-opens_node_capacity_report ()
  (let (displayed)
    (cl-letf (((symbol-function 'kubect--node-capacity-state)
               (lambda ()
                 '(:type plain
                   :title "node capacity"
                   :header "Node capacity: ctx"
                   :body "NODE CPU\nnode-a 1\n"
                   :context "ctx"
                   :namespace "*all*")))
              ((symbol-function 'kubect--record-session-command)
               (lambda (&rest _) nil))
              ((symbol-function 'kubect--display-buffer)
               (lambda (buffer)
                 (setq displayed buffer))))
      (kubect-top-nodes)
      (with-current-buffer displayed
        (should (string-match-p "NODE CPU" (buffer-string)))
        (should (equal header-line-format "Node capacity: ctx"))))))

(ert-deftest kubect-nodes-opens-cluster-scoped-node-browser ()
  (let (opened)
    (cl-letf (((symbol-function 'kubect-current-context) (lambda () "dev-cluster"))
              ((symbol-function 'kubect-open) (lambda (&rest args) (setq opened args))))
      (kubect-nodes '(4)))
    (should (equal opened '("dev-cluster" "" "nodes" nil pop-up nil "cluster nodes")))))

(ert-deftest kubect-describe-resource-honors_prefix_display_action ()
  (let (captured)
    (cl-letf (((symbol-function 'kubect--resource-plist-from-session)
               (lambda ()
                 '(:kind "pods" :name "api" :context "ctx" :namespace "ns")))
              ((symbol-function 'kubect--record-session-command)
               (lambda (&rest _) nil))
              ((symbol-function 'kubect--show-describe-resource)
               (lambda (kind name context namespace arg)
                 (setq captured (list kind name context namespace arg)))))
      (kubect-describe-resource '(4))
      (should (equal captured '("pods" "api" "ctx" "ns" (4)))))))

(ert-deftest kubect-describe-resource-at-point-honors_prefix_display_action ()
  (let (captured)
    (cl-letf (((symbol-function 'kubect--resource-for-command)
               (lambda ()
                 '(:kind "deployment" :name "api" :context "ctx" :namespace "ns")))
              ((symbol-function 'kubect--show-describe-resource)
               (lambda (kind name context namespace arg)
                 (setq captured (list kind name context namespace arg)))))
      (kubect-describe-resource-at-point '(4))
      (should (equal captured '("deployment" "api" "ctx" "ns" (4)))))))

(ert-deftest kubect-resource-for-command-prefers-session-row ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"))
    (let ((inhibit-read-only t))
      (insert "NAME READY STATUS RESTARTS AGE\napi 1/1 Running 0 1d\n"))
    (goto-char (point-min))
    (forward-line 1)
    (should (equal (kubect--resource-for-command)
                   '(:kind "pods" :name "api" :context "ctx" :namespace "ns")))))

(ert-deftest kubect-resource-for-command-passes-explicit-picker-scope ()
  (let (received)
    (cl-letf (((symbol-function 'kubect--resource-at-point) (lambda () nil))
              ((symbol-function 'kubect--resource-from-prompt)
               (lambda (&rest args)
                 (setq received args)
                 '(:kind "pods" :name "api" :context "ctx" :namespace "ns"))))
      (kubect--resource-for-command "ctx" "ns"))
    (should (equal received '(nil "ctx" "ns")))))

(ert-deftest kubect-resource-from-prompt-keeps-context-before-namespace ()
  "Prompted resources must use the canonical plist order used by reports."
  (cl-letf (((symbol-function 'kubect--read-kind) (lambda () "pods"))
            ((symbol-function 'kubect--list-resource-names) (lambda (&rest _) '("api")))
            ((symbol-function 'kubect--completing-read) (lambda (&rest _) "api")))
    (should (equal (kubect--resource-from-prompt nil "dev-cluster" "team-a")
                   '(:kind "pods" :name "api" :context "dev-cluster" :namespace "team-a")))))

(ert-deftest kubect-xray-opens-related-resource-report ()
  (let (displayed)
    (cl-letf (((symbol-function 'kubect--resource-for-command)
               (lambda ()
                 '(:kind "deployment" :name "api" :context "ctx" :namespace "default")))
              ((symbol-function 'kubect--resource-basic-summary)
               (lambda (&rest _)
                 '(:owners nil :spec nil :data nil)))
              ((symbol-function 'kubect--selector-for-resource)
               (lambda (&rest _) "app=api"))
              ((symbol-function 'kubect--pod-names-for-selector)
               (lambda (&rest _) '("api-0" "api-1")))
              ((symbol-function 'kubect--resource-event-items)
               (lambda (&rest _) nil))
              ((symbol-function 'kubect--resource-url-lines)
               (lambda (&rest _) nil))
              ((symbol-function 'kubect--deployment-replicasets)
               (lambda (&rest _)
                 '((:name "api-rs-1" :revision 1) (:name "api-rs-2" :revision 2))))
              ((symbol-function 'kubect--record-session-command)
               (lambda (&rest _) nil))
              ((symbol-function 'kubect--display-buffer)
               (lambda (buffer)
                 (setq displayed buffer))))
      (kubect-xray))
    (with-current-buffer displayed
      (should (eq major-mode 'kubect-report-mode))
      (should (string-match-p "XRAY  deployment/api" (buffer-string)))
      (should (string-match-p "selector: app=api" (buffer-string)))
      (should (string-match-p "pod/api-0" (buffer-string)))
      (should (string-match-p "replicaset/api-rs-2 revision=2" (buffer-string))))))

(ert-deftest kubect-open-exec-buffer-uses-custom-function-when-set ()
  (let (captured)
    (let ((kubect-exec-open-function
           (lambda (buffer-name command args display-action)
             (setq captured (list buffer-name command args display-action)))))
      (kubect--open-exec-buffer "*kubect exec*" '("--context" "ctx" "exec" "-it" "pod" "--" "/bin/sh") 'pop-up)
      (should (equal (car captured) "*kubect exec*"))
      (should (string-match-p "kubectl" (cadr captured)))
      (should (equal (caddr captured) '("--context" "ctx" "exec" "-it" "pod" "--" "/bin/sh")))
      (should (eq (cadddr captured) 'pop-up)))))

(ert-deftest kubect-open-exec-buffer-defaults-to-term-backend ()
  (let ((kubect-exec-backend 'term)
        opened)
    (cl-letf (((symbol-function 'kubect--open-term-exec-buffer)
               (lambda (buffer-name _command args display-action)
                 (setq opened (list buffer-name args display-action)))))
      (kubect--open-exec-buffer "*kubect exec*" '("exec" "-it" "pod") 'same-window)
      (should (equal opened '("*kubect exec*" ("exec" "-it" "pod") same-window))))))

(ert-deftest kubect-current-namespace-falls-back-to-default ()
  (let ((kubect--project-state (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'kubect--project-key)
               (lambda () "project-a"))
              ((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args)
                 (pcase args
                   (`("config" "view" "--minify" "-o" "jsonpath={..namespace}") "")
                   (`("config" "current-context") "ctx-a")
                   (_ (error "Unexpected args: %S" args))))))
      (should (equal (kubect-current-namespace) "default"))
      (should (equal (kubect-current-context) "ctx-a")))))

(ert-deftest kubect-project-state-is-scoped-by-project ()
  (let ((kubect--project-state (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args)
                 (pcase args
                   (`("config" "current-context") "shared-context")
                   (`("config" "view" "--minify" "-o" "jsonpath={..namespace}") "shared-namespace")
                   (_ (error "Unexpected args: %S" args))))))
      (cl-letf (((symbol-function 'kubect--project-key) (lambda () "project-a")))
        (kubect-set-context "ctx-a")
        (kubect-set-namespace "ns-a")
        (kubect-set-resource "deployments"))
      (cl-letf (((symbol-function 'kubect--project-key) (lambda () "project-b")))
        (kubect-set-context "ctx-b")
        (kubect-set-namespace "ns-b"))
      (cl-letf (((symbol-function 'kubect--project-key) (lambda () "project-a")))
        (should (equal (kubect-current-context) "ctx-a"))
        (should (equal (kubect-current-namespace) "ns-a"))
        (should (equal (kubect-current-resource) "deployments")))
      (cl-letf (((symbol-function 'kubect--project-key) (lambda () "project-b")))
        (should (equal (kubect-current-context) "ctx-b"))
        (should (equal (kubect-current-namespace) "ns-b"))
        (should (equal (kubect-current-resource) kubect-default-resource))))))

(ert-deftest kubect-project-defaults-come-from-dot-k8s-locals ()
  (let ((kubect--project-state (make-hash-table :test #'equal)))
    (let ((root (make-temp-file "kubect-project-" t)))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name ".k8s-locals.el" root)
              (insert "(:context \"ctx-local\" :namespace \"ns-local\" :resource \"deployments\" :display-buffer-action pop-up :wide t :file-root \"/workspace\"")
              (insert " :filter-presets ((\"hot\" :mode regexp :pattern \"CrashLoopBackOff\\\\|Error\"))")
              (insert " :sort-presets ((\"youngest\" :column \"AGE\" :parser age :descending nil)))\n"))
            (cl-letf (((symbol-function 'kubect--project-root) (lambda () root))
                      ((symbol-function 'kubect--project-key) (lambda () root))
                      ((symbol-function 'kubect--kubectl-output)
                       (lambda (&rest args)
                         (pcase args
                           (`("config" "current-context") "ctx-fallback")
                           (`("config" "view" "--minify" "-o" "jsonpath={..namespace}") "ns-fallback")
                           (_ (error "Unexpected args: %S" args))))))
              (should (equal (kubect-current-context) "ctx-local"))
              (should (equal (kubect-current-namespace) "ns-local"))
              (should (equal (kubect-current-resource) "deployments"))
              (should (kubect-current-wide-p))
              (should (equal (kubect--project-default :file-root) "/workspace"))
              (should (eq (kubect--current-display-buffer-action) 'pop-up))
              (should (equal (plist-get (kubect--filter-preset-spec "hot") :pattern)
                             "CrashLoopBackOff\\|Error"))
              (should (equal (plist-get (kubect--sort-preset-spec "youngest") :column)
                             "AGE"))))
        (delete-directory root t)))))

(ert-deftest kubect-pod-for-deployment-resolves-by-selector ()
  (cl-letf (((symbol-function 'kubect--kubectl-json)
             (lambda (&rest args)
               (pcase args
                 (`("--context" "ctx" "--namespace" "ns" "get" "deployments" "api" "-o" "json")
                  '((spec . ((selector . ((matchLabels . ((app . "api")
                                                         (tier . "backend")))))))))
                 (`("--context" "ctx" "--namespace" "ns" "get" "pods" "-l" "app=api,tier=backend" "-o" "json")
                  '((items . (((metadata . ((name . "api-123")
                                            (creationTimestamp . "2024-01-01T00:00:00Z")))
                               (status . ((phase . "Running")
                                          (containerStatuses . (((ready . t)
                                                                 (restartCount . 0)
                                                                 (state . ())))))))))))
                 (_ (error "Unexpected args: %S" args))))))
    (should (equal (kubect--pod-for-resource "deployments" "api" "ctx" "ns")
                   "api-123"))))

(ert-deftest kubect-jump-to-related-resource-prefers-resolved-pod ()
  (let (viewed)
    (cl-letf (((symbol-function 'kubect--current-line-resource-plist)
               (lambda ()
                 '(:kind "deployment" :name "api" :context "ctx" :namespace "ns")))
              ((symbol-function 'kubect--pod-for-resource)
               (lambda (&rest _args) "api-777"))
              ((symbol-function 'kubect--view-known-resource)
               (lambda (kind name context namespace &optional _arg)
                 (setq viewed (list kind name context namespace)))))
      (kubect-jump-to-related-resource)
      (should (equal viewed '("pod" "api-777" "ctx" "ns"))))))

(ert-deftest kubect-jump-to-related-resource-opens-jobs-for-cronjob ()
  (let (opened)
    (cl-letf (((symbol-function 'kubect--current-line-resource-plist)
               (lambda ()
                 '(:kind "cronjob" :name "nightly" :context "ctx" :namespace "ns")))
              ((symbol-function 'kubect-open)
               (lambda (context namespace resource filter display-action)
                 (setq opened (list context namespace resource filter display-action)))))
      (kubect-jump-to-related-resource)
      (should (equal opened '("ctx" "ns" "jobs" "nightly" nil))))))

(ert-deftest kubect-resource-urls-shows-service-report-and-copies-urls ()
  (let (displayed)
    (cl-letf (((symbol-function 'kubect--current-line-resource-plist)
               (lambda ()
                 '(:kind "service" :name "api" :context "ctx" :namespace "ns")))
              ((symbol-function 'kubect--kubectl-json)
               (lambda (&rest _args)
                 '((spec . ((ports . (((port . 8080))))))
                   (status . ((loadBalancer . ((ingress . (((hostname . "api.example.com")))))))))))
              ((symbol-function 'kubect--display-buffer)
               (lambda (buffer)
                 (setq displayed buffer))))
      (kubect-resource-urls)
      (with-current-buffer displayed
        (should (eq major-mode 'kubect-report-mode))
        (should (string-match-p "http://api.example.com:8080" (buffer-string)))
        (should (string-match-p "http://api.ns.svc.cluster.local:8080" (buffer-string))))
      (should (string-match-p "api.example.com:8080" (current-kill 0))))))

(ert-deftest kubect-resource-open-url-opens_selected_url ()
  (let (opened)
    (cl-letf (((symbol-function 'kubect--current-line-resource-plist)
               (lambda ()
                 '(:kind "service" :name "api" :context "ctx" :namespace "ns")))
              ((symbol-function 'kubect--resource-url-lines)
               (lambda (&rest _args)
                 '("http://a.example" "http://b.example")))
              ((symbol-function 'kubect--completing-read)
               (lambda (_prompt candidates &optional _initial)
                 (should (equal candidates '("http://a.example" "http://b.example")))
                 "http://b.example"))
              ((symbol-function 'browse-url)
               (lambda (url &rest _args)
                 (setq opened url))))
      (kubect-resource-open-url)
      (should (equal opened "http://b.example")))))

(ert-deftest kubect-resource-open-url-prefers_url_at_point_without_prompt ()
  (let (opened prompted)
    (with-temp-buffer
      (insert "http://a.example\nhttp://b.example\n")
      (goto-char (point-min))
      (forward-line 1)
      (cl-letf (((symbol-function 'kubect--current-line-resource-plist)
                 (lambda ()
                   '(:kind "service" :name "api" :context "ctx" :namespace "ns")))
                ((symbol-function 'kubect--resource-url-lines)
                 (lambda (&rest _args)
                   '("http://a.example" "http://b.example")))
                ((symbol-function 'kubect--completing-read)
                 (lambda (&rest _args)
                   (setq prompted t)
                   "http://a.example"))
                ((symbol-function 'browse-url)
                 (lambda (url &rest _args)
                   (setq opened url))))
        (kubect-resource-open-url)
        (should (equal opened "http://b.example"))
        (should-not prompted)))))

(ert-deftest kubect-report-url-actions-use_buffer_state ()
  (let (opened)
    (with-temp-buffer
      (insert "http://a.example\nhttp://b.example\n")
      (goto-char (point-min))
      (forward-line 1)
      (kubect-report-mode)
      (setq-local kubect-report-state '(:urls ("http://a.example" "http://b.example")))
      (cl-letf (((symbol-function 'kubect--completing-read)
                 (lambda (_prompt _candidates &optional _initial)
                   "http://b.example"))
                ((symbol-function 'browse-url)
                 (lambda (url &rest _args)
                   (push url opened))))
        (kubect-report-open-url)
        (should (equal opened '("http://b.example")))
        (kubect-report-copy-url)
        (should (equal (current-kill 0) "http://b.example"))
        (kubect-report-copy-all-urls)
        (should (equal (current-kill 0) "http://a.example\nhttp://b.example"))
        (kubect-report-open-all-urls)
        (should (equal (nreverse opened)
                       '("http://b.example" "http://a.example" "http://b.example")))))))

(ert-deftest kubect-top-pods-shows_report ()
  (let (displayed)
    (cl-letf (((symbol-function 'kubect-current-context) (lambda () "ctx"))
              ((symbol-function 'kubect-current-namespace) (lambda () "ns"))
              ((symbol-function 'kubect--kubectl-output)
               (lambda (&rest args)
                 (should (equal args
                                '("--context" "ctx" "--namespace" "ns" "top" "pods")))
                 "NAME CPU MEMORY"))
              ((symbol-function 'kubect--display-buffer)
               (lambda (buffer)
                 (setq displayed buffer))))
      (kubect-top-pods)
      (with-current-buffer displayed
        (should (string-match-p "== top pods ==" (buffer-string)))
        (should (string-match-p "NAME\tCPU\tMEMORY" (buffer-string)))
        (should (string-match-p "Top pods: ctx/ns" header-line-format))))))

(ert-deftest kubect-top-report-can_sort_by_memory ()
  (let* ((state '(:type top
                  :title "top pods"
                  :header "hdr"
                  :columns ("NAME" "CPU(cores)" "MEMORY(bytes)")
                  :rows ((("NAME" . "a") ("CPU(cores)" . "10m") ("MEMORY(bytes)" . "20Mi"))
                         (("NAME" . "b") ("CPU(cores)" . "5m") ("MEMORY(bytes)" . "30Mi")))
                  :sort "MEMORY(bytes)"))
         (rendered (kubect--render-report-state state)))
    (should (string-match-p "b\t5m\t30Mi\na\t10m\t20Mi" (plist-get rendered :body)))))

(ert-deftest kubect-resource-urls-shows-ingress-rules ()
  (let (displayed)
    (cl-letf (((symbol-function 'kubect--current-line-resource-plist)
               (lambda ()
                 '(:kind "ingress" :name "api" :context "ctx" :namespace "ns")))
              ((symbol-function 'kubect--kubectl-json)
               (lambda (&rest _args)
                 '((spec . ((tls . (((hosts . ("api.example.com")))))
                            (rules . (((host . "api.example.com")
                                       (http . ((paths . (((path . "/health"))
                                                          ((path . "/ready"))))))))))))))
              ((symbol-function 'kubect--display-buffer)
               (lambda (buffer)
                 (setq displayed buffer))))
      (kubect-resource-urls)
      (with-current-buffer displayed
        (should (string-match-p "https://api.example.com/health" (buffer-string)))
        (should (string-match-p "https://api.example.com/ready" (buffer-string)))))))

(ert-deftest kubect-prioritize-recent-moves-known-items-first ()
  (should (equal (kubect--prioritize-recent
                  '("b" "a" "c" "d")
                  '("c" "a" "z"))
                 '("c" "a" "b" "d"))))

;;; test-core.el ends here
