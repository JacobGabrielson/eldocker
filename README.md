# eldocker

A pure Emacs Lisp Docker client and magit-style Docker browser.

## Philosophy

**Pure Elisp. Docker CLI is the only shelled-out dependency.**

eldocker shells out to the Docker CLI (`docker`, `sbx`, etc.) for all
daemon operations. Everything else — JSON parsing, UI rendering, config
handling — is pure Emacs Lisp. No Python, no Go, no shell scripts.

## What it does (planned)

`M-x docker` opens a magit-style buffer showing your containers. From
there:

| Key | Action |
|-----|--------|
| `?` | Transient dispatch menu (all operations) |
| `g` | Refresh |
| `q` | Quit |
| `s` | Start container |
| `S` | Stop container |
| `r` | Restart container |
| `d` | Delete container/image |
| `i` | Inspect container/image |
| `l` | Tail container logs |
| `e` | Exec command in container |
| `TAB` | Expand/collapse section details |

### Planned views

- **Containers** — running/all list with status, ports, names, images
- **Images** — image list with tags, sizes, created
- **Compose** — compose project status, service-level views
- **Logs** — live tailing with follow, timestamps, streaming
- **Exec** — interactive command execution in containers

## Architecture

```
 eldocker (this repo)
   |
   |-- docker-config.el   Docker env config (socket, TLS, hosts)
   |-- docker-api.el      Docker CLI wrapper (call-process, JSON parse)
   |-- docker-ps.el       Container listing, start/stop/rm/kill
   |-- docker-images.el   Image listing, pull/push/build/rmi
   |-- docker-logs.el     Log tailing (async process, follow)
   |-- docker-exec.el     Container exec (interactive commands)
   |-- docker-compose.el  Docker Compose operations
   |-- docker.el          Shared UI (magit-section, transient menus)
   |
   +-- Docker CLI         The only external dependency (docker, sbx)
```

### Networking

- **CLI commands**: `call-process` / `start-process` to `docker` CLI
- **JSON**: Emacs built-in `json.el` for parsing docker CLI output
- **Streaming**: `start-process` with process filter for log tailing

### UI

Built on `magit-section` for collapsible sections and `transient` for
popup menus. All views derive from `magit-section-mode`.

## Requirements

- Emacs 29+
- `magit-section`, `transient` packages
- Docker CLI installed and functional
- A running Docker daemon (local or remote)

## Quick start

```elisp
(add-to-list 'load-path "/path/to/eldocker")
(require 'docker)

;; Then:
;;   M-x docker
```

## License

GPL-3.0 — see [LICENSE](LICENSE).
