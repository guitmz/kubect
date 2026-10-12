# Kubect

Kubect is a text focused Emacs interface for inspecting and operating Kubernetes
clusters through the `kubectl` CLI you already use.  It is designed for moving
between contexts and namespaces without hiding the command line: browser,
report, log, stream, and compilation buffers show the underlying invocation.

Kubect does not bundle credentials, contact a service, or depend on a specific
cluster, namespace, project directory, or external Emacs package.

This project was developed with AI assistance for tests, and documentation, with human review required for every change.

## Comparison

- [Kubel](https://github.com/abrochard/kubel) provides a focused resource browser with per buffer context and namespace selection, while Kubect adds asynchronous reports, incident workflows, and mandatory confirmations for state changes and connection opening.
- [kubernetes-el](https://github.com/kubernetes-el/kubernetes-el) provides a broad Kubernetes dashboard, while Kubect favors lightweight text buffers, literal `kubectl` commands, and independent per session workflows.
- [Kubed](https://github.com/emacsmirror/kubed) is a rich integrated interface with extensive resource support and remote access, while Kubect stays intentionally compact and uses its existing `kubectl` command flow.

## Requirements

- Emacs 28.2 or later.
- A `kubectl` executable on `exec-path` (customize `kubect-kubectl-command` if
  needed).
- A working kubeconfig only when you run commands that query a cluster.

Optional integrations are detected at runtime and are never required:

- `transient` adds command dispatch menus. Ordinary key bindings remain usable
  without it.
- `consult` improves completion. Standard `completing-read` is the fallback.
- `yaml-mode` is used when editing manifests. Otherwise Kubect uses `text-mode`.
- `vterm`, `eat`, and `ghostel` can host exec sessions when selected. `term` is
  built in and remains the default.
- `metrics-server` enables `kubectl top` data. Unavailable metrics produce a
  readable error rather than a dependency failure.
- Prometheus is disabled unless `kubect-prometheus-url` or
  `kubect-prometheus-query-function` is configured.

Kubect also works from a Tramp buffer when `kubectl` is available on the remote
host.  Set `kubect-kubectl-command` in a connection local profile when remote
hosts use a different executable path.

## Installation

Clone or place this directory anywhere on your machine, then add it to
`load-path` and load the entry point:

```elisp
(add-to-list 'load-path "/path/to/kubect")
(require 'kubect)
```

With `use-package`:

```elisp
(use-package kubect
  :load-path "/path/to/kubect"
  :bind ("C-c k" . kubect-prefix-map))
```

With Elpaca:

```elisp
(elpaca (kubect :host github :repo "guitmz/kubect")
  (require 'kubect))
```

With Emacs 29 or later and the built in `package-vc` command:

```elisp
(require 'package)
(package-vc-install '(kubect :url "https://github.com/guitmz/kubect.git"))
(require 'kubect)
```

With straight.el:

```elisp
(straight-use-package
 '(kubect :type git :host github :repo "guitmz/kubect"))
(require 'kubect)
```

Kubect does not require a particular package manager or archive.  After the
first installation, bind `kubect-prefix-map` as shown above.

## Quick start

Bind `kubect-prefix-map`, then use `C-c k b` to open a resource browser.  In a
session buffer, `g` refreshes, `RET` views a manifest, `D` describes, `l` opens
logs, `w` toggles a timed refresh, `c` and `n` change scope, `C-c f` filters a
named table column, and `?` opens the
available command menu when Transient is installed.  `C-c k .` opens the home
report. `C-c k B` switches live sessions.

The browser retains its own context and namespace, so multiple sessions can
target different clusters safely.  Use `C-c k N` for a view across namespaces.
Read only reports and browser refreshes run asynchronously by default.  `C-c
C-k` cancels a running refresh. `C-c C-e` opens the full failure message.
Manifest views are read only, bookmarkable standard Emacs buffers. Press `g` or
use `revert-buffer` to fetch the same resource again in its original scope.

## Configuration

Customize Kubect with `M-x customize-group RET kubect RET`.  Common settings:

```elisp
(setq kubect-default-resource "pods"
      kubect-watch-interval 5
      kubect-exec-backend 'term)
```

To use a different `kubectl` executable on a particular Tramp host, define a
connection local profile in your Emacs configuration:

```elisp
(connection-local-set-profile-variables
 'kubect-remote
 '((kubect-kubectl-command . "/opt/bin/kubectl")))
(connection-local-set-profiles
 '(:application tramp :machine "cluster-host")
 'kubect-remote)
```

Project defaults may live in a local `.k8s-locals.el` containing one
plist, for example:

```elisp
(:context "example-context" :namespace "example-namespace" :resource "pods")
```

Do not commit that file: it is ignored because it can reveal environment
details.  `kubect-persist-sessions` is disabled by default. Enable it only if
you want context and namespace information written under your Emacs directory.

## Safety model

Kubect invokes `kubectl` with literal argument lists for normal processes.
Its displayed shell commands are quoted for readability and compilation
buffers. Actions that change cluster state or open connections ask for an
explicit yes/no confirmation by default: apply, edited manifest apply, remote
file create/save/rename/delete, rollout restart, exec, and port-forward.
Contexts matching `kubect-prod-context-regexp` are labelled as production
contexts.

Set `kubect-confirm-mutating-commands` to nil only if you intentionally accept
weaker safeguards. Production context confirmations remain in force.
Review a buffer with `kubect-diff-buffer` before applying it.  Kubect never
selects a context, namespace, or credential source on your behalf.

## Troubleshooting

- **`kubectl` not found:** set `kubect-kubectl-command` to an executable name
  or absolute executable path available to Emacs.
- **Timeout or authentication failure:** increase `kubect-command-timeout` if
  appropriate, repair kubeconfig/cluster access, or set
  `kubect-credential-refresh-command` to document your own refresh command.
- **`top` fails:** ensure the target cluster provides metrics-server. Or use
  normal resource and log views instead.
- **A report is stale:** press `C-c C-e` for the retained error and `C-c C-k`
  to cancel a running request before refreshing.

## Tests

The ERT suite is hermetic and requires no cluster, network, credentials, or
external packages:

```sh
emacs -Q --batch -L . -L tests -l tests/run-tests.el
```

CI covers Emacs 28.2, 29.4, 30.2, and 31.1 on Linux.

See [CONTRIBUTING.md](CONTRIBUTING.md) for style, safety, and test guidance.

## License

Kubect is distributed under the [MIT License](LICENSE).
