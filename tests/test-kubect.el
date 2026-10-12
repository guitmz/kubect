;;; test-kubect.el --- Compatibility loader for kubect tests -*- lexical-binding: t; -*-

(require 'test-support)

(dolist (file '("test-core.el"
                "test-incident.el"
                "test-session.el"
                "test-files.el"
                "test-reliability.el"))
  (load-file (expand-file-name file
                               (file-name-directory (or load-file-name buffer-file-name)))))

;;; test-kubect.el ends here
