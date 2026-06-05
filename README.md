# shellbox

A tiny "dev sandbox" wrapper that drops you into a Dockerized shell with your current working directory mounted inside the container.

Currently built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) -the Dockerfile is embedded in the script itself (single file, no extras).

- Run from any directory -your project files are mounted at `/home/dev/work`
- Container is ephemeral (`--rm`) and removed when you exit
- Images are tagged per “profile” so you can reuse a built environment across projects
- Comes with Claude Code CLI (installed via official `curl` method), Python 3, and common dev tools pre-installed
- Surgical Claude config copy: settings, auth, and customizations only (no history/caches/plugins); project `.claude/` is mounted
- `ANTHROPIC_API_KEY` forwarded; telemetry opt-out vars preset (overridable)
- Optional toggles to pre-accept Claude Code's folder-trust / bypass-permissions dialogs
- Lightweight sandboxing: `--cap-drop ALL` and `no-new-privileges`
- Optional gVisor isolation (`--runsc`) and an opt-in interactive egress firewall (`--boxwall`, see [boxwall](#boxwall))

---

## Requirements

- Docker Desktop / Docker Engine (23.0+ recommended for multiple `--network` flags)
- `ANTHROPIC_API_KEY` set in your host environment

---

## Install

Save `shellbox.sh` in $PATH and make it executable

---

## Usage

From any project directory, run:

```bash
shellbox.sh
```

This builds a Docker image (if needed), mounts the current directory to `/home/dev/work` inside the container, and drops you into an interactive bash shell. The container is removed automatically when you exit.

### Environment

The following are set inside the container automatically:

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Forwarded from host (required for Claude Code) |
| `PIP_NO_CACHE_DIR=1` | Disables pip cache inside the container |
| `TERM` | Inherited from host (`xterm-256color` default) |
| Telemetry opt-outs | `DO_NOT_TRACK`, `DISABLE_TELEMETRY`, etc. (see `DEFAULT_ENV_VARS` in the script) |

Presets apply first; `-e KEY=VALUE` overrides them.

### Sandbox dialog auto-accept

Toggles at the top of `shellbox.sh` pre-accept Claude Code's first-run dialogs (`1`/`0`, no rebuild needed):

| Variable | Suppresses |
|---|---|
| `SHELLBOX_TRUST_WORKDIR` | "Trust this folder?" |
| `SHELLBOX_ACCEPT_BYPASS_PERMISSIONS` | "Bypass Permissions mode" warning |

### Profiles

Use profiles to maintain separate image tags for different projects:

```bash
shellbox.sh -n myproject
```

This tags the image as `shellbox-dev:myproject` so the built environment is reused across sessions for that profile.

### Running a command

Pass a command after `--` to run it instead of an interactive shell:

```bash
shellbox.sh -- python3 my_script.py
shellbox.sh -p 8000:8000 -- python3 -m http.server 8000
```

### Options

| Flag | Description |
|---|---|
| `-n, --profile NAME` | Use a named image tag (`shellbox-dev:NAME`) |
| `-v, --volume HOST:CONTAINER[:ro]` | Add an extra volume mount (repeatable) |
| `-e, --env KEY=VALUE` | Pass an environment variable (repeatable) |
| `-p, --port HOST:CONTAINER` | Publish a port (repeatable) |
| `-N, --network NETWORK` | Connect to a Docker network (repeatable) |
| `--container-name NAME` | Set an explicit container name |
| `--image IMAGE` | Use a custom image name (overrides `--profile`) |
| `--rebuild` | Force a full rebuild from scratch (`docker build --no-cache`) |
| `--no-build` | Skip the build step (assume the image already exists) |
| `--runsc` | Run under gVisor (`--runtime=runsc`) if registered; warn + continue otherwise |
| `--boxwall` | Route all egress through a running [boxwall](boxwall/README.md) firewall (see below). Incompatible with `-p`/`-N` |
| `--boxwall-name NAME` | Attach to a named boxwall (default `shellbox-boxwall`; implies `--boxwall`) |
| `-h, --help` | Show help |

### Examples

```bash
# Basic interactive shell
shellbox.sh

# Named profile with an extra mount
shellbox.sh -n projectA -v ~/data:/data:ro

# Expose a port and run a server
shellbox.sh -p 3000:3000 -- node server.js

# Join an existing Docker network
shellbox.sh -N my-network

# Fixed container name (prevents duplicate instances)
shellbox.sh --container-name mybox
```

---

## boxwall

`boxwall` is an opt-in, interactive egress firewall for the sandbox: run it in a second window and approve every new outbound connection by hand. Start it, then attach a sandbox with `--boxwall`:

```bash
# window 1: start the firewall (stays running)
./boxwall/boxwall.sh

# window 2: start a sandbox that routes all egress through it
shellbox.sh --boxwall
```

It lives in its own directory with full docs: see [boxwall/README.md](boxwall/README.md).

