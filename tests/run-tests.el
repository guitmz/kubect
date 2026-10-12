;;; run-tests.el --- Batch test runner for kubect -*- lexical-binding: t; -*-

(require 'ert)
(let ((test-dir (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path test-dir)
  (load-file (expand-file-name "test-kubect.el" test-dir)))

(ert-run-tests-batch-and-exit)

;;; run-tests.el ends here
