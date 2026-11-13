#!/usr/bin/env bash
set -euo pipefail

# The whole script is one { ... } block, so bash reads all of it before running
# any of it; editing this file while a box is open can't derail the running copy.
{

# Resolve this script's own directory so --agent can find the agents/ config
# templates that ship next to it, regardless of the caller's CWD (shellbox.sh
# is meant to live in $PATH).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
IMAGE_REPO="shellbox-dev"
PROFILE="default"                 # controls image tag: shellbox-dev:<PROFILE>
WORKDIR="/home/dev/work"

# Claude Code toggles: pre-accept its sandbox dialogs, and privacy (1=on, 0=off).
# Applied to the container's config at startup by the entrypoint helper, so
# toggling these takes effect on the next run with NO rebuild needed.
SHELLBOX_TRUST_WORKDIR=1              # skip the "trust this folder?" dialog
SHELLBOX_ACCEPT_BYPASS_PERMISSIONS=1  # skip the "Bypass Permissions mode" warning
SHELLBOX_SKIP_FULLSCREEN_UPSELL=1     # skip the "try fullscreen mode?" prompt (every fresh box)
SHELLBOX_SKIP_WEBFETCH_PREFLIGHT=1    # don't send WebFetch hostnames to Anthropic's blocklist check

IMAGE_NAME=""                     # set after arg parsing
CONTAINER_NAME=""                 # --container-name, else shellbox-$$ when a helper needs one
NO_BUILD=0
CUSTOM_IMAGE=0                    # 1 with --image (no shellbox entrypoint guaranteed)
REBUILD=0
USE_RUNSC=0                       # opt-in: run under gVisor (--runtime=runsc)
USE_BOXWALL=0                       # opt-in: route egress through the boxwall proxy
BOXWALL_NAME=""                       # boxwall namespace to attach to; required with --boxwall (see boxwall.sh)
ALLOW_INSTALL=0                   # opt-in: relaxed in-box sandbox (see --allow-install below)
PIDS_LIMIT=4096                   # fork-bomb guard (every box)
AGENT="claude"                    # which agent to install (see --agent); default claude when none given
SUPPORTED_AGENTS="claude pi"      # valid values for --agent
USE_BOXWATCH=0                    # opt-in: record activity via the out-of-box boxwatch
BOXWATCH_NAME=""                      # boxwatch to register with; required with --boxwatch (see boxwatch.sh)
ALLOW_LOCAL_HOST=0                # opt-out: --allow-local-host disables the default host-egress block
LOCKDOWN_TIMEOUT=200              # entrypoint gate: N * 0.1s before fail-closed refuse (20s)

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
  "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1"   # not covered by the umbrella

  # pi (PI_OFFLINE is the umbrella; to opt out, `unset` it — any value counts as set)
  "PI_SKIP_VERSION_CHECK=1"
  "PI_TELEMETRY=0"
  "PI_OFFLINE=1"

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
  "SHELLBOX_SKIP_FULLSCREEN_UPSELL=${SHELLBOX_SKIP_FULLSCREEN_UPSELL}"
  "SHELLBOX_SKIP_WEBFETCH_PREFLIGHT=${SHELLBOX_SKIP_WEBFETCH_PREFLIGHT}"
)

# User `-e/--env` flags are appended to this during arg parsing.
ENV_VARS=("${DEFAULT_ENV_VARS[@]}")

# Forward host's Anthropic API key into the sandbox (by name, so the value stays off
# the docker command line). Off by default: Claude uses the copied ~/.claude login.
FORWARD_ANTHROPIC_API_KEY=0
[[ "${FORWARD_ANTHROPIC_API_KEY}" -eq 1 && -n "${ANTHROPIC_API_KEY:-}" ]] && \
  ENV_VARS+=( "ANTHROPIC_API_KEY" )

# pi boxes: model-provider settings forwarded when set (export them in your shell rc).
# Ollama (Cloud, or a LAN server at OLLAMA_LAN_URL) and Venice models come from the
# bundled agents/pi/extensions; OpenRouter is built into pi. The default model is the first entry whose <PROVIDER>_API_KEY is
# set, unless your pi settings already name one (OpenRouter: pi picks its own).
PI_FORWARD_ENV=( OLLAMA_API_KEY OLLAMA_LAN_URL VENICE_API_KEY OPENROUTER_API_KEY )
PI_DEFAULT_MODELS="ollama/deepseek-v4-pro:0813 venice/deepseek-v4-pro-0813"

# Grab host UID/GID once
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

usage() {
  cat <<'EOF'
Usage: ./shellbox.sh [options] [-- command...]

Single-file dev sandbox: mounts the current dir to /home/dev/work as the host
UID/GID, runs Claude Code by default, and removes the container on exit.

Options:
  -n, --profile NAME        Per-project image tag (shellbox-dev:NAME)
  -v, --volume SRC:DST[:ro] Extra volume mount (repeatable); a bare SRC name is a
                            named Docker volume, ./SRC a local dir
  -e, --env KEY[=VALUE]     Extra env var (repeatable); a bare KEY forwards the value
                            from the host without putting it on the docker command line
  -p, --port HOST:CONTAINER Publish a port (repeatable)
  -N, --network NAME        Connect to a Docker network (repeatable)
  --container-name NAME     Explicit container name
  --image IMAGE             Full image override; takes precedence over --profile
  --rebuild                 Clean rebuild with a fresh base image and agent
  --no-build                Skip build; assume the image exists
  -h, --help                Show help

Security / isolation:
  --allow-local-host        Let the box reach services on the host (blocked by
                            default; no effect under --boxwall).
  --allow-install           Let the agent sudo/apt-install and run freely INSIDE the
                            box (it still cannot escape to the host).
  --boxwall NAME            Route all egress through the running boxwall NAME
                            (interactive firewall). --boxwall-name NAME is the same.
  --runsc                   Run under gVisor if the runsc runtime is registered.
                            Conflicts with --boxwall and --boxwatch.
  --boxwatch NAME           Record file/network/process activity via the running
                            boxwatch NAME (out-of-box eBPF). --boxwatch-name NAME is
                            the same.

Agents:
  --agent NAME              Agent to install: claude (default) or pi. Uses the host
                            config (~/.claude or ~/.pi/agent).

Examples:
  ./shellbox.sh                                      # Claude Code in the current dir
  ./shellbox.sh --agent pi                           # pi (pi.dev) instead of Claude Code
  ./shellbox.sh -n projectA -p 8000:8000             # named profile, publish a port
  ./shellbox.sh -- python3 -m http.server 8000       # run a one-off command
  ./shellbox.sh --allow-install --boxwall proj-a     # autonomous agent, egress gated
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

# True if container $1 is running and is a shellbox $2 (labelled shellbox.role=$2, or
# an unlabelled one from before labels that runs image $3), so a same-named
# container of another kind is never mistaken for it.
service_up() {
  local info
  info="$(docker container inspect -f '{{.State.Running}}|{{index .Config.Labels "shellbox.role"}}|{{.Config.Image}}' "$1" 2>/dev/null)" || return 1
  case "$info" in
    "true|$2|"*|"true||$3:"*|"true|<no value>|$3:"*) return 0 ;;
  esac
  return 1
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
      CUSTOM_IMAGE=1
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
    --boxwall|--boxwall-name)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || {
        echo "Error: $1 needs the boxwall's NAME, e.g. $1 proj-a (start it with ./boxwall/boxwall.sh --name proj-a)." >&2
        exit 2; }
      BOXWALL_NAME="$2"
      USE_BOXWALL=1
      shift 2
      ;;
    --allow-install)
      ALLOW_INSTALL=1
      shift
      ;;
    --agent)
      [[ $# -ge 2 ]] || { echo "Missing argument for $1 (expected one of: ${SUPPORTED_AGENTS})" >&2; exit 2; }
      AGENT="$2"
      case " ${SUPPORTED_AGENTS} " in
        *" ${AGENT} "*) ;;
        *) echo "Error: unknown --agent '${AGENT}'. Supported: ${SUPPORTED_AGENTS}." >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --boxwatch|--boxwatch-name)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || {
        echo "Error: $1 needs the boxwatch's NAME, e.g. $1 proj-a (start it with ./boxwatch/boxwatch.sh --name proj-a)." >&2
        exit 2; }
      BOXWATCH_NAME="$2"
      USE_BOXWATCH=1
      shift 2
      ;;
    --allow-local-host)
      ALLOW_LOCAL_HOST=1
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
    -*)
      echo "Unknown option: $1 (see --help)" >&2
      exit 2
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

# --boxwatch records via host-kernel eBPF, which can't see syscalls a gVisor sandbox
# makes (they're serviced by the runsc sentry in userspace), so the watcher would
# go blind. Refuse the combination rather than record nothing.
if [[ "${USE_BOXWATCH}" -eq 1 && "${USE_RUNSC}" -eq 1 ]]; then
  echo "Error: --boxwatch (host eBPF) can't observe syscalls under gVisor; --boxwatch and --runsc are mutually exclusive." >&2
  exit 2
fi

# Host-egress block (default ON): keep a rogue agent inside the box from reaching
# services bound to the host (host.docker.internal & the Docker Desktop host range).
# Implemented by a transient NET_ADMIN helper that injects iptables DROP rules into
# the box's netns after start; the box keeps --cap-drop ALL so it can't undo them.
# Disabled when:
#   --allow-local-host : the operator explicitly wants host access.
#   --boxwall    : boxwall already default-denies ALL egress (host included).
#   --runsc      : gVisor runs its own userspace netstack, which sends packets past
#                  iptables, so neither this block nor boxwall can gate it.
LOCKDOWN=1
if [[ "${ALLOW_LOCAL_HOST}" -eq 1 ]]; then
  LOCKDOWN=0
elif [[ "${USE_BOXWALL}" -eq 1 ]]; then
  LOCKDOWN=0
elif [[ "${USE_RUNSC}" -eq 1 ]]; then
  echo "Warning: the host-egress block can't be applied under gVisor (--runsc): its network stack bypasses iptables. Pass --allow-local-host to silence this." >&2
  LOCKDOWN=0
fi

# Compute image name default after args:
# - If --image not provided, use IMAGE_REPO:PROFILE
# - claude (the default agent) keeps the lean ":PROFILE" tag; pi appends "-pi" so
#   it's a distinct, separately-cached image.
if [[ -z "${IMAGE_NAME}" ]]; then
  _agent_tag=""
  [[ "${AGENT}" != "claude" ]] && _agent_tag="-${AGENT}"
  IMAGE_NAME="${IMAGE_REPO}:${PROFILE}${_agent_tag}"
fi

# --boxwatch needs a deterministic container name so the out-of-box watcher can map
# this sandbox to its cgroup. Give it one if the user didn't (PID keeps it unique
# across concurrent watched sandboxes).
if [[ "${USE_BOXWATCH}" -eq 1 && -z "${CONTAINER_NAME}" ]]; then
  CONTAINER_NAME="shellbox-watched-$$"
fi

# The host-egress block helper must address this box by a stable name to join its
# netns, so give it one if the user didn't (PID keeps it unique across concurrent boxes).
if [[ "${LOCKDOWN}" -eq 1 && -z "${CONTAINER_NAME}" ]]; then
  CONTAINER_NAME="shellbox-$$"
fi

PWD_ABS="$(pwd)"

# Sanity checks, all before the (possibly slow) build.
# Never bind-mount your whole home dir (~/.ssh, ~/.aws, ...) or / into the box.
if [[ "${HOME%/}/" == "${PWD_ABS%/}/"* ]]; then
  echo "Error: refusing to mount ${PWD_ABS} into the box (it would expose ~/.ssh, ~/.aws, ...); cd into a project dir." >&2
  exit 2
fi
# --boxwall shares the boxwall's netns, so -p/-N can't apply; and gVisor's userspace
# network stack sends packets past boxwall's iptables rules, so it can't gate runsc.
if [[ "${USE_BOXWALL}" -eq 1 ]]; then
  if (( ${#PORTS[@]} )) || (( ${#NETWORKS[@]} )); then
    echo "Error: --boxwall shares the boxwall's network namespace, so -p/--port and -N/--network can't be used with it." >&2
    exit 2
  fi
  if [[ "${USE_RUNSC}" -eq 1 ]]; then
    echo "Error: --runsc can't be combined with --boxwall: gVisor's network stack bypasses boxwall's iptables rules." >&2
    exit 2
  fi
fi
# The host-egress helper joins the box's netns; with -N host or container:X that's
# another namespace, whose firewall it would rewrite (and never clean up).
if [[ "${LOCKDOWN}" -eq 1 ]] && (( ${#NETWORKS[@]} )); then
  for _net in "${NETWORKS[@]}"; do
    case "${_net}" in host|container:*)
      echo "Error: -N ${_net} shares another network namespace, so the host-egress block can't be applied safely; add --allow-local-host to run without it." >&2
      exit 2 ;;
    esac
  done
fi
if [[ "${LOCKDOWN}" -eq 1 && "${CUSTOM_IMAGE}" -eq 1 ]]; then
  echo "Warning: --image: the host-egress block is only fail-closed with shellbox's own entrypoint; another image may start before it's applied." >&2
fi
# The helpers find the box by name, so an existing container with that name would be
# the one they act on (and `docker run` would fail anyway).
if [[ -n "${CONTAINER_NAME}" ]] && docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "Error: a container named '${CONTAINER_NAME}' already exists; remove it or pick another --container-name." >&2
  exit 2
fi
# Both --boxwall and --boxwatch are fail-closed: each depends on a helper that must
# already be running in its own window. If any is down, print the command to start it.
_missing=()
# boxwall counts as running only with both its netns holder and its console up.
if [[ "${USE_BOXWALL}" -eq 1 ]] && ! { service_up "${BOXWALL_NAME}" boxwall shellbox-boxwall \
     && service_up "${BOXWALL_NAME}-ctl" boxwall-ctl shellbox-boxwall; }; then
  _missing+=( "boxwall '${BOXWALL_NAME}' is not running. Start it in another window with:"$'\n'"      ./boxwall/boxwall.sh --name ${BOXWALL_NAME}" )
fi
if [[ "${USE_BOXWATCH}" -eq 1 ]] && ! service_up "${BOXWATCH_NAME}-watch" boxwatch shellbox-boxwatch; then
  _missing+=( "boxwatch '${BOXWATCH_NAME}' is not running. Start it in another window with:"$'\n'"      ./boxwatch/boxwatch.sh --name ${BOXWATCH_NAME}" )
fi
if (( ${#_missing[@]} )); then
  echo "Error: required service(s) not running:" >&2
  for _m in "${_missing[@]}"; do
    printf '  - %s\n' "${_m}" >&2
  done
  exit 2
fi
# Each boxwatch keeps its logs and target registrations in its own dir.
WATCH_DIR="${HOME}/.shellbox/watch/${BOXWATCH_NAME}"
# The watcher's integrity rests on the box NOT being able to write to WATCH_DIR
# (where target registrations live), so it must sit outside the bind-mounted workdir.
if [[ "${USE_BOXWATCH}" -eq 1 ]]; then
  mkdir -p "${WATCH_DIR}/targets"   # must exist to resolve its real path
  _watch_abs="$(abs_host_path "${WATCH_DIR}")"
  case "${_watch_abs%/}/" in
    "${PWD_ABS%/}/"*)
      echo "Error: --boxwatch dir (${_watch_abs}) is inside the bind-mounted workdir (${PWD_ABS}); the box could tamper with its own watcher." >&2
      echo "Point boxwatch at a dir outside this tree (boxwatch.sh --watch-dir ...) or run shellbox from elsewhere." >&2
      exit 2 ;;
  esac
fi

# Cleanup handler for temp files (runs on EXIT now that we don't exec)
TMPDIR_BUILD=""
CLAUDE_CONFIG_TAR=""
CLAUDE_JSON_DIR=""
PI_CONFIG_TAR=""
WATCH_TARGET_FILE=""
LOCKDOWN_GATE_DIR=""
cleanup() {
  # Stop any still-running background helper first, so none writes after cleanup.
  local live; live="$(jobs -p)"
  if [[ -n "${live}" ]]; then
    kill ${live} 2>/dev/null || true
    wait 2>/dev/null || true
  fi
  [[ -n "${TMPDIR_BUILD}" ]] && rm -rf "${TMPDIR_BUILD}"
  [[ -n "${CLAUDE_CONFIG_TAR}" && -f "${CLAUDE_CONFIG_TAR}" ]] && rm -f "${CLAUDE_CONFIG_TAR}"
  [[ -n "${CLAUDE_JSON_DIR}" && -d "${CLAUDE_JSON_DIR}" ]] && rm -rf "${CLAUDE_JSON_DIR}"
  [[ -n "${PI_CONFIG_TAR}" && -f "${PI_CONFIG_TAR}" ]] && rm -f "${PI_CONFIG_TAR}"
  # Deregister from the watcher so it stops scoping probes to a dead cgroup.
  [[ -n "${WATCH_TARGET_FILE}" && -f "${WATCH_TARGET_FILE}" ]] && rm -f "${WATCH_TARGET_FILE}"
  [[ -n "${LOCKDOWN_GATE_DIR}" && -d "${LOCKDOWN_GATE_DIR}" ]] && rm -rf "${LOCKDOWN_GATE_DIR}"
  return 0   # a skipped check above must not replace the script's exit status
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
  # Include UID/GID and the selected agent in the cache key so a different user
  # or a different --agent triggers a rebuild (the agent is a build-arg, so the
  # Dockerfile text alone doesn't capture it).
  CACHE_KEY="${DOCKERFILE_HASH}:${HOST_UID}:${HOST_GID}:agent=${AGENT}"

  existing_hash="$(
    docker image inspect "${IMAGE_NAME}" \
      --format '{{ index .Config.Labels "shellbox.dockerfile_sha256" }}' 2>/dev/null || true
  )"

  if [[ "${REBUILD}" -eq 1 ]] || [[ "${existing_hash}" != "${CACHE_KEY}" ]]; then
    docker build \
      $( (( REBUILD )) && echo "--no-cache --pull" ) \
      --build-arg HOST_UID="${HOST_UID}" \
      --build-arg HOST_GID="${HOST_GID}" \
      --build-arg AGENT="${AGENT}" \
      --label "shellbox.dockerfile_sha256=${CACHE_KEY}" \
      -t "${IMAGE_NAME}" \
      "${TMPDIR_BUILD}"
  fi
fi

# Prepare host Claude config for copy into container (MVP / surgical).
# Only for --agent claude: other agents don't install Claude, so they get none of it.
if [[ "${AGENT}" == "claude" ]]; then
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
      rm -rf "${CLAUDE_JSON_DIR}"; CLAUDE_JSON_DIR=""   # stripping failed; skip it
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
    # COPYFILE_DISABLE: stop macOS bsdtar adding AppleDouble ._* entries.
    if ! COPYFILE_DISABLE=1 tar "${_tar_args[@]}"; then
      echo "Warning: couldn't copy your Claude config into the box (see tar error above)." >&2
      rm -f "${CLAUDE_CONFIG_TAR}"; CLAUDE_CONFIG_TAR=""
    fi
  fi
fi

# Prepare host pi config (--agent pi only), same allowlist approach as Claude:
# settings, auth, models, and customizations — NOT sessions or pi's own install.
if [[ "${AGENT}" == "pi" ]]; then
  PI_HOST_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
  PI_CONFIG_INCLUDES=(
    "settings.json" "auth.json" "models.json" "mcp.json" "keybindings.json"
    "AGENTS.md" "AGENTS.override.md" "CLAUDE.md" "SYSTEM.md" "APPEND_SYSTEM.md"
    "extensions" "skills" "prompts" "themes"
  )
  _pi_items=()
  for _item in "${PI_CONFIG_INCLUDES[@]}"; do
    [[ -e "${PI_HOST_DIR}/${_item}" ]] && _pi_items+=("${_item}")
  done
  if (( ${#_pi_items[@]} )); then
    PI_CONFIG_TAR="$(mktemp "/tmp/pi-config-XXXXXXXX")"
    if ! COPYFILE_DISABLE=1 tar -cf "${PI_CONFIG_TAR}" -C "${PI_HOST_DIR}" "${_pi_items[@]}"; then
      echo "Warning: couldn't copy your pi config into the box (see tar error above)." >&2
      rm -f "${PI_CONFIG_TAR}"; PI_CONFIG_TAR=""
    fi
  fi
fi

DOCKER_ARGS=(
  run --rm -i
  --user "${HOST_UID}:${HOST_GID}"
  -w "${WORKDIR}"
  -v "${PWD_ABS}:${WORKDIR}"

  # Env vars (incl. TERM, PIP_NO_CACHE_DIR, SHELLBOX_*, and any -e flags) are
  # added below from the ENV_VARS array. Only genuine run flags live here.
  --pids-limit "${PIDS_LIMIT}"
)
[[ -t 0 && -t 1 ]] && DOCKER_ARGS+=( -t )   # pipes and CI have no terminal

# Sandbox hardening posture.
#
# Strict (default): drop ALL Linux capabilities and forbid privilege escalation.
# Ideal for "just let Claude read and run my code" — but it also blocks system
# package installs, because sudo/apt can no longer elevate.
#
# --allow-install: loosen the *in-container* restrictions just enough that an
# autonomous agent can install software and do real work, WITHOUT handing it any
# new reach over the host. We keep Docker's DEFAULT capability set and DEFAULT
# seccomp profile — both designed to prevent container->host escape — and leave
# no-new-privileges off so `sudo apt-get install ...` works. The container's only
# persistent effect on the host
# stays exactly what it was: outbound network + writes to the bind-mounted
# workdir. We still run as your host UID, so files the agent creates in the
# workdir remain host-owned (sudo grants in-container root only when needed).
if [[ "${ALLOW_INSTALL}" -eq 1 ]]; then
  # No --cap-drop ALL and no no-new-privileges here, on purpose: that's what lets
  # the agent install software. Host isolation is preserved by NOT adding any of the
  # dangerous escapes (--privileged, docker socket, host mounts, --pid=host, ...).
  #
  # BUT we still strip the two network-admin caps from the default set:
  #   NET_RAW   - with it the box can open an AF_PACKET/SOCK_RAW socket and inject
  #               raw L2 frames straight to the wire. AF_PACKET TX goes
  #               dev_queue_xmit and NEVER traverses netfilter's LOCAL_OUT hook, so
  #               it sidesteps boxwall's entire iptables OUTPUT egress filter AND
  #               produces no connect() for boxwatch to see. boxwall's threat model
  #               (boxwall/README.md) assumes the box can't do this.
  #   NET_ADMIN - lets the box rewrite iptables / set SO_MARK (forge the proxy's
  #               fwmark exemption) in the shared netns. Not in Docker's default set
  #               today, dropped here belt-and-braces so a default change can't
  #               silently re-open it.
  # apt/sudo/dpkg need neither, so installs still work.
  DOCKER_ARGS+=(
    --cap-drop NET_RAW
    --cap-drop NET_ADMIN
  )
else
  # Light sandboxing (remove --cap-drop ALL if it breaks something you need)
  DOCKER_ARGS+=(
    --cap-drop ALL
    --security-opt no-new-privileges:true
  )
fi

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
# forced through its interactive proxy (see boxwall.sh). Checked running above.
if [[ "${USE_BOXWALL}" -eq 1 ]]; then
  DOCKER_ARGS+=( --network "container:${BOXWALL_NAME}" )
fi

# Host-egress block: the entrypoint blocks until a background helper (below) confirms
# the DROP rules are in place, then fails closed if they never land. The gate dir lives
# INSIDE the box at /run/shellbox-gate and is populated by the helper via `docker exec`
# as root — NOT a host bind mount. (A host `mktemp -d` bind mount is unreliable on
# Docker Desktop: if the temp path isn't in File Sharing the mount appears EMPTY in the
# box, so the host-written sentinel/log are never visible and the gate always times out.)
# The box runs as a non-root user with cap-drop ALL and can't write to /run, so it still
# can't forge the `ready` sentinel.
if [[ "${LOCKDOWN}" -eq 1 ]]; then
  DOCKER_ARGS+=(
    -e "SHELLBOX_LOCKDOWN_GATE=/run/shellbox-gate/ready"
    -e "SHELLBOX_LOCKDOWN_TIMEOUT=${LOCKDOWN_TIMEOUT}"
  )
fi

# Mount host Claude config tarball (entrypoint unpacks it to $HOME)
if [[ -n "${CLAUDE_CONFIG_TAR}" && -f "${CLAUDE_CONFIG_TAR}" ]]; then
  DOCKER_ARGS+=( -v "${CLAUDE_CONFIG_TAR}:/tmp/.claude-config.tar:ro" )
fi

# Tell the entrypoint which agent this box has, so it only sets up that agent.
DOCKER_ARGS+=( -e "SHELLBOX_BOX_AGENT=${AGENT}" )

# pi boxes: host config tarball, forwarded env vars (by name, so values stay off the
# docker command line; an explicit -e still wins), and the bundled extensions.
if [[ "${AGENT}" == "pi" ]]; then
  [[ -n "${PI_CONFIG_TAR}" ]] && DOCKER_ARGS+=( -v "${PI_CONFIG_TAR}:/tmp/.pi-config.tar:ro" )
  for _var in "${PI_FORWARD_ENV[@]}"; do
    [[ -n "${!_var:-}" ]] && DOCKER_ARGS+=( -e "${_var}" )
  done
  _pi_ext="${SCRIPT_DIR}/agents/pi/extensions"
  [[ -d "${_pi_ext}" ]] && DOCKER_ARGS+=( -v "${_pi_ext}:/run/shellbox-pi-extensions:ro" )
  DOCKER_ARGS+=( -e "SHELLBOX_PI_DEFAULT_MODELS=${PI_DEFAULT_MODELS}" )
fi

# Name the box if one was given or a helper needs it (above); else Docker picks one.
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

    # A bare name (no "/", not starting with "." or "~") is a named Docker volume.
    case "$host" in
      */*|.*|\~*) host_abs="$(abs_host_path "$host")" ;;
      *)         host_abs="$host" ;;
    esac
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

# --allow-install banner: make the relaxed-inside / locked-to-host trade explicit.
if [[ "${ALLOW_INSTALL}" -eq 1 ]]; then
  printf '\033[1;33m[shellbox:install]\033[0m install mode — the agent can install software and run freely INSIDE this box.\n' >&2
  printf '  host isolation kept: no privileged, no docker socket, no host mounts beyond the workdir; default caps minus NET_RAW/NET_ADMIN + seccomp.\n' >&2
  printf '  only host effects: outbound network%s and writes to the bind mount (%s).\n' \
    "$( [[ "${USE_BOXWALL}" -eq 1 ]] && echo " (gated by boxwall)" )" "${PWD_ABS}" >&2
  printf '  pids-limit=%s%s\n' "${PIDS_LIMIT}" "$( [[ "${USE_RUNSC}" -eq 1 ]] && echo ", gVisor on" )" >&2
fi

# Watch registrar: the container doesn't exist until `docker run` below, so spawn
# a background helper that waits for it to appear, then records its id where the
# out-of-box watcher will pick it up and scope its eBPF probes to this cgroup. The
# EXIT trap removes the registration when the box stops.
if [[ "${USE_BOXWATCH}" -eq 1 ]]; then
  mkdir -p "${WATCH_DIR}/targets"
  WATCH_TARGET_FILE="${WATCH_DIR}/targets/${CONTAINER_NAME}.json"
  (
    for _ in $(seq 1 100); do
      cid="$(docker container inspect -f '{{.Id}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
      if [[ -n "${cid}" ]]; then
        printf '{"name":"%s","id":"%s"}\n' "${CONTAINER_NAME}" "${cid}" > "${WATCH_TARGET_FILE}"
        break
      fi
      sleep 0.2
    done
  ) &

  printf '\033[1;36m[shellbox:watch]\033[0m activity capture ON via out-of-box watcher %s.\n' "${BOXWATCH_NAME}" >&2
  printf '  file / network / process events -> %s (this box cannot see or disable it).\n' "${WATCH_DIR}" >&2
fi

# Host-egress block helper: the box's netns doesn't exist until `docker run` below,
# so spawn a background helper that waits for the box to be running, joins its netns
# with NET_ADMIN, and installs DROP rules for the host-local ranges — then unblocks the
# entrypoint (which is waiting) by writing <gate>/ready. The box itself keeps
# --cap-drop ALL, so it can never see this helper or remove the rules it leaves behind.
# Fail-closed: if the helper can't apply the rules, no sentinel is written and the
# entrypoint refuses to start the shell.
if [[ "${LOCKDOWN}" -eq 1 ]]; then
  # Runs INSIDE the box's network namespace (via --network container:), as root with
  # NET_ADMIN. Strategy, ordered safest-first:
  #   1. Drop every resolved address (IPv4 via iptables, IPv6 via ip6tables) of the
  #      Docker Desktop host aliases (host.docker.internal=.254,
  #      gateway.docker.internal=.1) — but NEVER the default gateway, which is our route
  #      to the internet (and on plain Linux the host itself IS the gateway). This alone
  #      blocks every host path we demonstrated, and can't touch DNS.
  #   2. Defense-in-depth: only if the resolver sits in the Docker Desktop host range,
  #      ACCEPT it explicitly and then drop the rest of 192.168.65.0/24. Gated on the
  #      carve-out so the blanket can never blackhole the box's own DNS.
  #   3. Drop link-local (incl. cloud metadata 169.254.169.254).
  # Pure bash + getent/grep/cut/sort (no iproute2); harmless on hosts without that range.
  # Every iptables call uses `-w 5` (wait up to 5s for the xtables lock) so it can't
  # fail just because the daemon is mid-flight on its own netfilter changes. Each step
  # echoes what it's doing: the helper captures this into <gate>/log, which the box
  # surfaces (read-only) if the gate ever times out — so a failure is never silent.
  LOCKDOWN_SCRIPT='set -eu
gwip=""
while read -r _if dest gw _rest; do
  [ "$dest" = "00000000" ] || continue
  gwip=$(printf "%d.%d.%d.%d" "0x${gw:6:2}" "0x${gw:4:2}" "0x${gw:2:2}" "0x${gw:0:2}")
  break
done < /proc/net/route
echo "default gateway: ${gwip:-<none>}"
for name in host.docker.internal gateway.docker.internal; do
  hips=$(getent ahosts "$name" 2>/dev/null | cut -d" " -f1 | sort -u || true)
  [ -z "$hips" ] && { echo "skip $name (unresolved)"; continue; }
  for hip in $hips; do
    [ "$hip" = "$gwip" ] && { echo "skip $name=$hip (is default gateway)"; continue; }
    echo "drop $name=$hip"
    case "$hip" in
      *:*) ip6tables -w 5 -A OUTPUT -d "$hip" -j DROP ;;
      *)   iptables -w 5 -A OUTPUT -d "$hip" -j DROP ;;
    esac
  done
done
dns=$(grep -m1 "^nameserver" /etc/resolv.conf 2>/dev/null | cut -d" " -f2 || true)
case "$dns" in
  192.168.65.*)
    echo "accept dns $dns; drop rest of 192.168.65.0/24"
    iptables -w 5 -I OUTPUT 1 -d "$dns" -j ACCEPT
    iptables -w 5 -A OUTPUT -d 192.168.65.0/24 -j DROP
    ;;
  *) echo "dns ${dns:-<none>} outside docker-desktop host range; leaving 192.168.65.0/24 alone" ;;
esac
iptables -w 5 -A OUTPUT -d 169.254.0.0/16 -j DROP
echo "host-egress DROP rules installed"'
  (
    # Stage the helper log on the HOST, then push it into the box's own filesystem with
    # `docker exec` (no bind mount involved). The box reads /run/shellbox-gate/log and
    # prints it if the gate times out; the WAIT phase is logged too, so "container never
    # went running" is distinguishable from "sidecar failed".
    _log="$(mktemp)"
    trap 'rm -f "${_log}"' EXIT
    echo "helper: waiting for container '${CONTAINER_NAME}' to report running" > "${_log}"
    _state=""
    for _ in $(seq 1 200); do
      _state="$(docker container inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>>"${_log}" || true)"
      [[ "${_state}" == "running" ]] && break
      sleep 0.1
    done
    echo "after wait: container state='${_state:-<empty>}'" >> "${_log}"
    if [[ "${_state}" != "running" ]]; then
      echo "FAILED: container '${CONTAINER_NAME}' never reached 'running'. The sidecar was not run." >> "${_log}"
    fi

    # Apply the DROP rules in the box's netns, retrying a few times so a transient
    # daemon/iptables hiccup doesn't strand us fail-closed.
    _ok=0
    if [[ "${_state}" == "running" ]]; then
      for _attempt in 1 2 3; do
        echo "=== host-egress block: attempt ${_attempt} ===" >> "${_log}"
        if docker run --rm \
             --cap-add NET_ADMIN --cap-add NET_RAW --user 0:0 \
             --network "container:${CONTAINER_NAME}" \
             --entrypoint /bin/bash \
             "${IMAGE_NAME}" -c "${LOCKDOWN_SCRIPT}" >> "${_log}" 2>&1; then
          _ok=1; break
        fi
        sleep 0.5
      done
    fi

    # Publish the log into the box (best-effort) and, only on a clean apply, the `ready`
    # sentinel. Both go through `docker exec` as root: /run is root-owned, so the box's
    # own non-root user (cap-drop ALL) can neither read a stale gate nor forge `ready`.
    docker exec -i --user 0:0 "${CONTAINER_NAME}" \
      /bin/sh -c 'mkdir -p /run/shellbox-gate && cat > /run/shellbox-gate/log && chmod 644 /run/shellbox-gate/log' \
      < "${_log}" >/dev/null 2>&1 || true
    if [[ "${_ok}" -eq 1 ]]; then
      docker exec --user 0:0 "${CONTAINER_NAME}" \
        /bin/sh -c ': > /run/shellbox-gate/ready' >/dev/null 2>&1 || true
    fi
    rm -f "${_log}"
  ) &

  printf '\033[1;36m[shellbox:lock]\033[0m host-egress block ON — the box cannot reach host-local services (host.docker.internal et al.).\n' >&2
  printf '  DNS, gateway, and general internet stay up. Opt out with --allow-local-host.\n' >&2
fi

# Run bash shell, or run provided command
# No exec — EXIT trap must fire to clean up temp files.
# Note: the agent never auto-launches; you always land in a shell (or run the
# command you passed) and start the agent yourself.
if [[ $# -gt 0 ]]; then
  docker "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" bash -lc '"$@"' _ "$@"
else
  docker "${DOCKER_ARGS[@]}" "${IMAGE_NAME}"
fi

# Stop shell from parsing the embedded Dockerfile below
exit $?
}
__SHELLBOX_DOCKERFILE__
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Selected agent (claude|pi); "none" only for a raw docker build that
# passes no build-arg (shellbox always passes one, defaulting to claude). Declared
# once for the whole stage so every RUN below can branch on it; folded into
# shellbox's image tag + cache key so agent images are distinct and cached.
ARG AGENT=none

# apt over HTTPS: the base image ships http:// sources and no CA store, so install
# just ca-certificates over the default http:// first (apt still verifies it against
# Ubuntu's signed archive index; http only reveals which package was fetched), then
# switch the sources to https:// for everything else.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
  && sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources \
  && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl wget less \
    vim tmux git openssh-client \
    python3 python3-pip python3-venv \
    build-essential pkg-config \
    ripgrep fd-find nodejs \
    sudo iptables \
  && rm -rf /var/lib/apt/lists/*

# fd on Ubuntu is typically installed as fdfind; add a convenient symlink
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd || true

# pi (--agent pi) needs Node >= 22.19, newer than Ubuntu 24.04's apt nodejs (18).
# Install the latest official Node 22 build into /usr/local (ahead of /usr/bin on
# PATH), checked against nodejs.org's SHASUMS256.txt (catches a corrupt download;
# same origin, so not a signature). Other agents skip it.
RUN set -eux; if [ "${AGENT}" = pi ]; then \
      case "$(dpkg --print-architecture)" in \
        amd64) node_arch=x64 ;; arm64) node_arch=arm64 ;; \
        *) echo "unsupported arch for Node: $(dpkg --print-architecture)" >&2; exit 1 ;; \
      esac; \
      base=https://nodejs.org/dist/latest-v22.x; \
      cd /tmp; \
      curl -fsSLO "${base}/SHASUMS256.txt"; \
      tarball="$(grep -oE "node-v[0-9.]+-linux-${node_arch}\.tar\.gz$" SHASUMS256.txt | head -n1)"; \
      curl -fsSLO "${base}/${tarball}"; \
      grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c -; \
      tar -xzf "${tarball}" -C /usr/local --strip-components=1 --no-same-owner; \
      rm -f "${tarball}" SHASUMS256.txt; \
      node --version; npm --version; \
    fi

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

# Helper: apply the Claude Code toggles above, each gated by an
# env var passed in at runtime (so toggling needs no rebuild). Runs in-container
# (python3 is always present here), so it works even if the host lacked python3.
#   SHELLBOX_TRUST_WORKDIR=1            -> hasTrustDialogAccepted in ~/.claude.json
#   SHELLBOX_ACCEPT_BYPASS_PERMISSIONS=1 -> skipDangerousModePermissionPrompt in
#                                          ~/.claude/settings.json (documented key)
#   SHELLBOX_SKIP_FULLSCREEN_UPSELL=1    -> fullscreenUpsellSeenCount=3 in ~/.claude.json
#                                          (Claude stops asking after 3 impressions)
#   SHELLBOX_SKIP_WEBFETCH_PREFLIGHT=1   -> skipWebFetchPreflight in ~/.claude/settings.json
#                                          (no hostname check against Anthropic's blocklist)
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
  'p = os.path.join(home, ".claude", "settings.json")' \
  'for var, key in (("SHELLBOX_ACCEPT_BYPASS_PERMISSIONS", "skipDangerousModePermissionPrompt"),' \
  '                 ("SHELLBOX_SKIP_WEBFETCH_PREFLIGHT", "skipWebFetchPreflight")):' \
  '    if truthy(os.environ.get(var)):' \
  '        s = load(p)' \
  '        s[key] = True' \
  '        save(p, s)' \
  'if truthy(os.environ.get("SHELLBOX_SKIP_FULLSCREEN_UPSELL")):' \
  '    p = os.path.join(home, ".claude.json")' \
  '    d = load(p)' \
  '    d["fullscreenUpsellSeenCount"] = max(int(d.get("fullscreenUpsellSeenCount") or 0), 3)' \
  '    save(p, d)' \
  > /usr/local/bin/ensure-claude-config.py

# Helper: tidy pi's config at startup.
#   - A blank models.json or settings.json (e.g. emptied on the host) is a parse
#     error in pi, so each becomes a valid empty config.
#   - The first SHELLBOX_PI_DEFAULT_MODELS entry ("provider/id") whose
#     <PROVIDER>_API_KEY is set becomes the default model, unless the settings
#     already name one. Unreadable files are left alone.
RUN printf '%s\n' \
  'import json, os' \
  'home = os.path.expanduser("~/.pi/agent")' \
  'def text(name):' \
  '    p = os.path.join(home, name)' \
  '    return open(p, encoding="utf-8-sig").read().strip() if os.path.exists(p) else None' \
  'def save(name, data):' \
  '    os.makedirs(home, exist_ok=True)' \
  '    with open(os.path.join(home, name), "w") as f: json.dump(data, f, indent=2)' \
  'for name, empty in (("models.json", {"providers": {}}), ("settings.json", {})):' \
  '    if text(name) == "": save(name, empty)' \
  'for entry in os.environ.get("SHELLBOX_PI_DEFAULT_MODELS", "").split():' \
  '    provider, _, model = entry.partition("/")' \
  '    if os.environ.get(provider.upper() + "_API_KEY"):' \
  '        settings = json.loads(text("settings.json") or "{}")' \
  '        if not (settings.get("defaultProvider") or settings.get("defaultModel")):' \
  '            settings.update(defaultProvider=provider, defaultModel=model)' \
  '            save("settings.json", settings)' \
  '        break' \
  > /usr/local/bin/ensure-pi-config.py

# Entrypoint: sets up the box's agent from the host config, prints a summary
RUN printf '%s\n' \
  '#!/bin/bash' \
  '# Set up only the agent this box has (claude when unset).' \
  'case "${SHELLBOX_BOX_AGENT:-claude}" in' \
  '  claude)' \
  '    if [ -f /tmp/.claude-config.tar ]; then' \
  '      tar xf /tmp/.claude-config.tar -C "$HOME" 2>/dev/null || true' \
  '    fi' \
  '    python3 /usr/local/bin/ensure-claude-config.py "$(pwd)" 2>/dev/null || true' \
  '    printf "\033[1;36m[shellbox]\033[0m Claude config:\n"' \
  '    if [ -f /tmp/.claude-config.tar ]; then' \
  '      printf "  %s/.claude/   (copied from host)\n" "$HOME"' \
  '    else' \
  '      printf "  %s/.claude/   -- not found on host\n" "$HOME"' \
  '    fi' \
  '    if [ ! -f "$HOME/.claude/.credentials.json" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then' \
  '      printf "  no login copied: run /login in claude (on macOS it lives in the Keychain)\n"' \
  '    fi' \
  '    if [ -d "$(pwd)/.claude" ]; then' \
  '      printf "  %s/.claude/   (mounted from project)\n" "$(pwd)"' \
  '    fi' \
  '    acc=""' \
  '    case "${SHELLBOX_TRUST_WORKDIR:-}" in 1|true|yes|on) acc="folder-trust" ;; esac' \
  '    case "${SHELLBOX_ACCEPT_BYPASS_PERMISSIONS:-}" in 1|true|yes|on) acc="${acc:+$acc, }bypass-permissions" ;; esac' \
  '    case "${SHELLBOX_SKIP_FULLSCREEN_UPSELL:-}" in 1|true|yes|on) acc="${acc:+$acc, }fullscreen-prompt" ;; esac' \
  '    case "${SHELLBOX_SKIP_WEBFETCH_PREFLIGHT:-}" in 1|true|yes|on) acc="${acc:+$acc, }no-webfetch-preflight" ;; esac' \
  '    if [ -n "$acc" ]; then' \
  '      printf "\033[1;36m[shellbox]\033[0m Claude toggles: %s\n" "$acc"' \
  '    fi' \
  '    ;;' \
  '  pi)' \
  '    mkdir -p "$HOME/.pi/agent"' \
  '    if [ -f /tmp/.pi-config.tar ]; then' \
  '      tar xf /tmp/.pi-config.tar -C "$HOME/.pi/agent" 2>/dev/null || true' \
  '    fi' \
  '    if [ -d /run/shellbox-pi-extensions ]; then' \
  '      mkdir -p "$HOME/.pi/agent/extensions"' \
  '      cp -r --update=none /run/shellbox-pi-extensions/. "$HOME/.pi/agent/extensions/"' \
  '    fi' \
  '    python3 /usr/local/bin/ensure-pi-config.py 2>/dev/null || true' \
  '    printf "\033[1;36m[shellbox]\033[0m pi config:\n"' \
  '    if [ -f /tmp/.pi-config.tar ]; then' \
  '      printf "  %s/.pi/agent/   (copied from host)\n" "$HOME"' \
  '    else' \
  '      printf "  %s/.pi/agent/   -- not found on host (use /login in pi)\n" "$HOME"' \
  '    fi' \
  '    if [ -d "$(pwd)/.pi" ]; then' \
  '      printf "  %s/.pi/         (mounted from project)\n" "$(pwd)"' \
  '    fi' \
  '    providers=""' \
  '    [ -n "${OLLAMA_API_KEY:-}" ] && providers="ollama"' \
  '    [ -n "${VENICE_API_KEY:-}" ] && providers="${providers:+$providers, }venice"' \
  '    [ -n "${OPENROUTER_API_KEY:-}" ] && providers="${providers:+$providers, }openrouter"' \
  '    [ -n "${OLLAMA_LAN_URL:-}" ] && providers="${providers:+$providers, }ollama-lan"' \
  '    if [ -n "$providers" ]; then' \
  '      printf "  model providers: %s (pick in /model)\n" "$providers"' \
  '    else' \
  '      printf "  no model provider set (export OLLAMA_API_KEY, OLLAMA_LAN_URL, VENICE_API_KEY or OPENROUTER_API_KEY, or /login in pi)\n"' \
  '    fi' \
  '    printf "  start it with:  pi\n"' \
  '    ;;' \
  'esac' \
  '# Host-egress block gate: wait until the out-of-box helper has installed the DROP' \
  '# rules (it writes <gate>/ready). Fail-closed: refuse to start if they never land,' \
  '# so the box never runs with host-local services reachable.' \
  'if [ -n "${SHELLBOX_LOCKDOWN_GATE:-}" ]; then' \
  '  _tries=0; _max="${SHELLBOX_LOCKDOWN_TIMEOUT:-200}"' \
  '  while [ ! -f "${SHELLBOX_LOCKDOWN_GATE}" ]; do' \
  '    _tries=$((_tries+1))' \
  '    if [ "${_tries}" -gt "${_max}" ]; then' \
  '      printf "\033[1;31m[shellbox]\033[0m FATAL: host-egress block was not applied in time; refusing to start (fail-closed).\n" >&2' \
  '      _gatelog="$(dirname "${SHELLBOX_LOCKDOWN_GATE}")/log"' \
  '      if [ -s "${_gatelog}" ]; then' \
  '        printf "  --- host-egress helper log ---\n" >&2' \
  '        sed "s/^/  /" "${_gatelog}" >&2' \
  '        printf "  -------------------------------\n" >&2' \
  '      else' \
  '        printf "  (no helper log was produced — the netns sidecar never ran; check that the Docker daemon is reachable.)\n" >&2' \
  '      fi' \
  '      printf "  Rebuild the image (--rebuild) or, to allow host access on purpose, rerun with --allow-local-host.\n" >&2' \
  '      exit 1' \
  '    fi' \
  '    sleep 0.1' \
  '  done' \
  '  printf "\033[1;36m[shellbox]\033[0m host-egress block active: host-local services are unreachable from this box.\n"' \
  'fi' \
  'exec "$@"' \
  > /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /home/dev/work
USER dev

RUN printf "%s\n" \
  'export PS1="\[\e[1;32m\](shellbox)\[\e[0m\] \u@\h:\w\$ "' \
  'export PIP_DISABLE_PIP_VERSION_CHECK=1' \
  'export PATH="$HOME/.local/bin:$PATH"  # where the claude (and pi) installers land' \
  >> ~/.bashrc

# Install the selected agent with its official installer (only that one, so a pi
# box has no Claude and vice versa). Network is available at BUILD time; boxwall
# only gates the running box's egress.
#   - claude: lands in ~/.local/bin.
#   - pi:     needs the Node 22 above; links `pi` into the first writable PATH dir,
#             so give it ~/.local/bin.
RUN set -eux; \
    case "${AGENT}" in \
      claude) \
        curl -fsSL https://claude.ai/install.sh | bash ;; \
      pi) \
        mkdir -p "$HOME/.local/bin"; \
        curl -fsSL https://pi.dev/install.sh \
          | PATH="$HOME/.local/bin:$PATH" sh; \
        PI_OFFLINE=1 "$HOME/.local/bin/pi" --version ;; \
    esac

# UTF-8 locale so Unicode output (agent TUIs, box-drawing, emoji) renders instead
# of "?" — the default C/POSIX locale is ASCII-only. C.UTF-8 is built into glibc,
# so no locales package is needed. Placed last so it only re-runs the cheap final
# layers on a rebuild.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash", "-l"]
