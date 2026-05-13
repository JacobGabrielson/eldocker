# AGENT.md — Project rules for eldocker

## What this project is

A pure Emacs Lisp Docker client and magit-style Docker browser.
Shells out to the Docker CLI (docker, sbx, etc.) — no other external
dependencies. All parsing, UI rendering, and business logic is pure Elisp.

## Implementation plan (2026-05-13)

### Phase 1 — Core infrastructure

1. **docker-config.el** — Docker socket path detection, environment config
   - Detect DOCKER_HOST, default socket path, TLS settings
   - Config struct for connection parameters

2. **docker-api.el** — Docker CLI wrapper
   - Pure Elisp wrapper around `call-process` / `start-process` for docker CLI
   - JSON output parsing with Emacs built-in `json.el`
   - Error handling, exit code checking, retry logic
   - Functions: docker-command (synchronous), docker-command-async

3. **docker-ps.el** — Container listing (docker ps)
   - List containers (running/all), format columns
   - Start, stop, restart, rm, kill containers
   - Inspect containers (docker inspect)

4. **docker-images.el** — Image management
   - List images (docker images)
   - Pull, push, build, rmi images
   - Tag, inspect images

5. **docker.el** — Shared magit-section UI infrastructure
   - Magit-section based buffer for container/image views
   - Transient menus for actions
   - Keybinding conventions matching emak8s style

### Phase 2 — Advanced features

6. **docker-logs.el** — Log viewing and tailing
   - Follow/tail container logs (docker logs -f)
   - Timestamps, latest N lines, streaming via async process

7. **docker-exec.el** — Container exec
   - Run commands in containers interactively
   - Attach to container stdin/stdout

8. **docker-compose.el** — Docker Compose support
   - Compose up/down, ps, logs, exec
   - Service filtering, project-scoped views

### Phase 3 — Polish

9. **reload.el** — Dev helper: byte-compiles + reloads all modules
10. **test/** — ERT tests using a local Docker daemon
    - test-docker-api.el — CLI wrapper tests
    - test-docker-ps.el — Container listing tests
    - test-docker-images.el — Image listing tests
    - test-docker-compose.el — Compose tests

### File layout (final)

```
docker-config.el   — Docker socket/env config, structs
docker-api.el      — Docker CLI wrapper (sync/async JSON parsing)
docker-ps.el       — Container listing, start/stop/rm
docker-images.el   — Image listing, pull/push/build/rmi
docker-logs.el     — Log tailing (follow, timestamps, streaming)
docker-exec.el     — Container exec (interactive commands)
docker-compose.el  — Docker Compose operations
docker.el          — Shared UI infrastructure, all views
reload.el          — Dev helper: compile + reload all modules
test/              — ERT tests against local Docker daemon
```

### Key dependencies (Emacs packages)

- `magit-section` — section-based UI (collapsible, navigable)
- `transient` — popup menus (action dispatch, ? key)
- `json.el` — ships with Emacs (JSON parsing from docker CLI output)
- `cl-lib` — ships with Emacs (cl-defstruct, etc.)

## Core constraints

- **Pure Elisp only.** Every line of code must be Emacs Lisp.
- **Shell out ONLY to Docker products** (docker CLI, sbx, etc.).
  Use `call-process` or `start-process` for docker commands. Never
  shell out to kubectl, curl, python, or anything else.
- **No Docker daemon TCP connection directly** — use the docker CLI
  as the canonical interface. The CLI handles socket connection,
  TLS, auth, and streaming for us.
- **Target Emacs 29+.**

## Code style

- Always use `lexical-binding: t` in file headers.
- Use `cl-lib` (cl-defstruct, cl-loop, etc.) — ships with Emacs.
- Prefix all public symbols with `docker-` (e.g., `docker-list-containers`).
- Prefix internal/private symbols with `docker--`.
- Use `defcustom` for user-facing configuration, `defvar` for state.

## UI conventions

- Follow magit's UI patterns: collapsible sections, single-key navigation, transient menus.
- All views derive from `magit-section-mode`.
- Buffer names: `*docker:<view>*` (e.g., `*docker:containers*`, `*docker:images*`).
- Log buffers: `*docker:logs:<container>*`.

### Keybinding conventions

| Key | Action | Scope |
|-----|--------|-------|
| `g` | Refresh (fresh docker CLI call) | All views |
| `q` | Quit | All views |
| `d` | Delete/remove resource | All views |
| `i` | Inspect resource | All views |
| `s` | Start container | Containers view |
| `S` | Stop container | Containers view |
| `r` | Restart container | Containers view |
| `l` | View logs | Containers view |
| `e` | Exec command | Containers view |
| `?` | Transient dispatch menu | All views |
| `TAB` | Expand/collapse section | All views |
| `RET` | Smart action or inspect | All views |
| `n/p` | Next/prev section (magit) | All views |

## Testing

- Use `emacs --script` to run tests.
- Tests are ERT, in `test/` directory, named `test-<module>.el`.
- Tests hit a local Docker daemon (docker CLI must be available).
- A running Docker daemon is required — that is the whole point.

```bash
emacs --script test/test-docker-api.el
emacs --script test/test-docker-ps.el
emacs --script test/test-docker-images.el
```

## User preferences

- Keep responses concise — the user is an expert Elisp developer.
- Use `completing-read` for container/image selection.
- Use `transient` for action menus.
