# Contributing to Kubect

Thanks for improving Kubect.  Keep changes small, text focused, and compatible
with Emacs 27.1 and later.  Avoid adding required external packages.

## Development

Run the complete hermetic test suite from the repository root:

```sh
emacs -Q --batch -L . -L tests -l tests/run-tests.el
```

Tests must not contact a cluster, read a user's kubeconfig, require network
access, or depend on a local package installation.  Mock `kubect--kubectl-output`,
`kubect--kubectl-json`, processes, and prompts at the boundary instead.

Use lexical binding in every Lisp file, write public command and customization
docstrings as user documentation, and retain the `kubect-` prefix.  Internal
helpers use `kubect--`.  Prefer literal argument lists passed to `make-process`
or Kubect's process helpers. Do not interpolate user or Kubernetes data into a
shell command unless it is intentionally quoted for shell use in a terminal display.

## Safety and review

Any action that can alter a cluster, a container filesystem, or an interactive
connection needs an explicit confirmation through `kubect--confirm-write` and
an ERT test for acceptance and refusal.  New background work must clean up its
process, temporary buffers, and timers when cancelled, replaced, or killed.

Before proposing a change, run the test command above and check that edited
text files have no trailing whitespace and end in a newline.
