# eltainer

A pure Emacs Lisp porcelain for **Docker and Kubernetes**, fronted by
a single magit-style UI.

> Note: the repo is still named `eldocker` while the rewrite settles.
> The eventual rename to `eltainer` is parked behind everything
> working.  GitHub mirrors at
> [JacobGabrielson/eldocker](https://github.com/JacobGabrielson/eldocker)
> and [JacobGabrielson/eltainer](https://github.com/JacobGabrielson/eltainer).

![eltainer dashboard + docker exec](docs/exec-demo.gif)

*`M-x eltainer` opens a dashboard listing every available view in both
backends.  `c` jumps to the docker containers list; `e` on a row opens
a real shell inside the container — via HTTP Upgrade hijack of
`POST /exec/{id}/start`, rendered in `eat`.  No `docker` CLI involved.*

## Philosophy

**Pure Elisp talking directly to the daemon.**

eltainer speaks HTTP/1.1 to the Docker daemon over its Unix socket
**and** HTTPS to the Kubernetes API server.  Both halves share one
transport (`docker-http.el`), one streaming/event pipeline, one
terminal abstraction.  No `docker` CLI, no `kubectl`.  JSON via native
`json-parse-*`, TLS via built-in GnuTLS; the package refuses to load
without the former and refuses to TLS-connect without the latter.

CLI fallbacks are kept *only* for things the engine APIs genuinely
can't do — `docker build` (BuildKit gRPC), `docker compose`, CLI
plugins, `docker login` config writes, `DOCKER_HOST=ssh://…` transport,
and `docker-credential-*` / kubeconfig-exec helper binaries.  Each is
one clearly-named function in one place.  See
[docs/direct-daemon-rewrite.md](docs/direct-daemon-rewrite.md) and
[docs/merge-emak8s.md](docs/merge-emak8s.md).

## What you can do

`M-x eltainer` is the home screen.  From there, single-key launchers:

| Backend | Key | View |
|---------|-----|------|
| Docker | `c` | Containers (running; `a` toggles all) |
| Docker | `I` | Images |
| Docker | `N` | Networks (+ connected containers) |
| Docker | `p` | Pull image (streamed per-layer progress) |
| Kubernetes | `k` | Pods grouped by namespace |
| Kubernetes | `d` | Deployments |
| Kubernetes | `s` | Services |
| Kubernetes | `S` | StatefulSets |
| Kubernetes | `D` | DaemonSets |
| Kubernetes | `j` / `J` | Jobs / CronJobs |
| Kubernetes | `i` | Ingresses |
| Kubernetes | `m` / `x` | ConfigMaps / Secrets |

`M-x docker` and `M-x k8s` still work directly and bypass the
dashboard if that's what you want.

### Inside any docker view

| Key | Action |
|-----|--------|
| `?` | Transient dispatch menu |
| `g` | Refresh |
| `q` | Quit window |
| `RET` | Toggle section / DWIM |
| `i` | Inspect resource at point |
| `d` | Delete / disconnect (context-aware) |
| `a` | Toggle running-only vs. all (containers view) |
| `s` `S` `r` `K` | Start / Stop / Restart / Kill container |
| `l` | Tail logs (streaming, stdout / stderr demuxed) |
| `e` | Exec a shell inside the container (TTY) |
| `j` `J` | Join / leave a network |

Views auto-refresh as the daemon's `/events` stream tells us what
changed (debounced).  The TTY exec lands in whichever screen-oriented
emulator is available (`eat` → `vterm` → `term`; `M-x customize-variable
eltainer-terminal-backend` to override).

### Inside the k8s view

| Key | Action |
|-----|--------|
| `?` | Dispatch menu (resource types) |
| `g` | Refresh |
| `N` | Switch namespace |
| `w` | Toggle live watch (auto-update via the K8s watch API) |
| `i` | Describe resource |
| `l` | Tail pod logs |
| `d` | Delete resource (with confirmation) |
| `TAB` | Expand / collapse section |

## Architecture

```
eltainer.el            Dashboard + `M-x eltainer'
eltainer-ui.el         Shared faces, age-string, describe-value
eltainer-terminal.el   Terminal backend selector: eat → vterm → term
reload.el              Dev helper: byte-compile + reload both halves

docker/
  docker-http.el       HTTP/1.1 over unix / TCP / TCP+TLS (GnuTLS)
                       + chunked-decoded streaming.  Used by k8s too.
  docker-stream.el     8-byte multiplex demux + ndjson splitter
  docker-api.el        /vX.Y-prefixed engine GET / POST / DELETE
  docker-config.el     Connection params struct (used by k8s too)
  docker-ps.el         Containers: list / inspect / lifecycle
  docker-images.el     Images: list / inspect / tag / remove
  docker-networks.el   Networks: list / inspect / connect / remove
  docker-events.el     Long-lived /events stream + pub/sub
  docker-logs.el       Streaming /containers/{id}/logs, demuxed
  docker-exec.el       Upgrade-hijacked /exec/{id}/start TTY
  docker-auth.el       ~/.docker/config.json + docker-credential-* helpers
  docker-pull.el       Streamed /images/create with per-layer progress
  docker.el            magit-section views + transient + actions

k8s/
  k8s-config.el        kubeconfig YAML parser (subset)
  k8s-api.el           REST client (thin wrapper over docker-http)
  k8s-watch.el         Watch streams on docker-http-stream + ndjson splitter
  k8s-pods.el          Pods view: phases, restarts, container statuses
  k8s-fs.el            Pod-fs browser
  k8s-fs-ui.el           …its UI layer
  k8s-exec.el          One-shot exec (returns stdout / stderr / exit-code)
  k8s.el               Shared k8s magit-section views + transient
```

Phase A → D of the [merge plan](docs/merge-emak8s.md) are landed; that
lifted the HTTP transport, the streaming/event pipeline, the
magit-section helpers, the faces, and the terminal abstraction so
both halves ride on one stack.  Interactive (TTY) `k8s exec` over
WebSockets is the natural next consumer of `eltainer-terminal`.

## Requirements

- Emacs 30+ with native JSON (`json-parse-string`) and, for any TLS
  target, GnuTLS (`gnutls-available-p`).  eltainer refuses to load
  without the former and refuses to TLS-connect without the latter.
- `magit-section`, `transient`.
- A running Docker daemon and / or a kubeconfig.
- Optional but recommended for TTY exec:
  [`eat`](https://codeberg.org/akib/emacs-eat) (`M-x package-install
  eat`, pure-elisp) or
  [`vterm`](https://github.com/akermu/emacs-libvterm) (compiled
  module).  Falls back to built-in `term-mode` if neither is present.

## Quick start

```elisp
(add-to-list 'load-path "/path/to/eldocker")
(require 'eltainer)

;; Then any of:
;;   M-x eltainer          ; dashboard listing every view
;;   M-x docker            ; jump straight to docker containers
;;   M-x k8s               ; jump straight to k8s pods
```

For development:

```elisp
(load "/path/to/eldocker/reload.el")
;; M-x eltainer-reload       ; byte-compile + reload + re-enter open buffers
```

## Demo

The GIF up top is regenerated by `docs/record-demo.sh` (requires
[asciinema](https://asciinema.org/) and
[agg](https://github.com/asciinema/agg) — `brew install agg`).  It
spins up a sentinel `eldocker-ticker` container, scripts an
`emacs -nw` session through
[`docs/demo-init.el`](docs/demo-init.el), records with asciinema, and
converts to GIF.

## License

Apache 2.0 — see [LICENSE](LICENSE).  Code lifted from emak8s (MIT) is
relicensed under Apache 2.0 with attribution; the LICENSE on the
upstream emak8s repo applies to any code there that hasn't been
imported.
