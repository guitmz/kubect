;;; kubect-process.el --- Kubect process -*- lexical-binding: t; -*-

(require 'kubect-core)

(defvar kubect--read-cache (make-hash-table :test #'equal))

(defun kubect-clear-read-cache ()
  "Clear Kubect's short-lived interactive read cache."
  (interactive)
  (clrhash kubect--read-cache))

(defun kubect--cacheable-read-p (args)
  "Return non-nil when ARGS describe a scoped, low-risk read.
Only interactive `get' and `top' requests with an explicit context are
cached.  This avoids reusing data across an implicit context change or for
potentially sensitive `describe' output."
  (let ((remaining args) verb)
    (while (and remaining (not verb))
      (let ((arg (pop remaining)))
        (cond
         ((member arg '("--context" "--namespace" "-n"))
          (pop remaining))
         ((string-prefix-p "-" arg))
         (t (setq verb arg)))))
    (and (not noninteractive)
         (member "--context" args)
         (member verb '("get" "top"))
         (not (member "--watch" args)))))

(defun kubect--connection-error-p (text)
  "Return non-nil when TEXT looks like connectivity or credential failure."
  (string-match-p "timed out\|Unable to connect\|connection refused\|Unauthorized\|credential\|authentication" text))

(defun kubect--connection-hint (text)
  "Return actionable connection guidance for failed command TEXT."
  (when (kubect--connection-error-p text)
    (concat "\nKubect remains responsive. Press C-g to cancel future reads."
            (if kubect-credential-refresh-command
                (format "\nCredential refresh: %s" kubect-credential-refresh-command)
              "\nCheck cluster reachability or configure kubect-credential-refresh-command."))))

(defun kubect--ensure-kubectl ()
  "Return the kubectl executable path or error.
For a Tramp `default-directory', return `kubect-kubectl-command' unchanged so
the remote process resolves it using the remote host's PATH."
  (if (file-remote-p default-directory)
      kubect-kubectl-command
    (or (executable-find kubect-kubectl-command)
        (user-error "Could not find `%s` in PATH" kubect-kubectl-command))))

(defun kubect--kubectl-base-args (&optional context namespace)
  "Return common kubectl arguments for CONTEXT and NAMESPACE."
  (let ((context (or context (kubect-current-context)))
        (namespace (or namespace (kubect-current-namespace))))
    (append
     (list "--context" context)
     (cond
      ((equal namespace kubect-all-namespaces-token)
       (list "--all-namespaces=true"))
      ((not (string-empty-p namespace))
       (list "--namespace" namespace))))))

(defun kubect--kubectl-output (&rest args)
  "Run kubectl with ARGS and return trimmed stdout.
Unlike `process-file', this keeps Emacs responsive while kubectl waits for a
cluster.  `C-g' aborts it immediately and `kubect-command-timeout' bounds it."
  (let* ((program (kubect--ensure-kubectl))
         (cache-key (cons program args))
         (cached (and (kubect--cacheable-read-p args) (gethash cache-key kubect--read-cache)))
         (stdout (generate-new-buffer " *kubect stdout*"))
        (stderr (generate-new-buffer " *kubect stderr*"))
        (process nil)
        (stderr-process nil)
        (deadline (+ (float-time) kubect-command-timeout))
        (timed-out nil))
    (if (and cached (< (- (float-time) (car cached)) kubect-read-cache-ttl))
        (progn (kill-buffer stdout) (kill-buffer stderr) (cdr cached))
      (unwind-protect
        (condition-case err
            (progn
              (setq process
                    (make-process :name "kubect-command"
                                  :buffer stdout :stderr stderr :noquery t
                                  :connection-type 'pipe
                                  :sentinel #'ignore
                                  :command (cons program args)))
              (setq stderr-process (get-buffer-process stderr))
              (when stderr-process
                (set-process-sentinel stderr-process #'ignore))
              (while (process-live-p process)
                (when (>= (float-time) deadline)
                  (setq timed-out t)
                  (delete-process process))
                ;; This yields to the command loop, so C-g remains immediate.
                (accept-process-output process 0.05))
              ;; A short-lived process can exit between `make-process' and the
              ;; first `process-live-p' check.  Give Emacs one final chance to
              ;; dispatch its queued stdout and stderr before reading buffers.
              (accept-process-output process 0.05)
              ;; Emacs 29 can report the main process as exited before its
              ;; separate stderr pipe has closed.  Drain that pipe too so a
              ;; failed kubectl command always reports both streams.
              (while (and stderr-process (process-live-p stderr-process))
                (accept-process-output stderr-process 0.05))
              (when stderr-process
                (accept-process-output stderr-process 0.05))
              (let ((stdout-text (with-current-buffer stdout (string-trim (buffer-string))))
                    (stderr-text (with-current-buffer stderr (string-trim (buffer-string)))))
                (cond
                 (timed-out
                  (error "kubectl timed out after %.1fs: %s%s"
                         kubect-command-timeout (mapconcat #'identity args " ")
                         (kubect--connection-hint "timed out")))
                 ((not (zerop (process-exit-status process)))
                  (error "kubectl failed (exit %s): %s%s%s%s"
                         (process-exit-status process)
                         (mapconcat #'identity args " ")
                         (if (string-empty-p stderr-text) "" (format "\nstderr:\n%s" stderr-text))
                         (if (string-empty-p stdout-text) "" (format "\nstdout:\n%s" stdout-text))
                         (kubect--connection-hint (concat stderr-text " " stdout-text))))
                 (t (when (kubect--cacheable-read-p args)
                      (puthash cache-key (cons (float-time) stdout-text) kubect--read-cache))
                    stdout-text))))
          (quit
           (when (and process (process-live-p process)) (delete-process process))
           (signal 'quit nil))
          (error (signal (car err) (cdr err))))
      (when (and process (process-live-p process)) (delete-process process))
      (when (and stderr-process (process-live-p stderr-process))
        (delete-process stderr-process))
      (kill-buffer stdout)
      (kill-buffer stderr)))))

(defun kubect--shell-command (args)
  "Return a shell-safe kubectl command string from ARGS."
  (mapconcat #'shell-quote-argument
             (cons (kubect--ensure-kubectl) args)
             " "))

(defun kubect--kubectl-json (&rest args)
  "Run kubectl with ARGS and parse JSON output."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol))
    (json-read-from-string
     (apply #'kubect--kubectl-output args))))

(provide 'kubect-process)
;;; kubect-process.el ends here
