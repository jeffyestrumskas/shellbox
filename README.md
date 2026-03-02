# shellbox

A tiny "dev sandbox" wrapper that drops you into a Dockerized shell with your current working directory mounted inside the container.

Currently built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — the Dockerfile is embedded in the script itself (single file, no extras).

- Run from any directory — your project files are mounted at `/work`
- Container is ephemeral (`--rm`) and removed when you exit
- Images are tagged per “profile” so you can reuse a built environment across projects
- Comes with Claude Code CLI, Python 3, Node.js, and common dev tools pre-installed
- `ANTHROPIC_API_KEY` is forwarded into the container automatically
- Lightweight sandboxing: `--cap-drop ALL` and `no-new-privileges`

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

This builds a Docker image (if needed), mounts the current directory to `/work` inside the container, and drops you into an interactive bash shell. The container is removed automatically when you exit.

### Environment

The following are set inside the container automatically:

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Forwarded from host (required for Claude Code) |
| `PIP_NO_CACHE_DIR=1` | Disables pip cache inside the container |
| `TERM` | Inherited from host (`xterm-256color` default) |

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
| `--no-build` | Skip the build step (assume the image already exists) |
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

