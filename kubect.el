;;; kubect.el --- Kubernetes workflows inside Emacs -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools
;; Author: Guilherme Thomazi Bonicontro <thomazi@linux.com>
;; Maintainer: Guilherme Thomazi Bonicontro <thomazi@linux.com>

;;; Commentary:
;;
;; Kubect is a text focused interface for inspecting and operating Kubernetes
;; clusters from Emacs.  It uses the user's `kubectl' configuration and keeps
;; write operations behind explicit confirmation prompts.

(require 'kubect-core)
(require 'kubect-process)
(require 'kubect-browser)
(require 'kubect-reports)
(require 'kubect-logs)
(require 'kubect-incident)
(require 'kubect-async)

(add-hook 'kill-emacs-hook #'kubect-save-sessions)
(if after-init-time
    (kubect--maybe-restore-sessions)
  (add-hook 'emacs-startup-hook #'kubect--maybe-restore-sessions))

(provide 'kubect)

;;; kubect.el ends here
