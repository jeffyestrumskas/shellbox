#!/usr/bin/env bash
set -euo pipefail

# Defaults
IMAGE_REPO="shellbox-dev"
PROFILE="default"                 # controls image tag: shellbox-dev:<PROFILE>
WORKDIR="/home/dev/work"

IMAGE_NAME=""                     # set after arg parsing
CONTAINER_NAME=""                 # ONLY set if user passes --container-name
NO_BUILD=0
REBUILD=0

EXTRA_MOUNTS=()
ENV_VARS=()
PORTS=()
NETWORKS=()

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
  -h, --help                                   Show help

Examples:
  ./shellbox.sh
  ./shellbox.sh -n projectA
  ./shellbox.sh -n projectA -v .:/pwd
  ./shellbox.sh -p 8000:8000 -- python3 -m http.server 8000
  ./shellbox.sh --container-name mybox   # fixed name (prevents running two with same name)
  ./shellbox.sh -N sentirail             # join a Docker network (e.g. to reach guard-proxy)
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
cleanup() {
  [[ -n "${TMPDIR_BUILD}" ]] && rm -rf "${TMPDIR_BUILD}"
  [[ -n "${CLAUDE_CONFIG_TAR}" && -f "${CLAUDE_CONFIG_TAR}" ]] && rm -f "${CLAUDE_CONFIG_TAR}"
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

# Prepare host Claude config for copy into container
if [[ -d "${HOME}/.claude" || -f "${HOME}/.claude.json" ]]; then
  CLAUDE_CONFIG_TAR="$(mktemp "/tmp/claude-config-XXXXXXXX")"
  _tar_items=()
  [[ -d "${HOME}/.claude" ]] && _tar_items+=(".claude")
  [[ -f "${HOME}/.claude.json" ]] && _tar_items+=(".claude.json")
  tar -cf "${CLAUDE_CONFIG_TAR}" -C "${HOME}" "${_tar_items[@]}" 2>/dev/null || CLAUDE_CONFIG_TAR=""
fi

DOCKER_ARGS=(
  run --rm -it
  --user "${HOST_UID}:${HOST_GID}"
  -w "${WORKDIR}"
  -v "${PWD_ABS}:${WORKDIR}"
  -e "TERM=${TERM:-xterm-256color}"
  -e "PIP_NO_CACHE_DIR=1"
  -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
  -e "SHELLBOX_HOST_HOME=${HOME}"
  -e "SHELLBOX_HOST_PWD=${PWD_ABS}"

  # Light sandboxing (remove --cap-drop ALL if it breaks something you need)
  --cap-drop ALL
  --security-opt no-new-privileges:true
)

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
    ripgrep fd-find \
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

# Entrypoint: copies host Claude config into container on startup, prints summary
RUN printf '%s\n' \
  '#!/bin/bash' \
  'if [ -f /tmp/.claude-config.tar ]; then' \
  '  tar xf /tmp/.claude-config.tar -C "$HOME" 2>/dev/null || true' \
  'fi' \
  'h="${SHELLBOX_HOST_HOME:-~}"' \
  'w="${SHELLBOX_HOST_PWD:-.}"' \
  'printf "\033[1;36m[shellbox]\033[0m Claude config:\n"' \
  'if [ -d "$HOME/.claude" ]; then' \
  '  printf "  %s/.claude/     -> %s/.claude/      (copied)\n" "$h" "$HOME"' \
  'else' \
  '  printf "  %s/.claude/     -- not found on host\n" "$h"' \
  'fi' \
  'if [ -f "$HOME/.claude.json" ]; then' \
  '  printf "  %s/.claude.json -> %s/.claude.json  (copied)\n" "$h" "$HOME"' \
  'else' \
  '  printf "  %s/.claude.json -- not found on host\n" "$h"' \
  'fi' \
  'if [ -d ".claude" ]; then' \
  '  printf "  %s/.claude/     -> %s/.claude/      (mounted)\n" "$w" "$(pwd)"' \
  'else' \
  '  printf "  %s/.claude/     -- not found in project\n" "$w"' \
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
