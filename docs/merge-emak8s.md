# Plan: merge emak8s into this repo

Status: **proposal**.  Sketches a unified "Emacs container porcelain"
that fronts both Docker daemons and Kubernetes clusters through the
same UI primitives.

## Why merge

Both codebases solve the same shape of problem with two different
backends:

|                          | eldocker                                 | emak8s                              |
| ------------------------ | ---------------------------------------- | ----------------------------------- |
| Transport                | HTTP/1.1 over unix socket / TCP / TCP+TLS| HTTPS to API server                 |
| Auth                     | Optional client cert; cred-helper plugins | Always TLS; bearer/cert/exec plugin |
| Streaming                | `/events` + per-container logs           | `/api/.../watch=true` + pod logs     |
| Exec into running thing  | HTTP Upgrade hijack, raw bidi bytes      | WebSocket (RFC 6455) frames         |
| Resource shape           | container / image / network              | pods / deps / services / configmaps / … |
| UI                       | magit-section + transient                | magit-section + transient           |
| Code base                | ~3 kloc                                  | ~3.4 kloc                            |

Roughly 30–40% of the code in each repo is doing the same job: open
a sized terminal buffer, run an HTTP+JSON request through GnuTLS,
parse chunked transfer, dispatch into magit-section view code,
auto-refresh on a streamed event.  The other 60% is genuinely domain-
specific: docker exec is not k8s exec, network sections are not pod
phases, registry auth is not kubeconfig auth.

Merging gives us:

- **One transport** (`docker-http.el` already covers most of what
  `k8s-api.el` needs; the URL-via-`url.el` path emak8s uses is the
  weaker of the two).  Single chunked decoder, single streaming
  filter, single TLS-via-GnuTLS setup, no `gnutls-boot-parameters`
  advice.
- **One UI shell** — a single `*ctr:resources*` (or whatever we call
  it) buffer pattern, a single dispatch transient, one set of section
  conventions.  Switching between docker and k8s feels like switching
  buffers in magit.
- **One terminal backend abstraction** (`docker-terminal.el` already
  is — eat / vterm / term selector).  Both exec implementations feed
  through the same `docker-terminal-feed`.
- **One auth helper invocation pattern** — `docker-credential-*` and
  `kubectl exec` plugin auth both shell out to small external helpers
  that return JSON on stdout.  Same shape, slightly different schemas.
- **Half-feature porting comes free.**  k8s currently polls pod logs
  every 2 s; lifting eldocker's streaming-log code gives k8s live
  logs.  eldocker doesn't surface "describe" output the way emak8s
  does; lifting that gives docker inspect a nicer rendering.

## What's *not* worth merging

These are domain-specific and stay separate, even after the merge:

- **Resource modelling.**  k8s has 10+ resource types with
  group/version/kind, namespaces, labels, owner references, status
  subresources, server-side prints.  Docker has 3 resource types
  with no group/version dimension.  Trying to model them under one
  generic resource struct adds more friction than it removes.
- **Watch vs events.**  k8s watches are *per-resource-type*, stateful
  (resource-version → reconnect at the right point), and bookmark-
  capable.  Docker `/events` is one global stream.  The pub-sub layer
  can be shared (subscribe a buffer, get refreshed callbacks); the
  state machine cannot.
- **Exec framing.**  k8s exec is WebSockets (Sec-WebSocket-Key,
  Sec-WebSocket-Protocol negotiation, per-frame masking, channel
  multiplexing via the first byte).  Docker exec is HTTP/1.1 Upgrade
  with raw bidi bytes.  Both end up calling
  `docker-terminal-feed`/`docker-terminal-bind`, but the framing layer
  is genuinely different code.
- **Image / pull / build.**  k8s has none of this; Docker's pull is
  already done.  These stay in `docker-*` files.

## Target architecture

```
ctr-http.el          HTTP/1.1 + streaming (was docker-http.el)
ctr-stream.el        ndjson + multiplex demux (was docker-stream.el)
ctr-terminal.el      eat/vterm/term selector (was docker-terminal.el)
ctr-events.el        debounced pub/sub for view auto-refresh
ctr-shell-helper.el  invoke `docker-credential-*' / exec plugins, parse JSON
ctr.el               shared magit-section view scaffolding, dispatch transient

docker/                                    k8s/
  docker-config.el     # daemon URLs       k8s-config.el     # kubeconfig YAML
  docker-api.el        # engine GET/POST/  k8s-api.el        # /api & /apis
                       # DELETE, version
                       # pin
  docker-ps.el         # containers        k8s-pods.el
  docker-images.el     # images            k8s-deployments.el
  docker-networks.el   # networks          k8s-services.el
  docker-logs.el       # streaming logs    k8s-logs.el        # gains streaming
  docker-exec.el       # Upgrade-hijack    k8s-exec.el        # WebSocket
  docker-pull.el       # /images/create    (no k8s analogue)
  docker-auth.el       # cred helpers      k8s-auth.el        # tokens & exec
                                           #                  plugins
  docker-views.el      # docker            k8s-views.el       # k8s magit-section
                       # magit-section     #                  views
                       # views

ctr-init.el / ctr-loader.el  # one place that requires both halves
```

The `ctr-*.el` prefix is a placeholder — pick a real name (see Open
questions below).  Everything that's truly shared moves up one level;
everything domain-specific lives under `docker/` or `k8s/`.

Two top-level entry points stay distinct (`M-x docker`, `M-x k8s`) but
they open isomorphic-feeling buffers — same keybindings for refresh,
inspect, delete, exec, logs.

## Lift-up plan (concrete file → file mapping)

Roughly, today's `docker-*.el` and `k8s-*.el` collapse like this:

| Today (eldocker)        | Today (emak8s)        | After merge                    |
| ----------------------- | --------------------- | ------------------------------ |
| `docker-http.el`        | the streaming half of `k8s-api.el` and all of `k8s-watch.el`'s socket plumbing | `ctr-http.el` |
| `docker-stream.el`      | NDJSON / chunked decoding inside `k8s-api.el` + `k8s-watch.el` | `ctr-stream.el` |
| `docker-terminal.el`    | terminal handling currently buried in `k8s-exec.el` | `ctr-terminal.el` |
| `docker-events.el`      | the dispatch/debounce layer hand-rolled across k8s view buffers | `ctr-events.el` |
| `docker-auth.el` (cred-helper invocation) | the exec-plugin path in `k8s-config.el` | `ctr-shell-helper.el` |
| (no analogue today)     | parts of `k8s.el` that are pure magit-section helpers (`--insert-header`, `--age-string`, `--phase-face`, generic refresh skeleton) | `ctr.el` |

That last row is the biggest win: today both `docker.el` and `k8s.el`
have their own copy of the generic "insert a header, group items,
draw collapsible sections, run a debounced refresh on event"
machinery.  Lifting it once makes adding a third backend (Compose
projects? Nomad?) a much smaller project.

## Phased migration

Each phase keeps both `M-x docker` and `M-x k8s` working at every
commit boundary.  Tests stay green throughout.

### Phase A — fold both repos into one tree

1. Move emak8s sources into `eldocker/k8s/`, retaining the `k8s-*`
   prefix.  Move eldocker sources into `eldocker/docker/`.
2. Add `eldocker/ctr.el` as a tiny loader (`(require 'docker)
   (require 'k8s)`) so the existing entry points still work.
3. Both readmes consolidated; one license file (both are permissive,
   re-license under whichever you prefer).  No code changes.

The repo is renamed.  Rename it now while history is short — a few
options below.

### Phase B — lift the shared transport

1. Rename `docker-http.el` → `ctr-http.el`, generalize the connection
   construction: take a struct that carries `(scheme . host . port .
   socket-path . tls . ca . cert . key . auth-header)`.  Both
   `docker-config` and `k8s-config` reduce to "produce one of these."
2. Migrate k8s onto `ctr-http`.  Drop the `url.el`-based path and the
   `gnutls-boot-parameters` advice in `k8s-api.el`; replace with
   direct `make-network-process :tls-parameters`.
3. Streaming watches in `k8s-watch.el` route through
   `docker-http-stream` (= `ctr-http-stream`).  Resource-version logic
   stays in `k8s-watch.el` as a thin layer above the transport.
4. Rename `docker-stream.el` → `ctr-stream.el`.  No content changes;
   k8s starts using the ndjson splitter.

After Phase B the k8s code talks to the API server through the same
plumbing the docker code uses for the daemon.  Tests on both sides
must still pass.

### Phase C — lift the UI shell

1. Extract from `docker.el` and `k8s.el` the genuinely-shared bits:
   - `--age-string`, `--truncate`, `--describe-value`
   - The header insert helper (`Docker: …  Endpoint: …` / `Cluster:
     …  Namespace: …`)
   - The `--generic-refresh` skeleton (erase / insert header / fold
     rows / show root section)
   - The dispatch-transient pattern (group keys, container-at-point
     style action dispatch)
   - Common faces (running / stopped / dim) renamed to
     `ctr-status-running` etc.
2. Place in `ctr.el` (plus `ctr-faces.el` if it grows).
3. Both `docker.el` and `k8s.el` shrink to "produce rows + bind
   actions"; the scaffolding is shared.
4. Subscribe both halves to `ctr-events.el`.

### Phase D — lift the terminal backend

1. Rename `docker-terminal.el` → `ctr-terminal.el`; nothing else
   changes — the abstraction is already general.
2. Rewrite `k8s-exec.el` so its WebSocket frame parser feeds
   `ctr-terminal-feed` instead of poking at the buffer directly.  All
   the eat/vterm/term selection is then automatic.
3. SIGWINCH equivalent: `k8s-exec` POSTs the resize subresource;
   `docker-exec` POSTs `/exec/{id}/resize`.  Common hook lives in
   `ctr.el`, per-backend resize helpers in each domain module.

### Phase E — lift the auth-helper invocation

1. Extract `docker-auth--run-helper` into
   `ctr-shell-helper.el`: a generic
   `(ctr-shell-helper BINARY ARGS STDIN-STR) → JSON-or-nil`.
2. `docker-auth.el` uses it for `docker-credential-*`.
3. `k8s-config.el`'s exec-plugin auth uses it for arbitrary commands
   (sometimes `aws eks get-token …`, sometimes `gke-gcloud-auth-plugin`).

### Phase F — feature parity wins

Now that the scaffolding is shared, harvest the asymmetries:

1. `k8s-logs.el` switches from 2-second polling to streaming chunked
   responses through `ctr-http-stream` — same approach as
   `docker-logs.el`.
2. `docker-inspect-at-point` adopts emak8s's nicer
   "describe-with-events" rendering (events alongside the spec).
3. Both halves get debounced auto-refresh on the same event-bus type,
   so a k8s buffer can in principle subscribe to docker events too
   (silly, but cheap).
4. `M-x ctr` opens whichever backend is "active" in the current
   buffer / window context, with a transient to switch.

### Phase G — cleanup

1. Delete dead code: emak8s's `url.el` path, the
   `gnutls-boot-parameters` advice, duplicate `--age-string`
   implementations.
2. Update `docs/direct-daemon-rewrite.md` to be `docs/architecture.md`
   covering both halves.
3. Update `AGENT.md` constraints to cover both backends.

## Risks / tricky parts

- **TLS client certs in two different shapes.**  Docker daemon's TLS
  is symmetric — a few PEM files referenced by `docker-config`'s slot
  names.  k8s kubeconfig allows three formats per user: client-
  certificate file, base64-encoded inline data, or exec-plugin
  output.  The shared `ctr-http--connect` must accept any of them; in
  practice it'll take resolved file paths and let the per-domain
  config layer extract / temp-file the inline / exec-plugin variants.
- **WebSocket implementation in `k8s-exec.el`.**  This is the most
  domain-specific code we keep — about 200 lines of frame
  encode/decode + masking + per-channel demux (stdin / stdout /
  stderr / err / resize).  Worth a thorough re-read during the lift
  to make sure we don't accidentally regress it.
- **Two-`reload.el`.**  emak8s and eldocker both have one.  Merge
  into a single `eldocker-reload`-style helper that re-enters modes
  in any open `ctr-*-mode` buffer (which the current eldocker reload
  already does for `docker-*-mode`).
- **YAML parser in `k8s-config.el`.**  emak8s rolled its own
  small-YAML parser because nothing in Emacs ships with one.  Stays
  put — it's k8s-only.
- **Naming clashes.**  Both repos define `--age-string` and similar
  helpers.  Lifting requires picking a single semantics (k8s prefers
  ISO-8601 strings, docker prefers epoch ints from the daemon).
  Already partially solved in eldocker (`docker--epoch-to-iso` +
  age-from-iso).  Standardize on epoch-seconds in/ISO-out at the
  module boundary.
- **License.**  eldocker = Apache-2.0, emak8s = MIT (README says GPL,
  the actual LICENSE file is MIT; worth correcting before merge).
  Both are permissive and forward-compatible; pick one for the merged
  repo and update file headers.

## Open questions

- **What's it called?**  Some candidates:
  - **emcontainers** / **em-ctr** — explicit, ugly
  - **emak** — Emacs ↔ Kubernetes/docker shorthand, reads as "ee-mack"
  - **harbor** — overloaded (Docker Harbor exists)
  - **dock** — too narrow
  - **moored** — playful, Emacs-y in tone, available
  - **emak8s** kept (extended to docker), or **eldocker** kept
    (extended to k8s).  Cleanest from a git-history perspective: keep
    `eldocker` as the repo name (the rewrite's history is here) and
    accept the misnomer.
- **One buffer or two?**  Should `M-x docker` and `M-x k8s` stay
  distinct, or should one master `M-x ctr` accept a backend
  argument?  My read: keep both, both also reachable from a `b`
  ("backend") binding inside either view.
- **Compose / Nomad later?**  Building a third backend on top of the
  shared scaffolding is a good stress test for the abstraction.
  Compose specifically is appealing: the daemon doesn't model
  projects, so a `*ctr:compose*` view that overlays compose project
  membership on top of the existing docker container list is a real
  feature.
- **Tramp-friendly?**  Today both clients run from local Emacs.  If
  we want "ssh into a host and run eldocker over the remote socket"
  to work without a CLI fallback, Tramp integration is a separate
  thread.
