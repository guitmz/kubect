;;; test-support.el --- Shared test setup for kubect -*- lexical-binding: t; -*-

(let ((test-dir (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name ".." test-dir))
  (add-to-list 'load-path (expand-file-name "../.." test-dir)))

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'kubect)

(provide 'test-support)

;;; test-support.el ends here
