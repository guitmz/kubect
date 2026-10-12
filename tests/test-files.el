;;; test-files.el --- kubect tests -*- lexical-binding: t; -*-

(require 'test-support)

(ert-deftest kubect-view-mode-is-read-only ()
  (with-temp-buffer
    (kubect-view-mode)
    (should buffer-read-only)))

(ert-deftest kubect-view-mode-binds-q-to-quit-window ()
  (with-temp-buffer
    (kubect-view-mode)
    (should (eq (key-binding (kbd "q")) #'quit-window))))

(ert-deftest kubect-view-mode-activates-base-mode-with-delayed-hooks ()
  (with-temp-buffer
    (let (seen)
      (cl-letf (((symbol-function 'yaml-mode)
                 (lambda ()
                   (setq seen delay-mode-hooks)
                   (setq major-mode 'yaml-mode))))
        (kubect-view-mode)
        (should seen)))))

(ert-deftest kubect-view-resource-focuses-its-buffer ()
  (let (displayed)
    (cl-letf (((symbol-function 'kubect--resource-plist-from-session)
               (lambda ()
                 '(:kind "pods" :name "api-123" :context "ctx" :namespace "ns")))
              ((symbol-function 'kubect--kubectl-output)
               (lambda (&rest _args)
                 "apiVersion: v1\nkind: Pod\nmetadata:\n  name: api-123\n"))
              ((symbol-function 'kubect--display-buffer)
               (lambda (buffer)
                 (setq displayed buffer))))
      (kubect-view-resource)
      (should (buffer-live-p displayed)))))

(ert-deftest kubect-toggle-watch-starts-and-stops-a-buffer-local-timer ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"))
    (let ((scheduled nil)
          (cancelled nil)
          (fake-timer (list :fake-timer)))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (secs repeat fn buffer)
                   (setq scheduled (list secs repeat fn buffer))
                   fake-timer))
                ((symbol-function 'timerp)
                 (lambda (obj) (eq obj fake-timer)))
                (timer-list (list fake-timer))
                ((symbol-function 'cancel-timer)
                 (lambda (timer)
                   (setq cancelled timer))))
        (kubect-toggle-watch)
        (should (equal scheduled
                       (list kubect-watch-interval
                             kubect-watch-interval
                             #'kubect--watch-refresh
                             (current-buffer))))
        (should (eq kubect--watch-timer fake-timer))
        (should (kubect-watching-p))
        (kubect-toggle-watch)
        (should (eq cancelled fake-timer))
        (should-not kubect--watch-timer)))))

(ert-deftest kubect-default-occur-regexp-prefers-resource-at-point ()
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
    (should (equal (kubect--default-occur-regexp) "api-7f6d9"))))

(ert-deftest kubect-open-registers-a-session-buffer ()
  (let ((kubect--sessions nil))
    (cl-letf (((symbol-function 'kubect-refresh) (lambda () nil))
              ((symbol-function 'kubect--project-root) (lambda () "/tmp/project")))
      (let ((session (kubect-open "ctx" "ns" "pods")))
        (unwind-protect
            (progn
              (should (kubect-session-p session))
              (should (buffer-live-p (kubect-session-buffer session)))
              (should (eq (buffer-local-value 'kubect-session
                                              (kubect-session-buffer session))
                          session))
              (should (equal (kubect-session-project-root session) "/tmp/project"))
              (should (equal (kubect-session-sort-label session) "status"))
              (should (memq session kubect--sessions)))
          (when (buffer-live-p (kubect-session-buffer session))
            (kill-buffer (kubect-session-buffer session))))))))

(ert-deftest kubect-save-and-restore-sessions-round-trip ()
  (let ((kubect--sessions nil)
        (kubect-persist-sessions t)
        (kubect--sessions-restored nil))
    (let ((persist-file (make-temp-file "kubect-sessions-"))
          (restored nil))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'kubect--session-live-p) (lambda (_session) t))
                      (noninteractive nil)
                      (kubect-session-persist-file persist-file))
              (let ((session (kubect-session-create
                              :name "ctx/ns/pods"
                              :context "ctx"
                              :namespace "ns"
                              :resource "pods"
                              :filter "api"
                              :filter-mode 'regexp
                              :filter-label "crashing"
                              :column-filter-column "STATUS"
                              :column-filter-pattern "Running"
                              :sort-label "restarts"
                              :sort-column "RESTARTS"
                              :sort-parser 'integer
                              :sort-descending t
                              :project-root "/tmp/project"
                              :wide t
                              :recent-pods '("api-123")
                              :recent-containers '("app")
                              :command-history '("logs api-123/app")
                              :marked-resources '("pod/api-123"))))
                (setf (kubect-session-buffer session) (current-buffer))
                (setq kubect--sessions (list session))
                (kubect-save-sessions)))
            (cl-letf (((symbol-function 'kubect-open)
                       (lambda (context namespace resource filter display-action &rest _scope)
                         (let ((session (kubect-session-create
                                         :name (format "%s/%s/%s" context namespace resource)
                                         :context context
                                         :namespace namespace
                                         :resource resource
                                         :filter filter
                                         :buffer (current-buffer))))
                           (setq restored (list session display-action))
                           session)))
                      ((symbol-function 'kubect-refresh) (lambda () nil))
                      (noninteractive nil)
                      (kubect-session-persist-file persist-file))
              (kubect-restore-sessions)
              (pcase-let ((`(,session ,display-action) restored))
                (should (equal display-action 'silent))
                (should (equal (kubect-session-context session) "ctx"))
                (should (equal (kubect-session-namespace session) "ns"))
                (should (equal (kubect-session-resource session) "pods"))
                (should (equal (kubect-session-filter session) "api"))
                (should (eq (kubect-session-filter-mode session) 'regexp))
                (should (equal (kubect-session-filter-label session) "crashing"))
                (should (equal (kubect-session-column-filter-column session) "STATUS"))
                (should (equal (kubect-session-column-filter-pattern session) "Running"))
                (should (equal (kubect-session-sort-label session) "restarts"))
                (should (equal (kubect-session-sort-column session) "RESTARTS"))
                (should (eq (kubect-session-sort-parser session) 'integer))
                (should (kubect-session-sort-descending session))
                (should (equal (kubect-session-project-root session) "/tmp/project"))
                (should (kubect-session-wide session))
                (should (equal (kubect-session-recent-pods session) '("api-123")))
                (should (equal (kubect-session-recent-containers session) '("app")))
                (should (equal (kubect-session-command-history session) '("logs api-123/app")))
                (should (equal (kubect-session-marked-resources session) '("pod/api-123"))))))
        (ignore-errors (delete-file persist-file))))))

(ert-deftest kubect-save-sessions-is-noop-when-persistence-disabled ()
  (let ((kubect-persist-sessions nil))
    (let ((persist-file (make-temp-file "kubect-sessions-")))
      (unwind-protect
          (progn
            (delete-file persist-file)
            (cl-letf ((kubect-session-persist-file persist-file)
                      (noninteractive nil))
              (kubect-save-sessions)
              (should-not (file-exists-p persist-file))))
        (ignore-errors (delete-file persist-file))))))

(ert-deftest kubect-browse-files-uses-project-file-root ()
  (cl-letf (((symbol-function 'kubect--read-pod) (lambda (&rest _) "api-123"))
            ((symbol-function 'kubect--read-container) (lambda (&rest _) nil))
            ((symbol-function 'kubect--project-default) (lambda (prop)
                                                          (when (eq prop :file-root) "/workspace")))
            ((symbol-function 'kubect-file-browser-refresh) (lambda () nil))
            ((symbol-function 'kubect--display-buffer) (lambda (_buffer) nil)))
    (let ((kubect--project-state (make-hash-table :test #'equal))
          (buffer nil))
      (cl-letf (((symbol-function 'kubect--project-root) (lambda () nil))
                ((symbol-function 'kubect--kubectl-output)
                 (lambda (&rest args)
                   (pcase args
                     (`("config" "current-context") "ctx")
                     (`("config" "view" "--minify" "-o" "jsonpath={..namespace}") "ns")
                     (_ (error "Unexpected args: %S" args)))))
                ((symbol-function 'kubect--display-buffer)
                 (lambda (buf)
                   (setq buffer buf)
                   nil)))
        (kubect-browse-files)
        (unwind-protect
            (with-current-buffer buffer
              (should (equal (plist-get kubect-file-browser-state :path) "/workspace"))
              (should (equal (plist-get kubect-file-browser-state :pod) "api-123")))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest kubect-file-browser-create-runs-touch-or-mkdir ()
  (let (commands)
    (with-temp-buffer
      (kubect-file-browser-mode)
      (setq-local kubect-file-browser-state
                  '(:context "ctx" :namespace "ns" :pod "api" :container nil :path "/work"))
      (cl-letf (((symbol-function 'kubect--run-remote-shell-command)
                 (lambda (_context _namespace _pod _container command)
                   (push command commands)))
                ((symbol-function 'kubect--confirm-write) (lambda (&rest _) t))
                ((symbol-function 'kubect-file-browser-refresh) (lambda () nil)))
        (kubect-file-browser-create "notes.txt")
        (kubect-file-browser-create "tmp/")
        (should (equal commands
                       '("mkdir -p /work/tmp"
                         "touch /work/notes.txt")))))))

(ert-deftest kubect-file-browser-delete-and-rename-run-remote-commands ()
  (let (commands)
    (with-temp-buffer
      (kubect-file-browser-mode)
      (setq-local kubect-file-browser-state
                  '(:context "ctx" :namespace "ns" :pod "api" :container nil :path "/work"))
      (let ((inhibit-read-only t))
        (insert "app.log\n")
        (goto-char (point-min)))
      (cl-letf (((symbol-function 'kubect--run-remote-shell-command)
                 (lambda (_context _namespace _pod _container command)
                   (push command commands)))
                ((symbol-function 'kubect-file-browser-refresh) (lambda () nil))
                ((symbol-function 'kubect--confirm-write) (lambda (&rest _) t)))
        (kubect-file-browser-rename "app.old.log")
        (goto-char (point-min))
        (kubect-file-browser-delete)
        (should (equal commands
                       '("rm -rf /work/app.log"
                         "mv /work/app.log /work/app.old.log")))))))

(ert-deftest kubect-session-history-renders-commands-pods-and-containers ()
  (with-temp-buffer
    (kubect-session-mode)
    (setq-local kubect-session
                (kubect-session-create
                 :name "ctx/ns/pods"
                 :context "ctx"
                 :namespace "ns"
                 :resource "pods"
                 :buffer (current-buffer)
                 :command-history '("logs api-123/app" "exec api-123/app")
                 :recent-pods '("api-123")
                 :recent-containers '("app")))
    (let ((kubect-display-buffer-action 'same-window))
      (cl-letf (((symbol-function 'switch-to-buffer) (lambda (buffer &rest _) buffer)))
        (kubect-session-history)
        (with-current-buffer "*kubect history ctx/ns/pods*"
          (should (string-match-p "Recent commands:" (buffer-string)))
          (should (string-match-p "- logs api-123/app" (buffer-string)))
          (should (string-match-p "Recent pods:" (buffer-string)))
          (should (string-match-p "- api-123" (buffer-string)))
          (should (string-match-p "Recent containers:" (buffer-string)))
          (should (string-match-p "- app" (buffer-string))))))))

(ert-deftest kubect-file-browser-history-uses-originating-session ()
  (let ((session (kubect-session-create
                  :name "ctx/ns/pods"
                  :context "ctx"
                  :namespace "ns"
                  :resource "pods")))
    (with-temp-buffer
      (kubect-file-browser-mode)
      (setq-local kubect-file-browser-state
                  (list :context "ctx" :namespace "ns" :pod "api-123"
                        :container "app" :path "/workspace" :session session))
      (kubect--record-session-command "file-open" "/workspace/app.log")
      (should (equal (kubect-session-command-history session)
                     '("file-open /workspace/app.log"))))))

(provide 'test-kubect)

;;; test-files.el ends here
