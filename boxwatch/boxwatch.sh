#!/usr/bin/env bash
set -euo pipefail

# boxwatch.sh - out-of-box activity recorder for a docker sandbox.
#
#   ./boxwatch.sh             # run in its own terminal
#   ./shellbox.sh --boxwatch  # attach a sandbox from another
#   ./boxwatch.sh --down      # tear it down
#
# One PRIVILEGED container that runs entirely OUTSIDE the sandbox and watches the
# host kernel with eBPF (bpftrace), scoping its probes to the sandbox's cgroup so
# it records that box's file, network, and process activity. Because it lives
# outside the box and writes its JSONL log to a host dir the sandbox never sees,
# a rogue agent inside the box cannot see, kill, or scrub its own watcher. The
# sandbox is told which cgroup to watch by shellbox.sh --boxwatch (a registration
# file under ~/.shellbox/watch/targets); the watcher never touches the docker
# socket. eBPF observes the host kernel directly, so this is INCOMPATIBLE with
# gVisor (--runsc), whose syscalls never reach the host kernel.

IMAGE_REPO="shellbox-boxwatch"
PROFILE="default"
BOXWATCH_NAME="shellbox-boxwatch"      # name shellbox.sh --boxwatch looks for
WATCH_DIR="${HOME}/.shellbox/watch"    # JSONL logs + target registrations
IMAGE_NAME=""
NO_BUILD=0
REBUILD=0
DOWN=0

usage() {
  cat <<'EOF'
Usage: ./boxwatch.sh [options]

Out-of-box activity recorder for shellbox sandboxes. Run in its own window, then
start a sandbox with `./shellbox.sh --boxwatch` in another.

Options:
  --name NAME          Watcher container name (default: shellbox-boxwatch). Must match
                       shellbox.sh's --boxwatch-name if you override it.
  --watch-dir DIR      Where to write logs + read target registrations (default: ~/.shellbox/watch)
  --image IMAGE        Full image name override (e.g. myrepo:tag)
  --rebuild            Force a full rebuild (docker build --no-cache)
  --no-build           Don't build (assume image exists)
  --down               Stop the watcher and exit. Attached sandboxes keep running, unwatched.
  -h, --help           Show help

Console commands (type in the boxwatch window): help, stats, tail, targets,
config, clear, quit. Type 'help' for details.

Note: needs a privileged container + an eBPF-capable host kernel (cgroup v2 +
BTF). Incompatible with `shellbox.sh --runsc` (gVisor hides syscalls from the
host kernel).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)       [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }; BOXWATCH_NAME="$2"; shift 2 ;;
    --watch-dir)  [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }; WATCH_DIR="$2"; shift 2 ;;
    --image)      [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }; IMAGE_NAME="$2"; shift 2 ;;
    --rebuild)    REBUILD=1; shift ;;
    --no-build)   NO_BUILD=1; shift ;;
    --down)       DOWN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "${NO_BUILD}" -eq 1 && "${REBUILD}" -eq 1 ]]; then
  echo "Error: --no-build and --rebuild are mutually exclusive" >&2
  exit 2
fi

if [[ -z "${IMAGE_NAME}" ]]; then
  IMAGE_NAME="${IMAGE_REPO}:${PROFILE}"
fi

# --down: tear down and exit (no build needed).
if [[ "${DOWN}" -eq 1 ]]; then
  docker rm -f "${BOXWATCH_NAME}" >/dev/null 2>&1 || true
  echo "[boxwatch] stopped '${BOXWATCH_NAME}'; attached sandboxes keep running, unwatched."
  exit 0
fi

# Build files below the exit marker, extracted at build time.
extract_dockerfile() {
  awk 'BEGIN{f=0} /^__BOXWATCH_PY__$/{f=0; next} f{print} /^__BOXWATCH_DOCKERFILE__$/{f=1}' "$0"
}
extract_py() {
  awk 'f{print} /^__BOXWATCH_PY__$/{f=1}' "$0"
}

TMPDIR_BUILD=""
cleanup() { [[ -n "${TMPDIR_BUILD}" ]] && rm -rf "${TMPDIR_BUILD}"; }
trap cleanup EXIT

if [[ "${NO_BUILD}" -eq 0 ]]; then
  TMPDIR_BUILD="$(mktemp -d)"
  extract_dockerfile > "${TMPDIR_BUILD}/Dockerfile"
  extract_py        > "${TMPDIR_BUILD}/boxwatch.py"
  if [[ ! -s "${TMPDIR_BUILD}/Dockerfile" || ! -s "${TMPDIR_BUILD}/boxwatch.py" ]]; then
    echo "Failed to extract embedded build files (markers missing?)" >&2
    exit 2
  fi
  docker build \
    $( (( REBUILD )) && echo "--no-cache" ) \
    -t "${IMAGE_NAME}" \
    "${TMPDIR_BUILD}"
fi

mkdir -p "${WATCH_DIR}/targets"

# Don't let two watchers fight over the same name.
if [[ "$(docker inspect -f '{{.State.Running}}' "${BOXWATCH_NAME}" 2>/dev/null || true)" == "true" ]]; then
  echo "Error: a boxwatch '${BOXWATCH_NAME}' is already running. Stop it first." >&2
  exit 2
fi
docker rm -f "${BOXWATCH_NAME}" >/dev/null 2>&1 || true

echo "[boxwatch] starting watcher '${BOXWATCH_NAME}'. Start a sandbox with: ./shellbox.sh --boxwatch$( [[ "${BOXWATCH_NAME}" != "shellbox-boxwatch" ]] && echo " --boxwatch-name ${BOXWATCH_NAME}" )"

# Foreground privileged watcher + console. It needs to load eBPF and see the
# whole host: --privileged for bpftrace, --pid=host so probe PIDs map to host
# tasks, and host tracefs/debugfs + cgroupfs mounted in. The sandbox gets NONE
# of this; only this out-of-box container does, which is what makes the log
# tamper-proof from inside the box.
docker run --rm -it \
  --name "${BOXWATCH_NAME}" \
  --privileged \
  --pid=host \
  -v /sys/kernel/debug:/sys/kernel/debug:rw \
  -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
  -v "${WATCH_DIR}:/watch" \
  -e BOXWATCH_LOG_DIR=/watch \
  -e BOXWATCH_TARGETS_DIR=/watch/targets \
  "${IMAGE_NAME}"

# Stop shell from parsing the embedded build files below
exit $?
__BOXWATCH_DOCKERFILE__
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    bpftrace python3 ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY boxwatch.py /usr/local/bin/boxwatch.py
ENTRYPOINT ["python3", "/usr/local/bin/boxwatch.py"]
__BOXWATCH_PY__
import json
import os
import re
import subprocess
import sys
import threading
import time

LOG_DIR = os.environ.get("BOXWATCH_LOG_DIR", "/watch")
TARGETS_DIR = os.environ.get("BOXWATCH_TARGETS_DIR", "/watch/targets")
CGROUP_ROOT = os.environ.get("BOXWATCH_CGROUP_ROOT", "/sys/fs/cgroup")

C_RESET = "\033[0m"
C_HDR = "\033[1;36m"
C_ASK = "\033[1;33m"
C_OK = "\033[32m"
C_NO = "\033[31m"

# A docker id is 64 hex chars; the cgroup dir is named after it (e.g.
# `docker-<id>.scope` or `<id>`). Used to map a registered container -> cgroup.
_ID_RE = re.compile(r"\A[0-9a-f]{12,64}\Z")
# Container names we'll accept from a registration file (kept to a safe charset
# since the name is printed to the operator console and used as a log label).
_NAME_RE = re.compile(r"\A[A-Za-z0-9_.-]{1,64}\Z")
# comm/filename come from the untrusted box and may contain control bytes, ANSI,
# tabs, or newlines. Anything outside printable ASCII is escaped before it's
# logged or printed, so a path can't redraw the operator's terminal (cf. boxwall's
# clean_name) or smuggle delimiters.
_UNSAFE_RE = re.compile(r"[^\x20-\x7e]")
# Cgroup paths are embedded into the generated bpftrace program as string
# literals. Only printable ASCII excluding " (0x22) and \ (0x5c) is allowed, so a
# path can neither break out of the literal nor smuggle a newline into the
# program text. A target whose resolved path fails this is dropped, not watched.
_SAFE_PATH_RE = re.compile(r"\A[\x20-\x21\x23-\x5b\x5d-\x7e]+\Z")

# open(2) flags we treat as a write.
O_ACCMODE, O_WRONLY, O_RDWR = 0o3, 0o1, 0o2
O_CREAT, O_TRUNC, O_APPEND = 0o100, 0o1000, 0o2000

EV_TYPES = ("exec", "open", "connect")

# Disk + CPU guards: a busy or hostile box generates events through us, so cap how
# much we'll write (rotate) and how fast (per-second rate limit), or it could fill
# the host disk via the watcher.
LOG_MAX_BYTES = 64 * 1024 * 1024    # rotate events.jsonl at 64 MiB
LOG_BACKUPS = 3                     # keep events.jsonl.1 .. .3
RATE_PER_SEC = 2000                 # events/sec written before we start dropping

stats = {"exec": 0, "open_r": 0, "open_w": 0, "connect": 0,
         "lines": 0, "suspect": 0, "dropped": 0}
recent = []                 # ring of the last N normalized events (console tail)
_RECENT_MAX = 1000
verbose_types = {"exec", "connect"}  # event types echoed live as they land; empty = quiet
_lock = threading.Lock()    # guards stats/recent/log against the reader thread

cgid_to_name = {}           # cgroup id -> container name (authoritative, from bpftrace)
known_cgids = set()         # cgroup ids bpftrace confirmed for our targets
target_names = []           # index -> name, matching the BEGIN probe order
session_dir = None          # /watch/session-<stamp>
log_path = None             # /watch/session-<stamp>/events.jsonl
log_fp = None               # append-only JSONL handle
log_bytes = 0               # bytes in the current log segment (for rotation)
_rate = {"sec": 0, "n": 0, "dropped": 0}
_tracer = None              # the live Tracer (set in main; used by console cmds)


def sanitize(s, limit=4096):
    # Escape every non-printable-ASCII byte so untrusted comm/paths can't inject
    # terminal escapes or record delimiters. Also length-capped.
    if not isinstance(s, str):
        return s
    return _UNSAFE_RE.sub(lambda m: "\\x%02x" % ord(m.group()), s[:limit])


def _bt_str(s):
    # Escape a path for safe embedding in a bpftrace double-quoted string literal.
    # Paths are also vetted by _SAFE_PATH_RE in read_targets; this is belt-and-braces.
    return s.replace("\\", "\\\\").replace('"', '\\"')


class QuitConsole(Exception):
    pass


def log(msg):
    print(f"{C_HDR}[boxwatch]{C_RESET} {msg}")


def open_session_log():
    global session_dir, log_path, log_fp, log_bytes
    stamp = time.strftime("%Y%m%d-%H%M%S")
    session_dir = os.path.join(LOG_DIR, f"session-{stamp}")
    os.makedirs(session_dir, exist_ok=True)
    log_path = os.path.join(session_dir, "events.jsonl")
    log_fp = open(log_path, "a", buffering=1)
    log_bytes = log_fp.tell()
    return log_path


def _rotate_log():
    # Size-based rotation so a flood can't fill the host disk through us:
    # events.jsonl -> .1 -> .2 -> ... -> .LOG_BACKUPS (oldest dropped).
    global log_fp, log_bytes
    log_fp.close()
    for i in range(LOG_BACKUPS, 0, -1):
        src = log_path if i == 1 else f"{log_path}.{i - 1}"
        if os.path.exists(src):
            os.replace(src, f"{log_path}.{i}")
    log_fp = open(log_path, "w", buffering=1)
    log_bytes = 0


def log_event(e):
    # Rate-limit then write one JSONL record, rotating when the segment is full.
    # Caller holds _lock. Returns False when the event was dropped (rate cap).
    global log_bytes
    sec = int(e["ts"])
    if sec != _rate["sec"]:
        if _rate["dropped"]:
            _write_line(json.dumps({"ts": e["ts"], "ev": "_dropped",
                                    "count": _rate["dropped"], "reason": "rate-cap"}))
        _rate["sec"], _rate["n"], _rate["dropped"] = sec, 0, 0
    _rate["n"] += 1
    if _rate["n"] > RATE_PER_SEC:
        _rate["dropped"] += 1
        stats["dropped"] += 1
        return False
    _write_line(json.dumps(e))
    return True


def _write_line(s):
    global log_bytes
    if log_fp is None:
        return
    log_fp.write(s + "\n")
    log_bytes += len(s) + 1
    if log_bytes >= LOG_MAX_BYTES:
        _rotate_log()


def find_cgroup_path(cid):
    # Locate the container's cgroup dir by its id. Docker names the dir after the
    # container id, optionally wrapped as `docker-<id>.scope` (systemd driver). We
    # strip that wrapper and require the id *token* to equal or start with `cid`,
    # rather than a bare substring match -- a loose `cid in d` can resolve two
    # different containers to one dir, which silently collapses their cgroup ids
    # and (see handle_cgid) used to leave the trusted-id set open to forgery.
    # Bounded walk over the cgroup tree.
    for root, dirs, _files in os.walk(CGROUP_ROOT):
        for d in dirs:
            ident = d
            if ident.startswith("docker-"):
                ident = ident[len("docker-"):]
            if ident.endswith(".scope"):
                ident = ident[:-len(".scope")]
            if ident == cid or ident.startswith(cid):
                return os.path.join(root, d)
        if root.count("/") - CGROUP_ROOT.count("/") > 6:
            dirs[:] = []        # don't descend forever
    return None


def read_targets():
    # Map of container-name -> cgroup path, from the registration files that
    # shellbox.sh --boxwatch drops here. The watcher never calls docker itself.
    out = {}
    try:
        names = os.listdir(TARGETS_DIR)
    except OSError:
        return out
    for fn in names:
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(TARGETS_DIR, fn)) as f:
                d = json.load(f)
        except Exception:
            continue
        cid = str(d.get("id", ""))
        name = str(d.get("name", fn[:-5]))
        if not _ID_RE.match(cid) or not _NAME_RE.match(name):
            continue
        path = find_cgroup_path(cid)
        if path and _SAFE_PATH_RE.match(path):
            out[name] = path
    return out


def gen_program(name_to_path):
    # Generate a bpftrace program scoped to the watched cgroups. Each probe bails
    # unless the current task is in one of them, so we only ever record the
    # sandbox's own file/network/process activity. `cgroup` is prepended to every
    # line so the collector can attribute events when several boxes are watched.
    global cgid_to_name, known_cgids, target_names
    cgid_to_name = {}
    known_cgids = set()
    items = list(name_to_path.items())
    target_names = [name for name, _ in items]
    conds = [f'cgroup == cgroupid("{_bt_str(path)}")' for _, path in items]
    guard = "if (!(%s)) { return; }" % " || ".join(conds)
    # BEGIN emits the authoritative cgroup id bpftrace itself computes for each
    # target (as a `Z` line). The collector trusts only these ids, so an event
    # whose cgroup field is anything else — e.g. a record forged by embedding a
    # newline in a filename — is flagged `suspect` instead of attributed.
    #
    # Field order matters: every trusted numeric field (cgroup, pid, flags, ip,
    # port) is emitted BEFORE the untrusted strings (comm, filename), and the
    # untrusted strings trail. A box can set its own `comm` to arbitrary bytes
    # (prctl PR_SET_NAME) including a TAB; with the strings trailing, a tab can
    # only blur the comm/filename boundary (both are sanitized) instead of
    # shifting a numeric field and crashing the parse — which previously let a
    # box drop its own open/connect events from the log entirely.
    #
    # exec is captured from sched:sched_process_exec, NOT syscalls:sys_enter_execve.
    # At sys_enter the filename is a *userspace* pointer that often isn't faulted in
    # yet, so str() reads empty on a cold page — making the FIRST exec of a binary
    # show up with no filename. sched_process_exec fires after the exec succeeds and
    # exposes filename as a kernel __data_loc string (already copied into the trace
    # record), so str() always reads the resolved path. It also fires exactly once
    # per successful exec (no execve retries/duplicates). Trade-off: `comm` here is
    # the NEW program, not the caller — still box-controllable, hence kept trailing.
    begin = "".join(
        f'printf("Z\\t%d\\t{i}\\n", cgroupid("{_bt_str(path)}"));'
        for i, (_, path) in enumerate(items))
    return r"""
BEGIN { %(b)s }
tracepoint:sched:sched_process_exec { %(g)s printf("X\t%%d\t%%d\t%%s\t%%s\n", cgroup, pid, comm, str(args->filename)); }
tracepoint:syscalls:sys_enter_openat { %(g)s printf("O\t%%d\t%%d\t%%d\t%%s\t%%s\n", cgroup, pid, args->flags, comm, str(args->filename)); }
tracepoint:syscalls:sys_enter_connect {
  %(g)s
  $sa = (struct sockaddr *)args->uservaddr;
  if ($sa->sa_family == 2) {
    $si = (struct sockaddr_in *)args->uservaddr;
    $p = (uint16)(($si->sin_port >> 8) | ($si->sin_port << 8));
    $a = $si->sin_addr.s_addr;
    printf("C\t%%d\t%%d\t%%d.%%d.%%d.%%d\t%%d\t%%s\n", cgroup, pid,
           $a & 0xff, ($a >> 8) & 0xff, ($a >> 16) & 0xff, ($a >> 24) & 0xff, $p, comm);
  }
}
""" % {"g": guard, "b": begin}


def handle_cgid(line):
    # Learn an authoritative target cgroup id from a BEGIN `Z` line. Caller holds
    # _lock. We accept at most one id per target and stop once all are known.
    #
    # The real defense against a forged `Z` (one smuggled through a newline in an
    # untrusted comm/filename) lives in reader_loop, which refuses ALL `Z` lines
    # after the first real event line: bpftrace emits every genuine `Z` from
    # BEGIN, before any probe can fire, so a `Z` arriving later is necessarily a
    # forgery. This count-based stop is now just a secondary cap, and crucially is
    # no longer load-bearing when two targets share a cgroup id (which keeps
    # len(known_cgids) below len(target_names) forever).
    if target_names and len(known_cgids) >= len(target_names):
        return
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 3:
        return
    try:
        cgid, idx = int(parts[1]), int(parts[2])
    except ValueError:
        return
    if 0 <= idx < len(target_names):
        cgid_to_name[cgid] = target_names[idx]
        known_cgids.add(cgid)


def normalize(line):
    # bpftrace prints tab-delimited lines; turn them into a JSON event. Trusted
    # numeric fields lead; the untrusted strings (comm, then filename) trail, so a
    # tab inside comm can only spill into the trailing field rather than displace a
    # numeric one. We split with a fixed field count and let the trailing field
    # keep anything extra. Returns None on a malformed line; the caller turns that
    # into a logged `suspect` marker rather than silently dropping it.
    parts = line.rstrip("\n").split("\t")
    if not parts:
        return None
    kind = parts[0]
    try:
        if kind == "X" and len(parts) >= 5:
            cg, pid, comm, fn = parts[1], parts[2], parts[3], "\t".join(parts[4:])
            stats["exec"] += 1
            return _ev("exec", cg, pid, comm, {"file": sanitize(fn)})
        if kind == "O" and len(parts) >= 6:
            cg, pid, flags, comm, fn = parts[1], parts[2], int(parts[3]), parts[4], "\t".join(parts[5:])
            write = bool(flags & O_CREAT or flags & O_TRUNC or (flags & O_ACCMODE) in (O_WRONLY, O_RDWR))
            stats["open_w" if write else "open_r"] += 1
            return _ev("open", cg, pid, comm, {"file": sanitize(fn), "write": write})
        if kind == "C" and len(parts) >= 6:
            cg, pid, ip, port, comm = parts[1], parts[2], parts[3], int(parts[4]), "\t".join(parts[5:])
            stats["connect"] += 1
            return _ev("connect", cg, pid, comm, {"ip": sanitize(ip), "port": port})
    except (ValueError, IndexError):
        return None
    return None


def _ev(ev, cg, pid, comm, extra):
    try:
        cgid = int(cg)
    except ValueError:
        cgid = None
    # A genuine bpftrace line carries one of the cgroup ids it confirmed at BEGIN;
    # once we know them, anything else is a forged/unattributable record.
    suspect = bool(known_cgids) and cgid not in known_cgids
    e = {"ts": round(time.time(), 3), "container": cgid_to_name.get(cgid),
         "ev": ev, "pid": int(pid) if pid.isdigit() else sanitize(pid),
         "comm": sanitize(comm)}
    if suspect:
        e["suspect"] = True
        stats["suspect"] += 1
    e.update(extra)
    return e


def fmt_event(e):
    # comm/file/ip/raw are sanitized at parse time, so this can't be used to inject
    # terminal escapes. A leading '!' marks a suspect (unconfirmed-cgroup or
    # unparseable) event.
    who = e.get("container") or "?"
    mark = f"{C_NO}!{C_RESET}" if e.get("suspect") else " "
    if e["ev"] == "malformed":
        return f"{mark}{C_OK}{'malformed':>7}{C_RESET} {who} {e.get('raw', '')}"
    base = f"{mark}{C_OK}{e['ev']:>7}{C_RESET} {who} pid={e.get('pid')} {e.get('comm', '')}"
    if e["ev"] == "exec":
        return f"{base} {e.get('file', '')}"
    if e["ev"] == "open":
        return f"{base} {'W' if e.get('write') else 'R'} {e.get('file', '')}"
    if e["ev"] == "connect":
        return f"{base} -> {e.get('ip')}:{e.get('port')}"
    return base


def _malformed(line):
    # A line with a valid event prefix that we couldn't parse into a known event
    # (e.g. a fragment left by a newline injected into an untrusted comm/filename).
    # Logged as a suspect marker rather than dropped, so a box can't make activity
    # vanish from the record by deliberately producing an unparseable line.
    stats["suspect"] += 1
    return {"ts": round(time.time(), 3), "ev": "malformed", "suspect": True,
            "raw": sanitize(line.rstrip("\n"))}


def reader_loop(proc):
    # Drain bpftrace stdout: normalize -> rate-limit + append JSONL -> stats/ring.
    # bpftrace emits every authoritative `Z` cgroup-id line from BEGIN, before any
    # syscall probe can fire. So once we've seen the first real event line, any
    # further `Z` can only be a forgery smuggled through a newline in an untrusted
    # comm/filename -- we refuse them from then on. This closes the cgid-poisoning
    # vector outright, independent of how many targets share a cgroup id.
    begin_done = False
    live = False           # announced "capture live" once all BEGIN Z lines arrived
    z_seen = 0             # BEGIN Z lines received so far (one per target)
    for line in proc.stdout:
        if line.startswith("Z\t"):       # BEGIN-emitted authoritative cgroup id
            if begin_done:
                continue                  # forged: real Z lines only arrive at BEGIN
            with _lock:
                handle_cgid(line)
                z_seen += 1
                # bpftrace runs BEGIN only AFTER every probe is attached, and emits
                # all Z lines there before any probe can fire. So the moment we've
                # received one Z per target, the syscall probes are live and capture
                # is authoritative. Anything before this point could be missed during
                # probe attach -- make that boundary explicit. Count Z lines (not
                # unique cgids) so targets sharing a cgroup id still announce.
                if not live and target_names and z_seen >= len(target_names):
                    live = True
                    log(f"capture live ({len(target_names)} target(s)); "
                        f"log -> {session_dir}/events.jsonl")
            continue
        if not line.startswith(("X\t", "O\t", "C\t")):
            continue                      # skip bpftrace's "Attaching probes" chatter
        begin_done = True
        with _lock:
            stats["lines"] += 1
            e = normalize(line)
            if e is None:
                e = _malformed(line)
            if not log_event(e):          # dropped by the rate cap
                continue
            recent.append(e)
            if len(recent) > _RECENT_MAX:
                del recent[0]
            if e["ev"] in verbose_types:
                print(fmt_event(e))


class Tracer:
    # Owns the bpftrace subprocess + its reader thread, and restarts both when
    # the set of watched targets changes.
    def __init__(self):
        self.proc = None
        self.thread = None
        self.paths = {}

    def restart(self, name_to_path):
        self.stop()
        self.paths = dict(name_to_path)
        if not name_to_path:
            log("no targets registered yet; waiting for ./shellbox.sh --boxwatch ...")
            return
        prog = gen_program(name_to_path)
        errlog = open(os.path.join(session_dir, "bpftrace.log"), "a", buffering=1)
        try:
            # -B line: line-buffer bpftrace's stdout. Over a pipe it defaults to
            # full (block) buffering, which makes events arrive in delayed bursts on
            # the console and, worse, discards anything still buffered when we SIGTERM
            # the process on a target-set change. Line buffering flushes per event.
            self.proc = subprocess.Popen(
                ["bpftrace", "-B", "line", "-e", prog],
                stdout=subprocess.PIPE, stderr=errlog, text=True, bufsize=1)
        except FileNotFoundError:
            log(f"{C_NO}FATAL{C_RESET} bpftrace not found in image.")
            raise SystemExit(1)
        self.thread = threading.Thread(target=reader_loop, args=(self.proc,), daemon=True)
        self.thread.start()
        # bpftrace is starting but its probes aren't attached yet; events in this
        # window can be missed. reader_loop prints "capture live" once BEGIN confirms
        # all probes are attached -- that line marks the start of authoritative capture.
        log(f"attaching probes for {', '.join(name_to_path)} ({len(name_to_path)} target(s)); "
            f"events before 'capture live' may be missed during attach...")

    def stop(self):
        if self.proc is not None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=5)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
            self.proc = None
        # Join the reader thread before returning so the next gen_program() can
        # reset the shared cgid_to_name/known_cgids/target_names globals without
        # racing a still-draining reader (which reads them under _lock).
        if self.thread is not None:
            self.thread.join(timeout=5)
            self.thread = None


def targets_poller(tracer, stop_evt):
    # Re-scan the targets dir; restart the tracer when membership changes.
    last = None
    while not stop_evt.is_set():
        cur = read_targets()
        if set(cur) != set(last or {}):
            tracer.restart(cur)
            last = cur
        stop_evt.wait(2)


def cmd_help(_args):
    print(
        "commands (type and press Enter):\n"
        "  help, h, ?           show this help\n"
        "  stats                event counts seen this session\n"
        "  tail [N]             show the last N events (default 20)\n"
        "  targets              containers currently being watched\n"
        "  config verbose <what>  echo events live; <what> = on|off|exec|open|connect\n"
        "                         (combine, e.g. 'config verbose exec connect'; default: exec,connect)\n"
        "  clear                clear the in-memory tail buffer\n"
        "  quit, exit           stop the watcher (sandboxes keep running, unwatched)"
    )


def cmd_stats(_args):
    with _lock:
        print(f"  exec      {stats['exec']}")
        print(f"  open  (r) {stats['open_r']}")
        print(f"  open  (w) {stats['open_w']}")
        print(f"  connect   {stats['connect']}")
        print(f"  lines     {stats['lines']}")
        print(f"  suspect   {stats['suspect']}  (events with an unconfirmed cgroup)")
        print(f"  dropped   {stats['dropped']}  (rate cap, {RATE_PER_SEC}/s)")
        if log_path:
            print(f"  log       {log_path}")


def cmd_tail(args):
    n = 20
    types = set()
    for a in args:
        if a.isdigit():
            n = int(a)
        elif a.lower() in EV_TYPES:
            types.add(a.lower())
        else:
            print(f"[boxwatch] tail: ignoring {a!r} (use a count or {'|'.join(EV_TYPES)})")
    with _lock:
        pool = [e for e in recent if not types or e["ev"] in types]
    tail = pool[-n:]
    if not tail:
        print("no matching events captured yet")
        return
    for e in tail:
        print(fmt_event(e))


def cmd_targets(_args):
    if _tracer is None or not _tracer.paths:
        print("no targets registered (start a sandbox with ./shellbox.sh --boxwatch)")
        return
    for name, path in _tracer.paths.items():
        print(f"  {name:<28} {path}")


def _fmt_verbose():
    return ",".join(t for t in EV_TYPES if t in verbose_types) if verbose_types else "off"


def cmd_config(args):
    global verbose_types
    if args and args[0] == "verbose":
        rest = [t for a in args[1:] for t in a.lower().split(",") if t]
        if not rest or rest == ["on"] or rest == ["all"]:
            verbose_types = set(EV_TYPES)
        elif rest == ["off"] or rest == ["none"]:
            verbose_types = set()
        else:
            picked = set()
            for t in rest:
                if t in EV_TYPES:
                    picked.add(t)
                else:
                    print(f"[boxwatch] unknown event type: {t!r} (pick from {'|'.join(EV_TYPES)})")
            verbose_types = picked
        print(f"[boxwatch] verbose {_fmt_verbose()}")
        return
    print(f"  log-dir     {LOG_DIR}")
    print(f"  targets-dir {TARGETS_DIR}")
    print(f"  verbose     {_fmt_verbose()}")


def cmd_clear(_args):
    with _lock:
        n = len(recent)
        recent.clear()
    print(f"[boxwatch] cleared {n} buffered event(s)")


COMMANDS = {
    "help": cmd_help, "h": cmd_help, "?": cmd_help,
    "stats": cmd_stats, "st": cmd_stats,
    "tail": cmd_tail, "log": cmd_tail,
    "targets": cmd_targets, "ls": cmd_targets,
    "config": cmd_config, "cfg": cmd_config,
    "clear": cmd_clear,
}


def run_command(line):
    parts = line.split()
    if not parts:
        return
    name, cargs = parts[0].lower(), parts[1:]
    if name in ("quit", "exit", "q"):
        raise QuitConsole()
    fn = COMMANDS.get(name)
    if fn is None:
        print(f"[boxwatch] unknown command: {name!r} (try 'help')")
        return
    fn(cargs)


def prompt_line():
    sys.stdout.write(f"{C_HDR}boxwatch>{C_RESET} ")
    sys.stdout.flush()


def console():
    # Sole owner of stdin. Each line parses as a command; exit on Ctrl-D.
    cmd_help([])
    prompt_line()
    for line in sys.stdin:
        try:
            run_command(line.strip())
        except QuitConsole:
            print("[boxwatch] quit requested.")
            return
        prompt_line()
    print("\n[boxwatch] stdin closed; stopping.")


def main():
    global _tracer
    path = open_session_log()
    log(f"recording to {path} (this dir is NOT visible to the sandbox).")
    _tracer = Tracer()
    stop_evt = threading.Event()
    poller = threading.Thread(target=targets_poller, args=(_tracer, stop_evt), daemon=True)
    poller.start()
    try:
        console()
    finally:
        stop_evt.set()
        _tracer.stop()
        if log_fp is not None:
            log_fp.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[boxwatch] shutting down.")
