#!/usr/bin/env bash
set -euo pipefail

# Defaults
IMAGE_REPO="shellbox-dev"
PROFILE="default"                 # controls image tag: shellbox-dev:<PROFILE>
WORKDIR="/home/dev/work"

# Pre-accept Claude Code's interactive sandbox dialogs (1=on, 0=off).
# Applied to the container's config at startup by the entrypoint helper, so
# toggling these takes effect on the next run with NO rebuild needed.
SHELLBOX_TRUST_WORKDIR=1              # skip the "trust this folder?" dialog
SHELLBOX_ACCEPT_BYPASS_PERMISSIONS=1  # skip the "Bypass Permissions mode" warning

IMAGE_NAME=""                     # set after arg parsing
CONTAINER_NAME=""                 # ONLY set if user passes --container-name
NO_BUILD=0
REBUILD=0
USE_RUNSC=0                       # opt-in: run under gVisor (--runtime=runsc)
USE_BOXWALL=0                       # opt-in: route egress through the boxwall proxy
BOXWALL_NAME="shellbox-boxwall"       # boxwall container to attach to (see boxwall.sh)

EXTRA_MOUNTS=()
PORTS=()
NETWORKS=()

# Preset env vars always injected into the container.
# These go FIRST so that any user-supplied `-e KEY=VALUE` (appended later)
# overrides them — Docker honors the last `-e` for a given key.
DEFAULT_ENV_VARS=(
  # Generic opt-outs honored by many tools
  "DO_NOT_TRACK=1"
  "DISABLE_TELEMETRY=1"

  # Claude Code (CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC is the umbrella switch)
  "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
  "DISABLE_ERROR_REPORTING=1"
  "DISABLE_BUG_COMMAND=1"
  "DISABLE_NON_ESSENTIAL_MODEL_CALLS=1"

  # Node / JS ecosystem
  "NEXT_TELEMETRY_DISABLED=1"
  "NUXT_TELEMETRY_DISABLED=1"
  "GATSBY_TELEMETRY_DISABLED=1"
  "ASTRO_TELEMETRY_DISABLED=1"
  "TURBO_TELEMETRY_DISABLED=1"
  "STORYBOOK_DISABLE_TELEMETRY=1"
  "SAM_CLI_TELEMETRY=0"

  # Python / data tooling
  "SCARF_ANALYTICS=false"           # Scarf-instrumented pkgs (e.g. some PyPI/npm)

  # Runtime / host-derived (interpolated at definition time)
  "TERM=${TERM:-xterm-256color}"
  "PIP_NO_CACHE_DIR=1"
  "SHELLBOX_TRUST_WORKDIR=${SHELLBOX_TRUST_WORKDIR}"
  "SHELLBOX_ACCEPT_BYPASS_PERMISSIONS=${SHELLBOX_ACCEPT_BYPASS_PERMISSIONS}"
)

# User `-e/--env` flags are appended to this during arg parsing.
ENV_VARS=("${DEFAULT_ENV_VARS[@]}")

# Forward host's Anthropic API key into the sandbox (edit/remove to taste).
FORWARD_ANTHROPIC_API_KEY=0
[[ "${FORWARD_ANTHROPIC_API_KEY}" -eq 1 && -n "${ANTHROPIC_API_KEY:-}" ]] && \
  ENV_VARS+=( "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" )

# Grab host UID/GID once
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

usage() {
  cat <<'EOF'
Usage: ./shellbox.sh [options] [-- command...]

Single-file dev sandbox. The Dockerfile is appended at the end of this script and extracted at build time.
- Mounts the current directory to /home/dev/work and starts there.
- Container is removed on exit (--rm) and auto-named by Docker (unless --container-name is provided).
- Pip cache does NOT persist (PIP_NO_CACHE_DIR=1).
- Images are tagged per profile (shellbox-dev:<profile>).
- The container user is created with YOUR host UID/GID so file permissions just work.

Options:
  -n, --profile NAME                           Use a per-project image tag (shellbox-dev:NAME)
  -v, --volume HOST_PATH:CONTAINER_PATH[:ro]   Add extra volume mount (repeatable)
  -e, --env KEY=VALUE                          Add env var (repeatable)
  -p, --port HOST_PORT:CONTAINER_PORT          Publish port (repeatable)
  -N, --network NETWORK                        Connect to Docker network (repeatable)
  --container-name NAME                        Set an explicit container name (otherwise Docker auto-names)
  --image IMAGE                                Full image name override (e.g. myrepo:tag). Overrides --profile.
  --rebuild                                     Force a full rebuild from scratch (docker build --no-cache)
  --no-build                                   Don't build (assume image exists)
  --runsc                                       Run under gVisor (--runtime=runsc) if registered; warn + continue if not
  --boxwall                                       Route all egress through a running boxwall.sh (interactive egress firewall)
  --boxwall-name NAME                             Boxwall container to attach to (default: shellbox-boxwall; implies --boxwall)
  -h, --help                                   Show help

Examples:
  ./shellbox.sh
  ./shellbox.sh -n projectA
  ./shellbox.sh -n projectA -v .:/pwd
  ./shellbox.sh -p 8000:8000 -- python3 -m http.server 8000
  ./shellbox.sh --container-name mybox   # fixed name (prevents running two with same name)
  ./shellbox.sh -N sentirail             # join a Docker network (e.g. to reach boxwall-proxy)
EOF
}

abs_host_path() {
  local p="$1"

  # Expand ~ manually
  if [[ "$p" == "~" ]]; then p="$HOME"; fi
  if [[ "$p" == "~/"* ]]; then p="$HOME/${p:2}"; fi

  if [[ "$p" == /* ]]; then
    printf '%s\n' "$p"
    return 0
  fi

  local dir base
  dir="$(dirname "$p")"
  base="$(basename "$p")"
  (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$base") || true
}

sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    shasum -a 256 "$f" | awk '{print $1}'
  fi
}

extract_dockerfile() {
  # Prints everything after the marker
  awk 'found{print} /^__SHELLBOX_DOCKERFILE__$/ {found=1}' "$0"
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--profile)
      [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    -v|--volume)
      [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }
      EXTRA_MOUNTS+=("$2")
      shift 2
      ;;
    -e|--env)
      [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }
      ENV_VARS+=("$2")
      shift 2
      ;;
    -p|--port)
      [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }
      PORTS+=("$2")
      shift 2
      ;;
    -N|--network)
      [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }
      NETWORKS+=("$2")
      shift 2
      ;;
    --container-name)
      [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --image)
      [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }
      IMAGE_NAME="$2"
      shift 2
      ;;
    --rebuild)
      REBUILD=1
      shift
      ;;
    --no-build)
      NO_BUILD=1
      shift
      ;;
    --runsc)
      USE_RUNSC=1
      shift
      ;;
    --boxwall)
      USE_BOXWALL=1
      shift
      ;;
    --boxwall-name)
      [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }
      BOXWALL_NAME="$2"
      USE_BOXWALL=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

# Catch conflicting flags
if [[ "${NO_BUILD}" -eq 1 && "${REBUILD}" -eq 1 ]]; then
  echo "Error: --no-build and --rebuild are mutually exclusive" >&2
  exit 2
fi

# Compute image name default after args:
# - If --image not provided, use IMAGE_REPO:PROFILE
if [[ -z "${IMAGE_NAME}" ]]; then
  IMAGE_NAME="${IMAGE_REPO}:${PROFILE}"
fi

# Cleanup handler for temp files (runs on EXIT now that we don't exec)
TMPDIR_BUILD=""
CLAUDE_CONFIG_TAR=""
CLAUDE_JSON_DIR=""
cleanup() {
  [[ -n "${TMPDIR_BUILD}" ]] && rm -rf "${TMPDIR_BUILD}"
  [[ -n "${CLAUDE_CONFIG_TAR}" && -f "${CLAUDE_CONFIG_TAR}" ]] && rm -f "${CLAUDE_CONFIG_TAR}"
  [[ -n "${CLAUDE_JSON_DIR}" && -d "${CLAUDE_JSON_DIR}" ]] && rm -rf "${CLAUDE_JSON_DIR}"
}
trap cleanup EXIT

# Build (cached by embedded Dockerfile hash + UID/GID) unless disabled
if [[ "${NO_BUILD}" -eq 0 ]]; then
  TMPDIR_BUILD="$(mktemp -d)"

  extract_dockerfile > "${TMPDIR_BUILD}/Dockerfile"
  if [[ ! -s "${TMPDIR_BUILD}/Dockerfile" ]]; then
    echo "Failed to extract embedded Dockerfile (marker missing?)" >&2
    exit 2
  fi

  DOCKERFILE_HASH="$(sha256_file "${TMPDIR_BUILD}/Dockerfile")"
  # Include UID/GID in the cache key so a different user triggers a rebuild
  CACHE_KEY="${DOCKERFILE_HASH}:${HOST_UID}:${HOST_GID}"

  existing_hash="$(
    docker image inspect "${IMAGE_NAME}" \
      --format '{{ index .Config.Labels "shellbox.dockerfile_sha256" }}' 2>/dev/null || true
  )"

  if [[ "${REBUILD}" -eq 1 ]] || [[ "${existing_hash}" != "${CACHE_KEY}" ]]; then
    docker build \
      $( (( REBUILD )) && echo "--no-cache" ) \
      --build-arg HOST_UID="${HOST_UID}" \
      --build-arg HOST_GID="${HOST_GID}" \
      --label "shellbox.dockerfile_sha256=${CACHE_KEY}" \
      -t "${IMAGE_NAME}" \
      "${TMPDIR_BUILD}"
  fi
fi

PWD_ABS="$(pwd)"

# Prepare host Claude config for copy into container (MVP / surgical).
# Copy ONLY settings, auth, and user customizations — NOT history, caches,
# projects, sessions, todos, statsig, or the (8MB+) plugins/marketplace dir.
CLAUDE_CONFIG_INCLUDES=(
  ".claude/settings.json"        # global settings
  ".claude/.credentials.json"    # auth token (avoids re-login in the box)
  ".claude/CLAUDE.md"            # global memory / instructions
  ".claude/agents"              # custom subagents
  ".claude/commands"            # custom slash commands
  ".claude/skills"              # custom skills
  ".claude/output-styles"       # custom output styles
)

_tar_items=()
for _item in "${CLAUDE_CONFIG_INCLUDES[@]}"; do
  [[ -e "${HOME}/${_item}" ]] && _tar_items+=("${_item}")
done

# Strip ~/.claude.json down to onboarding/auth keys so Claude doesn't re-run
# onboarding on every start, while dropping per-project history and the pile of
# cached telemetry (statsig/growthbook/tips/...). Needs python3 on the host; if
# it's missing we just skip .claude.json (auth still works via .credentials.json).
if [[ -f "${HOME}/.claude.json" ]] && command -v python3 >/dev/null 2>&1; then
  CLAUDE_JSON_DIR="$(mktemp -d)"
  if ! python3 - "${HOME}/.claude.json" "${CLAUDE_JSON_DIR}/.claude.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
KEEP = {
    "hasCompletedOnboarding", "lastOnboardingVersion",
    "userID", "oauthAccount", "customApiKeyResponses",
    "installMethod", "autoUpdates", "firstStartTime",
    "lastReleaseNotesSeen",
}
try:
    d = json.load(open(src))
except Exception:
    d = {}
# Note: the "trust this folder" entry is injected at container startup by the
# entrypoint (see Dockerfile below), so it works even if the host lacks python3.
json.dump({k: d[k] for k in KEEP if k in d}, open(dst, "w"), indent=2)
PY
  then
    CLAUDE_JSON_DIR=""   # stripping failed; skip it
  fi
fi

# Build the tarball: allowlisted .claude items (rooted at $HOME) plus the
# stripped .claude.json (rooted at its staging dir). Repeated -C is honored by
# both GNU and BSD tar. Entrypoint unpacks this into $HOME on startup.
if (( ${#_tar_items[@]} )) || [[ -n "${CLAUDE_JSON_DIR}" ]]; then
  CLAUDE_CONFIG_TAR="$(mktemp "/tmp/claude-config-XXXXXXXX")"
  _tar_args=( -cf "${CLAUDE_CONFIG_TAR}" )
  (( ${#_tar_items[@]} ))    && _tar_args+=( -C "${HOME}" "${_tar_items[@]}" )
  [[ -n "${CLAUDE_JSON_DIR}" ]] && _tar_args+=( -C "${CLAUDE_JSON_DIR}" ".claude.json" )
  tar "${_tar_args[@]}" 2>/dev/null || CLAUDE_CONFIG_TAR=""
fi

DOCKER_ARGS=(
  run --rm -it
  --user "${HOST_UID}:${HOST_GID}"
  -w "${WORKDIR}"
  -v "${PWD_ABS}:${WORKDIR}"

  # Env vars (incl. TERM, PIP_NO_CACHE_DIR, SHELLBOX_*, and any -e flags) are
  # added below from the ENV_VARS array. Only genuine run flags live here.

  # Light sandboxing (remove --cap-drop ALL if it breaks something you need)
  --cap-drop ALL
  --security-opt no-new-privileges:true
)

# Opt-in gVisor: only add --runtime=runsc if the daemon actually has it
# registered; otherwise warn and fall back to the default runtime.
if [[ "${USE_RUNSC}" -eq 1 ]]; then
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"runsc"'; then
    DOCKER_ARGS+=( --runtime=runsc )
  else
    echo "Warning: --runsc requested but the 'runsc' runtime is not registered with the Docker daemon; continuing without gVisor." >&2
  fi
fi

# Opt-in boxwall: share the boxwall container's network namespace so ALL egress is
# forced through its interactive proxy (see boxwall.sh). Fail-closed: if the boxwall
# isn't running, refuse to start rather than fall back to unfiltered network.
if [[ "${USE_BOXWALL}" -eq 1 ]]; then
  if (( ${#PORTS[@]} )) || (( ${#NETWORKS[@]} )); then
    echo "Error: --boxwall shares the boxwall's network namespace, so -p/--port and -N/--network can't be used with it (publish ports on the boxwall instead)." >&2
    exit 2
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "${BOXWALL_NAME}" 2>/dev/null || true)" != "true" ]]; then
    echo "Error: --boxwall requested but the boxwall netns holder '${BOXWALL_NAME}' is not running." >&2
    echo "Start it in another window first:  ./boxwall/boxwall.sh$( [[ "${BOXWALL_NAME}" != "shellbox-boxwall" ]] && echo " --name ${BOXWALL_NAME}" )" >&2
    exit 2
  fi
  # The holder can be up while the interactive proxy/console is down — in that
  # case egress is fail-closed until you (re)start boxwall.sh. Warn, don't block.
  if [[ "$(docker inspect -f '{{.State.Running}}' "${BOXWALL_NAME}-ctl" 2>/dev/null || true)" != "true" ]]; then
    echo "Warning: boxwall console '${BOXWALL_NAME}-ctl' is not running; egress will be blocked until you run ./boxwall/boxwall.sh." >&2
  fi
  DOCKER_ARGS+=( --network "container:${BOXWALL_NAME}" )
fi

# Mount host Claude config tarball (entrypoint unpacks it to $HOME)
if [[ -n "${CLAUDE_CONFIG_TAR}" && -f "${CLAUDE_CONFIG_TAR}" ]]; then
  DOCKER_ARGS+=( -v "${CLAUDE_CONFIG_TAR}:/tmp/.claude-config.tar:ro" )
fi

# Only set a container name if explicitly requested; otherwise Docker auto-generates a unique name.
if [[ -n "${CONTAINER_NAME}" ]]; then
  DOCKER_ARGS+=( --name "${CONTAINER_NAME}" )
fi

# Extra mounts
if (( ${#EXTRA_MOUNTS[@]} )); then
  for m in "${EXTRA_MOUNTS[@]}"; do
    host="${m%%:*}"
    rest="${m#*:}"   # cont[:mode]
    if [[ "$host" == "$m" ]]; then
      echo "Invalid --volume '$m' (expected HOST:CONTAINER[:ro])" >&2
      exit 2
    fi

    host_abs="$(abs_host_path "$host")"
    [[ -n "${host_abs}" ]] || { echo "Could not resolve host path for mount: $m" >&2; exit 2; }

    DOCKER_ARGS+=( -v "${host_abs}:${rest}" )
  done
fi

# Env vars
if (( ${#ENV_VARS[@]} )); then
  for e in "${ENV_VARS[@]}"; do
    [[ -n "$e" ]] && DOCKER_ARGS+=( -e "$e" )
  done
fi

# Ports
if (( ${#PORTS[@]} )); then
  for p in "${PORTS[@]}"; do
    [[ -n "$p" ]] && DOCKER_ARGS+=( -p "$p" )
  done
fi

# Networks
if (( ${#NETWORKS[@]} )); then
  for net in "${NETWORKS[@]}"; do
    [[ -n "$net" ]] && DOCKER_ARGS+=( --network "$net" )
  done
fi

# Run bash shell, or run provided command
# No exec — EXIT trap must fire to clean up temp files.
if [[ $# -gt 0 ]]; then
  docker "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" bash -lc '"$@"' _ "$@"
else
  docker "${DOCKER_ARGS[@]}" "${IMAGE_NAME}"
fi

# Stop shell from parsing the embedded Dockerfile below
exit $?
__SHELLBOX_DOCKERFILE__
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl wget less \
    vim tmux git openssh-client \
    python3 python3-pip python3-venv \
    build-essential pkg-config \
    ripgrep fd-find nodejs \
    sudo \
  && rm -rf /var/lib/apt/lists/*

# fd on Ubuntu is typically installed as fdfind; add a convenient symlink
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd || true

# Create container user with the host caller's UID/GID
ARG HOST_UID
ARG HOST_GID
ARG USERNAME=dev
RUN set -eux; \
    # Handle GID: reuse existing group or create one \
    existing_group="$(getent group "${HOST_GID}" | cut -d: -f1 || true)"; \
    if [ -n "${existing_group}" ]; then \
      group_name="${existing_group}"; \
    else \
      groupadd -g "${HOST_GID}" "${USERNAME}"; \
      group_name="${USERNAME}"; \
    fi; \
    # Handle UID: if already taken, hijack that user instead of creating a new one \
    existing_user="$(getent passwd "${HOST_UID}" | cut -d: -f1 || true)"; \
    if [ -n "${existing_user}" ]; then \
      usermod -l "${USERNAME}" -d "/home/${USERNAME}" -m -g "${group_name}" -s /bin/bash "${existing_user}"; \
    else \
      useradd -m -u "${HOST_UID}" -g "${group_name}" -s /bin/bash "${USERNAME}"; \
    fi; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"; \
    mkdir -p /home/dev/work; \
    chown -R "${HOST_UID}:${HOST_GID}" /home/dev/work || true

# Helper: pre-accept Claude Code's interactive sandbox dialogs, each gated by an
# env var passed in at runtime (so toggling needs no rebuild). Runs in-container
# (python3 is always present here), so it works even if the host lacked python3.
#   SHELLBOX_TRUST_WORKDIR=1            -> hasTrustDialogAccepted in ~/.claude.json
#   SHELLBOX_ACCEPT_BYPASS_PERMISSIONS=1 -> skipDangerousModePermissionPrompt in
#                                          ~/.claude/settings.json (documented key)
RUN printf '%s\n' \
  'import json, os, sys' \
  'def truthy(v): return str(v).strip().lower() in ("1", "true", "yes", "on")' \
  'def load(p):' \
  '    try:' \
  '        with open(p) as f: return json.load(f)' \
  '    except Exception:' \
  '        return {}' \
  'def save(p, d):' \
  '    os.makedirs(os.path.dirname(p), exist_ok=True)' \
  '    with open(p, "w") as f: json.dump(d, f, indent=2)' \
  'home = os.path.expanduser("~")' \
  'workdir = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()' \
  'if truthy(os.environ.get("SHELLBOX_TRUST_WORKDIR")):' \
  '    p = os.path.join(home, ".claude.json")' \
  '    d = load(p)' \
  '    proj = d.setdefault("projects", {}).setdefault(workdir, {})' \
  '    proj["hasTrustDialogAccepted"] = True' \
  '    proj.setdefault("projectOnboardingSeenCount", 1)' \
  '    save(p, d)' \
  'if truthy(os.environ.get("SHELLBOX_ACCEPT_BYPASS_PERMISSIONS")):' \
  '    p = os.path.join(home, ".claude", "settings.json")' \
  '    s = load(p)' \
  '    s["skipDangerousModePermissionPrompt"] = True' \
  '    save(p, s)' \
  > /usr/local/bin/ensure-claude-config.py

# Entrypoint: copies host Claude config into container on startup, prints summary
RUN printf '%s\n' \
  '#!/bin/bash' \
  'if [ -f /tmp/.claude-config.tar ]; then' \
  '  tar xf /tmp/.claude-config.tar -C "$HOME" 2>/dev/null || true' \
  'fi' \
  'python3 /usr/local/bin/ensure-claude-config.py "$(pwd)" 2>/dev/null || true' \
  'printf "\033[1;36m[shellbox]\033[0m Claude config:\n"' \
  'if [ -d "$HOME/.claude" ]; then' \
  '  printf "  %s/.claude/      (copied from host)\n" "$HOME"' \
  'else' \
  '  printf "  %s/.claude/      -- not found on host\n" "$HOME"' \
  'fi' \
  'if [ -f "$HOME/.claude.json" ]; then' \
  '  printf "  %s/.claude.json  (copied from host)\n" "$HOME"' \
  'else' \
  '  printf "  %s/.claude.json  -- not found on host\n" "$HOME"' \
  'fi' \
  'if [ -d "$(pwd)/.claude" ]; then' \
  '  printf "  %s/.claude/      (mounted from project)\n" "$(pwd)"' \
  'else' \
  '  printf "  %s/.claude/      -- not found in project\n" "$(pwd)"' \
  'fi' \
  'acc=""' \
  'case "${SHELLBOX_TRUST_WORKDIR:-}" in 1|true|yes|on) acc="folder-trust" ;; esac' \
  'case "${SHELLBOX_ACCEPT_BYPASS_PERMISSIONS:-}" in 1|true|yes|on) acc="${acc:+$acc, }bypass-permissions" ;; esac' \
  'if [ -n "$acc" ]; then' \
  '  printf "\033[1;36m[shellbox]\033[0m Auto-accepted dialogs: %s\n" "$acc"' \
  'fi' \
  'exec "$@"' \
  > /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /home/dev/work
USER dev

# Install Claude Code CLI (official method)
RUN curl -fsSL https://claude.ai/install.sh | bash

RUN printf "%s\n" \
  'export PS1="\[\e[1;32m\](shellbox)\[\e[0m\] \u@\h:\w\$ "' \
  'export PIP_DISABLE_PIP_VERSION_CHECK=1' \
  >> ~/.bashrc

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash", "-l"]
