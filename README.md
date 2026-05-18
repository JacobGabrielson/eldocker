# eldocker

A pure Emacs Lisp Docker client and magit-style Docker browser.

![eldocker exec demo](docs/exec-demo.gif)

*Pressing `e` on a container row opens a real shell inside it — no
`docker exec -it` involved, just an HTTP Upgrade hijack of
`POST /exec/{id}/start` running through Emacs' `term-mode`.*

## Philosophy

**Pure Elisp talking directly to the Docker engine API.**

eldocker speaks HTTP/1.1 to the Docker daemon over its Unix socket (or
TLS-wrapped TCP for remote daemons) — no `docker` CLI process is forked
for list, inspect, lifecycle, log streaming, events, exec, or pull.
Everything else — JSON parsing, UI rendering, config handling — is
pure Emacs Lisp on top of built-in `json-parse-*` and GnuTLS.

The CLI is kept only as a deliberately-narrow fallback for the handful
of features that have no engine endpoint: `docker build` /
`docker buildx` (BuildKit gRPC), `docker compose`, CLI plugins,
`docker login` config writes, `DOCKER_HOST=ssh://…` transport, and
`docker-credential-*` helpers.  Each is a clearly-named helper in one
small place.  See [docs/direct-daemon-rewrite.md](docs/direct-daemon-rewrite.md).

## What you can do

`M-x docker` opens a magit-style buffer listing your containers.
Views auto-refresh as the daemon's `/events` stream tells us what
changed.

| Key | Action | Scope |
|-----|--------|-------|
| `?` | Transient dispatch menu | All views |
| `g` | Refresh | All views |
| `q` | Quit window | All views |
| `i` | Inspect resource at point | All views |
| `d` | Delete / disconnect (context-aware) | All views |
| `RET` | Toggle section | All views |
| `a` | Toggle running/all containers | Containers |
| `s` / `S` / `r` / `K` | Start / Stop / Restart / Kill | Containers |
| `l` | Tail logs (streaming, stdout/stderr demuxed) | Containers |
| `e` | Exec a shell into the container | Containers |
| `j` / `J` | Join / leave a network | Containers |
| `p` | Pull image (via `?` transient) | Images |

Three views ship today: `*docker:containers*`, `*docker:images*`,
`*docker:networks*`.  Each subscribes to `/events` and refreshes
automatically (debounced) on relevant changes.

## Status: merging with emak8s

This repo is in the middle of folding [emak8s](../emak8s) in so a
single Emacs frontend covers both Docker daemons and Kubernetes
clusters.  As of Phase A:

- `M-x docker` — unchanged.
- `M-x k8s` — works against your kubeconfig (kubeconfig path or `KUBECONFIG`).
- `M-x eltainer` — picks one of the two backends (completing-read).
- Sources live in `docker/` and `k8s/` subdirectories; `eltainer.el`
  is the loader.  Phase B will lift the shared HTTP transport.

See [docs/merge-emak8s.md](docs/merge-emak8s.md) for the plan.

## Architecture

```
eltainer.el            Loader + `M-x eltainer'
reload.el              Dev helper: byte-compile + reload both halves

docker/
  docker-http.el       HTTP/1.1 over unix / TCP / TCP+TLS (GnuTLS)
  docker-stream.el     8-byte multiplex demux + ndjson splitter
  docker-api.el        /vX.Y-prefixed engine GET / POST / DELETE
  docker-config.el     Daemon connection params
  docker-ps.el         Containers: list / inspect / lifecycle
  docker-images.el     Images: list / inspect / tag / remove
  docker-networks.el   Networks: list / inspect / connect / remove
  docker-events.el     Long-lived /events stream + pub/sub
  docker-logs.el       Streaming /containers/{id}/logs, demuxed
  docker-terminal.el   Backend picker: eat → vterm → term
  docker-exec.el       Upgrade-hijacked /exec/{id}/start, TTY in Emacs
  docker-auth.el       ~/.docker/config.json + docker-credential-* helpers
  docker-pull.el       Streamed /images/create with per-layer progress
  docker.el            magit-section views, transient dispatch, actions

k8s/
  k8s-config.el        kubeconfig YAML parser (subset)
  k8s-api.el           REST client over GnuTLS (Phase B: lift onto docker-http)
  k8s-watch.el         Per-resource watch streams
  k8s-pods.el          Pods view: phases, restarts, container statuses
  k8s-fs.el            Pod-fs browser  (kubectl-exec underneath)
  k8s-fs-ui.el         …its UI layer
  k8s-exec.el          WebSocket exec into pods
  k8s.el               Shared k8s magit-section views + transient
```

## Requirements

- Emacs 30+ built with native JSON (`json-parse-string`) and, for TLS
  daemons, GnuTLS (`gnutls-available-p`).  eldocker refuses to load
  without the former and refuses to TLS-connect without the latter.
- `magit-section`, `transient`.
- A running Docker daemon reachable over a Unix socket or TCP.
- Optional but recommended for TTY exec: `package-install eat` (pure
  Elisp) or compile in `vterm` for best fidelity.  Falls back to
  built-in `term-mode` if neither is present.

## Quick start

```elisp
(add-to-list 'load-path "/path/to/eldocker")
(require 'eltainer)               ; loads both docker/ and k8s/

;; Then any of:
;;   M-x eltainer          ; prompt for backend
;;   M-x docker            ; containers view
;;   M-x docker-images     ; images
;;   M-x docker-networks   ; networks
;;   M-x k8s               ; cluster pods view
```

## Demo

The GIF at the top is regenerated by `docs/record-demo.sh` (requires
[asciinema](https://asciinema.org/) and
[agg](https://github.com/asciinema/agg) — `brew install agg`).  The
script spins up a sentinel `eldocker-ticker` container if needed,
launches a scripted `emacs -nw` session via
[`docs/demo-init.el`](docs/demo-init.el), records it with asciinema,
and converts to GIF.

## License

Apache 2.0 — see [LICENSE](LICENSE).
