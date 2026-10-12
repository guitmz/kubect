;;; test-support.el --- Shared test setup for kubect -*- lexical-binding: t; -*-

(let ((test-dir (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name ".." test-dir))
  (add-to-list 'load-path (expand-file-name "../.." test-dir)))

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'kubect)

(defvar kubect-test--program-directory
  (make-temp-file "kubect-test-programs-" t)
  "Directory containing test only command placeholders.")

(defun kubect-test--write-program (name contents)
  "Create executable test program NAME containing CONTENTS."
  (let ((file (expand-file-name name kubect-test--program-directory)))
    (with-temp-file file
      (insert contents))
    (set-file-modes file #o700)))

;; Async tests replace `make-process' after Kubect resolves its executable.
;; These placeholders keep that lookup hermetic and fail loudly if an
;; unmocked kubectl or git invocation reaches the operating system.
(kubect-test--write-program
 "kubectl" "#!/bin/sh\necho 'Unexpected kubectl call from test' >&2\nexit 127\n")
(kubect-test--write-program
 "git" "#!/bin/sh\necho 'Unexpected git call from test' >&2\nexit 127\n")
(setq exec-path (cons kubect-test--program-directory exec-path))
(setenv "PATH" (concat kubect-test--program-directory path-separator
                       (or (getenv "PATH") "")))
(add-hook 'kill-emacs-hook
          (lambda ()
            (ignore-errors (delete-directory kubect-test--program-directory t))))

(provide 'test-support)

;;; test-support.el ends here
