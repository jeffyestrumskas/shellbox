#!/usr/bin/env bash
set -euo pipefail

# Defaults
IMAGE_REPO="shellbox-dev"
PROFILE="default"                 # controls image tag: shellbox-dev:<PROFILE>
WORKDIR="/work"

IMAGE_NAME=""                     # set after arg parsing
CONTAINER_NAME=""                 # ONLY set if user passes --container-name
NO_BUILD=0

EXTRA_MOUNTS=()
ENV_VARS=()
PORTS=()
NETWORKS=()

usage() {
  cat <<'EOF'
Usage: ./shellbox.sh [options] [-- command...]

Single-file dev sandbox. The Dockerfile is appended at the end of this script and extracted at build time.
- Mounts the current directory to /work and starts in /work.
- Container is removed on exit (--rm) and auto-named by Docker (unless --container-name is provided).
- Pip cache does NOT persist (PIP_NO_CACHE_DIR=1).
- Images are tagged per profile (shellbox-dev:<profile>).

Options:
  -n, --profile NAME                           Use a per-project image tag (shellbox-dev:NAME)
  -v, --volume HOST_PATH:CONTAINER_PATH[:ro]   Add extra volume mount (repeatable)
  -e, --env KEY=VALUE                          Add env var (repeatable)
  -p, --port HOST_PORT:CONTAINER_PORT          Publish port (repeatable)
  -N, --network NETWORK                        Connect to Docker network (repeatable)
  --container-name NAME                        Set an explicit container name (otherwise Docker auto-names)
  --image IMAGE                                Full image name override (e.g. myrepo:tag). Overrides --profile.
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

# Compute image name default after args:
# - If --image not provided, use IMAGE_REPO:PROFILE
if [[ -z "${IMAGE_NAME}" ]]; then
  IMAGE_NAME="${IMAGE_REPO}:${PROFILE}"
fi

# Build (cached by embedded Dockerfile hash label) unless disabled
if [[ "${NO_BUILD}" -eq 0 ]]; then
  tmpdir="$(mktemp -d)"
  cleanup() { rm -rf "${tmpdir}"; }
  trap cleanup EXIT

  extract_dockerfile > "${tmpdir}/Dockerfile"
  if [[ ! -s "${tmpdir}/Dockerfile" ]]; then
    echo "Failed to extract embedded Dockerfile (marker missing?)" >&2
    exit 2
  fi

  DOCKERFILE_HASH="$(sha256_file "${tmpdir}/Dockerfile")"

  existing_hash="$(
    docker image inspect "${IMAGE_NAME}" \
      --format '{{ index .Config.Labels "shellbox.dockerfile_sha256" }}' 2>/dev/null || true
  )"

  if [[ "${existing_hash}" != "${DOCKERFILE_HASH}" ]]; then
    docker build \
      --label "shellbox.dockerfile_sha256=${DOCKERFILE_HASH}" \
      -t "${IMAGE_NAME}" \
      "${tmpdir}"
  fi
fi

PWD_ABS="$(pwd)"

DOCKER_ARGS=(
  run --rm -it
  -w "${WORKDIR}"
  -v "${PWD_ABS}:${WORKDIR}"
  -e "TERM=${TERM:-xterm-256color}"
  -e "PIP_NO_CACHE_DIR=1"
  -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"

  # Light sandboxing (remove --cap-drop ALL if it breaks something you need)
  --cap-drop ALL
  --security-opt no-new-privileges:true
)

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
if [[ $# -gt 0 ]]; then
  exec docker "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" bash -lc "$*"
else
  exec docker "${DOCKER_ARGS[@]}" "${IMAGE_NAME}"
fi

# IMPORTANT: stop shell parsing before the embedded Dockerfile
exit 0
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
    nodejs npm \
  && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# fd on Ubuntu is typically installed as fdfind; add a convenient symlink
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd || true

ARG USERNAME=dev
ARG USER_UID=1003
ARG USER_GID=1003
RUN set -eux; \
    existing_group="$(getent group "${USER_GID}" | cut -d: -f1 || true)"; \
    if [ -n "${existing_group}" ]; then \
      group_name="${existing_group}"; \
    else \
      groupadd -g "${USER_GID}" "${USERNAME}"; \
      group_name="${USERNAME}"; \
    fi; \
    useradd -m -u "${USER_UID}" -g "${group_name}" -s /bin/bash "${USERNAME}"; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"; \
    mkdir -p /work; \
    chown -R "${USER_UID}:${USER_GID}" /work || true

WORKDIR /work
USER dev

RUN printf "%s\n" \
  'export PS1="\[\e[1;32m\](shellbox)\[\e[0m\] \u@\h:\w\$ "' \
  'export PIP_DISABLE_PIP_VERSION_CHECK=1' \
  >> ~/.bashrc

CMD ["bash", "-l"]
