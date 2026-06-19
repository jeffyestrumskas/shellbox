#!/usr/bin/env bash
set -euo pipefail

# boxwall.sh - interactive egress firewall for a docker sandbox.
#
#   ./boxwall.sh              # run in its own terminal
#   ./shellbox.sh --boxwall   # attach a sandbox from another
#   ./boxwall.sh --down       # tear it down
#
# Two containers: a persistent netns holder (named by the required --name) owning the
# namespace + egress (the sandbox joins THIS), and a foreground proxy/console
# (-ctl) sharing the netns to gate traffic. Rerunning boxwall.sh keeps the holder
# up; while the console is down egress is fail-closed. The proxy peeks the TLS
# SNI / HTTP Host (no decryption) and prompts for a decision: an action
# (allow / deny) + a duration (once / until-quit / forever / timed) plus an
# optional scope (this host:port /
# any port on host / any host on port / domain+subdomains / any connection); DNS
# prompts once per resolver; everything else (ICMP/SCTP/QUIC/IPv6) drops.

IMAGE_REPO="shellbox-boxwall"
PROFILE="default"
BOXWALL_NAME=""                        # required via --name; the namespace shellbox.sh --boxwall attaches to
PROXY_PORT=12345
RULES_DIR="${PWD}/.shellbox"
IMAGE_NAME=""
NO_BUILD=0
REBUILD=0
DOWN=0

usage() {
  cat <<'EOF'
Usage: ./boxwall.sh [options]

Interactive egress firewall for shellbox sandboxes. Run in its own window, then
start a sandbox with `./shellbox.sh --boxwall` in another.

Options:
  --name NAME          Boxwall namespace (REQUIRED). Names the firewall containers and
                       scopes its rules file. Attach a sandbox with the same name via
                       shellbox.sh --boxwall NAME (or --boxwall-name NAME).
  --port PORT          Internal proxy port (default: 12345)
  --rules-dir DIR      Where to persist allow-forever rules (default: ./.shellbox)
  --image IMAGE        Full image name override (e.g. myrepo:tag)
  --rebuild            Force a full rebuild (docker build --no-cache)
  --no-build           Don't build (assume image exists)
  --down               Stop the netns holder (+ console) and exit. Attached
                       sandboxes lose network until a boxwall is started again.
  -h, --help           Show help

Prompts (per new destination) — type <action><duration>[scope]. Action: a=allow
d=deny. Duration: o=once  q=until-quit  f=forever  1m/1h=timed. Scope (append a
letter): h=any port on host  p=any host on port
s=domain+subdomains  *=any connection. e.g. 'af*' = allow any connection forever,
'aqs' = allow this domain until quit, 'df' = deny forever, 'dfs' = deny a whole
domain forever. Default scope is the exact host:port; a bare Enter (or d) denies
just this one connection.

Console commands (type in the boxwall window): help, rules, history, config,
allow, forget, reload, clear, quit. Type 'help' for details.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)       [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }; BOXWALL_NAME="$2"; shift 2 ;;
    --port)       [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }; PROXY_PORT="$2"; shift 2 ;;
    --rules-dir)  [[ $# -ge 2 ]] || { echo "Missing argument for $1" >&2; exit 2; }; RULES_DIR="$2"; shift 2 ;;
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

# A namespace is mandatory: it names the containers, scopes the rules file, and is
# what `shellbox.sh --boxwall NAME` attaches to. Refuse to guess a default.
if [[ -z "${BOXWALL_NAME}" ]]; then
  echo "Error: --name NAME is required (the boxwall namespace)." >&2
  echo "  e.g. ./boxwall.sh --name proj-a   then   ./shellbox.sh --boxwall proj-a" >&2
  exit 2
fi

if [[ -z "${IMAGE_NAME}" ]]; then
  IMAGE_NAME="${IMAGE_REPO}:${PROFILE}"
fi

NETNS_NAME="${BOXWALL_NAME}"          # persistent netns holder; sandbox attaches here
CTL_NAME="${BOXWALL_NAME}-ctl"        # foreground proxy/console (this process)

# --down: tear down and exit (no build needed).
if [[ "${DOWN}" -eq 1 ]]; then
  docker rm -f "${CTL_NAME}"   >/dev/null 2>&1 || true
  docker rm -f "${NETNS_NAME}" >/dev/null 2>&1 || true
  echo "[boxwall] stopped '${NETNS_NAME}' (+ '${CTL_NAME}'); attached sandboxes now have no network."
  exit 0
fi

# Build files below the exit marker, extracted at build time.
extract_dockerfile() {
  awk 'BEGIN{f=0} /^__BOXWALL_PROXY_PY__$/{f=0; next} f{print} /^__BOXWALL_DOCKERFILE__$/{f=1}' "$0"
}
extract_proxy() {
  awk 'f{print} /^__BOXWALL_PROXY_PY__$/{f=1}' "$0"
}

TMPDIR_BUILD=""
cleanup() { [[ -n "${TMPDIR_BUILD}" ]] && rm -rf "${TMPDIR_BUILD}"; }
trap cleanup EXIT

if [[ "${NO_BUILD}" -eq 0 ]]; then
  TMPDIR_BUILD="$(mktemp -d)"
  extract_dockerfile > "${TMPDIR_BUILD}/Dockerfile"
  extract_proxy     > "${TMPDIR_BUILD}/boxwall_proxy.py"
  if [[ ! -s "${TMPDIR_BUILD}/Dockerfile" || ! -s "${TMPDIR_BUILD}/boxwall_proxy.py" ]]; then
    echo "Failed to extract embedded build files (markers missing?)" >&2
    exit 2
  fi
  docker build \
    $( (( REBUILD )) && echo "--no-cache" ) \
    -t "${IMAGE_NAME}" \
    "${TMPDIR_BUILD}"
fi

mkdir -p "${RULES_DIR}"

# Decide how to persist allow-forever rules. Prefer a host bind mount so the
# rules file is inspectable at ${RULES_DIR}/boxwall-rules.json. But Docker
# Desktop refuses to bind-mount host paths that aren't in its File Sharing list
# ("path ... is not shared from the host and is not known to Docker"), which
# would kill the console before it ever seals the proxy. Probe the mount with a
# throwaway container; if Docker rejects it, fall back to a managed named volume
# so the firewall still runs (rules persist across restarts; they're just not a
# host-visible file).
# Scope the rules file to the boxwall namespace so several boxwalls can share one
# ${RULES_DIR} without clobbering each other's allow-forever lists.
RULES_BASENAME="boxwall-rules-${BOXWALL_NAME}.json"
RULES_VOLUME="${BOXWALL_NAME}-rules"
RULES_MOUNT="${RULES_DIR}:/rules"
if ! docker run --rm --entrypoint true -v "${RULES_DIR}:/rules" "${IMAGE_NAME}" >/dev/null 2>&1; then
  RULES_MOUNT="${RULES_VOLUME}:/rules"
  echo "[boxwall] WARN: cannot bind-mount '${RULES_DIR}' (Docker is not sharing that host path);" >&2
  echo "[boxwall]       persisting rules in the Docker named volume '${RULES_VOLUME}' instead." >&2
  echo "[boxwall]       For a host-visible rules file, add '${RULES_DIR}' (or your home dir) under" >&2
  echo "[boxwall]       Docker Desktop -> Settings -> Resources -> File Sharing, or pass --rules-dir a shared path." >&2
fi

# 1) Ensure the netns holder is up. The sandbox joins IT, not the console, so
#    restarting the console never drops the sandbox's network.
if [[ "$(docker inspect -f '{{.State.Running}}' "${NETNS_NAME}" 2>/dev/null || true)" != "true" ]]; then
  docker rm -f "${NETNS_NAME}" >/dev/null 2>&1 || true
  # Seal fail-closed as PID 1's first act, then sleep: sealing from a separate
  # container would leave a window where the holder is joinable but egress open.
  # `set -e` kills PID 1 (and the --rm container) on a failed seal instead of
  # sleeping open; the console rebuilds the full ruleset later. NET_ADMIN is
  # per-process, so a joining sandbox doesn't inherit it (stays --cap-drop ALL).
  # route_localnet=1 is REQUIRED for the design to work: REDIRECT rewrites the
  # sandbox's packets to 127.0.0.1, and without this the kernel won't reroute a
  # loopback destination from a non-loopback source (the sandbox's real IP) onto lo,
  # so they keep egressing eth0 and hit the catch-all DROP instead of the proxy.
  # This is consulted PER INTERFACE on the reroute path: conf.all=1 alone is NOT
  # enough -- conf.eth0 must be 1 too (verified empirically: with all=1 but eth0=0
  # the redirected packets still drop). It can only be set at creation: /proc/sys/net
  # is a read-only mount in the holder, so neither `docker exec` (even --privileged)
  # nor a netns-joining helper can write it afterward. Namespaced sysctl; the host is
  # untouched.
  # Docker Engine 28+ no longer accepts interface-specific sysctls for a NAMED iface
  # (net.ipv4.conf.eth0.*) via --sysctl -- it errors "must be supplied using driver
  # option 'com.docker.network.endpoint.sysctls'". The per-iface value is instead
  # passed as a bridge endpoint driver-opt, with the IFNAME placeholder (the real
  # iface name isn't known at create time; Docker substitutes it, == eth0 on the
  # default bridge). The non-iface 'all' and loopback 'lo' settings still ride
  # --sysctl. Joining the default bridge explicitly via --network name=bridge is
  # required to attach the driver-opt; it's the same network the container used
  # implicitly before.
  docker run -d --rm \
    --name "${NETNS_NAME}" \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --security-opt no-new-privileges:true \
    --sysctl net.ipv4.conf.all.route_localnet=1 \
    --sysctl net.ipv4.conf.lo.route_localnet=1 \
    --network "name=bridge,driver-opt=com.docker.network.endpoint.sysctls=net.ipv4.conf.IFNAME.route_localnet=1" \
    --entrypoint sh \
    "${IMAGE_NAME}" -c '
      set -e
      iptables  -P OUTPUT DROP
      iptables  -F OUTPUT
      iptables  -A OUTPUT -o lo -j ACCEPT
      iptables  -A OUTPUT -j DROP
      ip6tables -P OUTPUT DROP 2>/dev/null || true
      ip6tables -F OUTPUT       2>/dev/null || true
      ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
      ip6tables -A OUTPUT -j DROP 2>/dev/null || true
      exec sleep infinity
    ' >/dev/null
  echo "[boxwall] started self-sealing netns holder '${NETNS_NAME}'."

  # Confirm the holder sealed before a sandbox attaches; unsealed/dead means
  # tear down + abort rather than leak egress.
  if ! docker run --rm \
    --network "container:${NETNS_NAME}" \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --security-opt no-new-privileges:true \
    --entrypoint sh \
    "${IMAGE_NAME}" -c '[ "$(iptables -S OUTPUT 2>/dev/null | head -n1)" = "-P OUTPUT DROP" ]' >/dev/null 2>&1
  then
    docker rm -f "${NETNS_NAME}" >/dev/null 2>&1 || true
    echo "[boxwall] FATAL: holder netns is not sealed (egress would be open by default); refusing to start." >&2
    exit 1
  fi
fi

# A holder left running from before route_localnet was added to the --sysctl list
# above would still have it off (re-running boxwall.sh does NOT recreate a live
# holder), and it can't be fixed in place (/proc/sys/net is read-only in the holder).
# Detect that case and force a recreate so the new sysctls actually apply.
if docker exec --privileged "${NETNS_NAME}" \
     cat /proc/sys/net/ipv4/conf/eth0/route_localnet 2>/dev/null | grep -q '^0'; then
  echo "[boxwall] holder '${NETNS_NAME}' predates the eth0 route_localnet fix; recreating it." >&2
  docker rm -f "${CTL_NAME}" "${NETNS_NAME}" >/dev/null 2>&1 || true
  echo "[boxwall] re-run this command to start the holder with the corrected sysctls." >&2
  exit 1
fi

# 2) Don't let two consoles fight over the same netns / proxy port.
if [[ "$(docker inspect -f '{{.State.Running}}' "${CTL_NAME}" 2>/dev/null || true)" == "true" ]]; then
  echo "Error: a boxwall console '${CTL_NAME}' is already running. Stop it first." >&2
  exit 2
fi
docker rm -f "${CTL_NAME}" >/dev/null 2>&1 || true

echo "[boxwall] console attaching to '${NETNS_NAME}'. Start a sandbox with: ./shellbox.sh --boxwall ${BOXWALL_NAME}"

# 3) Foreground proxy/console: shares the holder's netns, manages its iptables,
#    runs the prompt. Exit leaves the holder intact. NET_ADMIN only (iptables +
#    SO_MARK); NET_RAW withheld.
docker run --rm -it \
  --name "${CTL_NAME}" \
  --network "container:${NETNS_NAME}" \
  --cap-drop ALL \
  --cap-add NET_ADMIN \
  --security-opt no-new-privileges:true \
  -e BOXWALL_PROXY_PORT="${PROXY_PORT}" \
  -e BOXWALL_RULES_FILE="/rules/${RULES_BASENAME}" \
  -v "${RULES_MOUNT}" \
  "${IMAGE_NAME}"

# Stop shell from parsing the embedded build files below
exit $?
__BOXWALL_DOCKERFILE__
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 iptables ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY boxwall_proxy.py /usr/local/bin/boxwall_proxy.py
ENTRYPOINT ["python3", "/usr/local/bin/boxwall_proxy.py"]
__BOXWALL_PROXY_PY__
import asyncio
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time

SO_ORIGINAL_DST = 80
IP_ORIGDSTADDR = 20         # IP_RECVORIGDSTADDR; recovers DNAT'd UDP dst
MARK = 1
PORT = int(os.environ.get("BOXWALL_PROXY_PORT", "12345"))
DNS_PORT = int(os.environ.get("BOXWALL_DNS_PORT", str(PORT + 1)))  # UDP DNS interceptor
RULES_FILE = os.environ.get("BOXWALL_RULES_FILE", "/rules/boxwall-rules.json")

C_RESET = "\033[0m"
C_HDR = "\033[1;36m"
C_ASK = "\033[1;33m"
C_OK = "\033[32m"
C_NO = "\033[31m"
C_B = "\033[1m"          # bold; highlights the keys you actually type
C_DIM = "\033[2m"

session_allow = set()   # allow-until-quit / timed (memory only)
session_expiry = {}     # allow rule-key -> epoch seconds; only for timed rules
forever_allow = set()   # allow-forever (persisted)
session_deny = set()    # deny-until-quit / timed (memory only)
deny_expiry = {}        # deny rule-key -> epoch seconds; only for timed rules
forever_deny = set()    # deny-forever (persisted); takes precedence over allow
decision_q = None       # Queue of (host, port, future); set in main()
verbose = False         # log every allowed connection
log_blocks = True       # log the first time a deny rule auto-blocks a dest
_deny_logged = set()    # (host,port) already logged as auto-denied; dedupe spam
stats = {"seen": 0, "allowed": 0, "denied": 0}
access_log = {}         # host -> {count, denied, ports}; session only
_resolve_cache = {}     # host -> set(ip): name<->dest-IP cross-check cache
# \A...\Z not ^...$: `$` also matches before a trailing \n, letting "github.com\n"
# slip past the anti-spoofing guard.
_IP_RE = re.compile(r"\A[0-9A-Fa-f:.]+\Z")
_HOSTNAME_RE = re.compile(r"\A[A-Za-z0-9._-]{1,253}\Z")
RESOLVER_V4 = []        # pinned IPv4 nameservers; set in setup_iptables()
_dns_qid = 0            # rolling query id for marked lookups
_dns_inflight = {}      # resolver-ip -> Future: coalesce DNS prompts
_tcp_inflight = {}      # (host,port,ip) -> Future: coalesce TCP prompts

# Caps so a sandbox spamming unique names can't grow these dicts unbounded;
# both are best-effort caches, so eviction under churn is harmless.
_RESOLVE_CACHE_MAX = 4096
_ACCESS_LOG_MAX = 4096
# Distinct decisions awaiting an answer; beyond it new dests fail CLOSED.
_MAX_PENDING = 256
# Concurrent DNS relays; beyond it datagrams drop (DNS fails closed).
_MAX_DNS_INFLIGHT = 256
_dns_serving = 0        # in-flight serve_dns tasks


class QuitConsole(Exception):
    pass


def load_rules():
    try:
        with open(RULES_FILE) as f:
            data = json.load(f)
        for h in data.get("allow", []):
            forever_allow.add(h)
        for h in data.get("deny", []):
            forever_deny.add(h)
    except Exception:
        pass


def save_rules():
    try:
        os.makedirs(os.path.dirname(RULES_FILE), exist_ok=True)
        tmp = RULES_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"allow": sorted(forever_allow),
                       "deny": sorted(forever_deny)}, f, indent=2)
        os.replace(tmp, RULES_FILE)
    except Exception as e:
        print(f"[boxwall] WARN: could not persist rules: {e}", file=sys.stderr)


def resolver_ips():
    # Nameservers from the netns resolv.conf (set by Docker/host, not the
    # sandbox). DNS may reach only THESE, so the sandbox can't dial an
    # attacker-run NS directly. Charset-validated before shelling out.
    v4, v6 = [], []
    try:
        with open("/etc/resolv.conf") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2 and parts[0] == "nameserver" and _IP_RE.match(parts[1]):
                    (v6 if ":" in parts[1] else v4).append(parts[1])
    except Exception:
        pass
    return v4, v6


def _run_rule(cmd, critical, failures):
    rc = subprocess.run(cmd, shell=True).returncode
    if rc != 0:
        if critical:
            failures.append(f"rule failed (rc={rc}): {cmd}")
        else:
            print(f"[boxwall] WARN: rule failed (rc={rc}): {cmd}", file=sys.stderr)
    return rc == 0


def _fail_closed_and_exit(failures):
    # Fail CLOSED before bailing: drop everything but loopback.
    for cmd in (
        "iptables -P OUTPUT DROP", "iptables -t nat -F OUTPUT", "iptables -F OUTPUT",
        "iptables -A OUTPUT -o lo -j ACCEPT", "iptables -A OUTPUT -j DROP",
        "ip6tables -P OUTPUT DROP", "ip6tables -F OUTPUT",
        "ip6tables -A OUTPUT -o lo -j ACCEPT", "ip6tables -A OUTPUT -j DROP",
    ):
        subprocess.run(cmd, shell=True)
    for m in failures:
        print(f"[boxwall] FATAL: {m}", file=sys.stderr)
    print("[boxwall] refusing to run with an incomplete ruleset; egress is now "
          "fail-closed. Fix the environment and restart.", file=sys.stderr)
    sys.exit(1)


def has_global_ipv6():
    # True if a non-loopback iface has a global IPv6 addr (egress possible).
    # /proc/net/if_inet6 scope field "00" == global (link-local fe80:: is "20").
    try:
        with open("/proc/net/if_inet6") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 6 and parts[3] == "00" and parts[5] != "lo":
                    return True
    except Exception:
        pass
    return False


def setup_ip6tables(v6res, failures):
    # Proxy + interceptor are IPv4-only, so IPv6 can't be gated; lock it to
    # loopback (incl. v6 DNS, else a silent egress channel). Same fail-closed
    # ordering as v4: policy DROP before the flush.
    subprocess.run("ip6tables -P OUTPUT DROP", shell=True)
    if subprocess.run("ip6tables -F OUTPUT", shell=True).returncode != 0:
        # If a global v6 address is present we can't fail-closed; abort.
        if has_global_ipv6():
            failures.append("ip6tables unavailable but a global IPv6 address is "
                            "present, cannot fail-closed on IPv6 egress")
        else:
            print("[boxwall] note: ip6tables unavailable and no global IPv6 address; "
                  "assuming no IPv6 egress path.", file=sys.stderr)
        return
    _run_rule("ip6tables -A OUTPUT -o lo -j ACCEPT", True, failures)
    _run_rule("ip6tables -A OUTPUT -j DROP", True, failures)


def setup_iptables():
    v4res, v6res = resolver_ips()
    if not v4res:
        print("[boxwall] WARN: no IPv4 nameserver in resolv.conf; external DNS will be "
              "blocked (loopback resolver still works).", file=sys.stderr)
    failures = []
    # route_localnet (so the kernel will route/deliver the REDIRECT-to-127.0.0.1
    # packets at all rather than treating 127/8 as martian) is set on the holder at
    # creation via --sysctl/endpoint driver-opt, incl. per-interface eth0. It can't
    # be set from here: this console shares the holder's netns, where /proc/sys/net
    # is a read-only mount. NOTE: route_localnet alone is not sufficient on every
    # kernel -- it does not reliably move the packet's oif to lo -- so the FILTER
    # chain below also accepts by destination (127.0.0.0/8), not just '-o lo'.
    # Fail CLOSED while (re)building: OUTPUT policy DROP *before* the flush, else
    # the flush..catch-all window runs default-ACCEPT on an empty chain. Policy
    # persists in the holder's netns, so "console down" stays closed.
    _run_rule("iptables -P OUTPUT DROP", True, failures)
    # Flush so re-attaching a fresh console doesn't stack duplicate rules.
    for f in ("iptables -t nat -F OUTPUT", "iptables -F OUTPUT"):
        _run_rule(f, False, failures)

    # NAT: redirect sandbox TCP -> proxy, UDP DNS -> interceptor. The proxy's own
    # sockets carry fwmark MARK and RETURN before any REDIRECT, so nothing it
    # emits loops back into itself. Holds even at uid 0.
    _run_rule("iptables -t nat -A OUTPUT -o lo -j RETURN", True, failures)
    _run_rule(f"iptables -t nat -A OUTPUT -m mark --mark {MARK} -j RETURN", True, failures)
    # Sandbox UDP DNS to the real resolver -> interceptor; else dropped by FILTER.
    for r in v4res:
        _run_rule(f"iptables -t nat -A OUTPUT -p udp -d {r} --dport 53 -j REDIRECT --to-ports {DNS_PORT}", False, failures)
    # All TCP (incl. TCP DNS) -> the proxy.
    _run_rule(f"iptables -t nat -A OUTPUT -p tcp -j REDIRECT --to-ports {PORT}", True, failures)

    # FILTER: allow loopback (REDIRECT DNATs to 127.0.0.1) + the proxy's marked
    # sockets, DROP the rest. The catch-all blocks ICMP/SCTP/GRE/QUIC/HTTP3 exfil
    # the TCP-only REDIRECT wouldn't cover.
    #
    # The REDIRECT'd packet's dst is rewritten to 127.0.0.1, but on some Docker/
    # kernel combos (observed on Docker Desktop's LinuxKit kernel even with
    # route_localnet=1 set on all/lo/eth0) the post-DNAT reroute does NOT move the
    # packet's output interface to lo, so it reaches this chain with oif=eth0,
    # misses '-o lo ACCEPT', and dies on the catch-all DROP -- the proxy never
    # sees the connection. Accept by DESTINATION instead: 127/8 can never egress a
    # real interface, so this is local-only and exactly as safe as the -o lo rule,
    # but it doesn't depend on the reroute happening. Keep BOTH (lo by-iface covers
    # genuine loopback traffic; 127/8 by-dest covers the redirected flows).
    _run_rule("iptables -A OUTPUT -o lo -j ACCEPT", True, failures)
    _run_rule("iptables -A OUTPUT -d 127.0.0.0/8 -j ACCEPT", True, failures)
    _run_rule(f"iptables -A OUTPUT -m mark --mark {MARK} -j ACCEPT", True, failures)
    _run_rule("iptables -A OUTPUT -j DROP", True, failures)

    setup_ip6tables(v6res, failures)

    if failures:
        _fail_closed_and_exit(failures)

    global RESOLVER_V4
    RESOLVER_V4 = list(v4res)


def original_dst(sock):
    data = sock.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
    port = struct.unpack_from("!H", data, 2)[0]
    ip = socket.inet_ntoa(data[4:8])
    return ip, port


def clean_name(name):
    # SNI/Host come from the untrusted sandbox and print raw into the prompt.
    # Reject anything that isn't a real hostname (control bytes, ANSI, spaces,
    # non-ASCII) so it can't redraw the prompt to spoof the dest. Rejects fall
    # back to a bare-IP prompt.
    if not name:
        return None
    name = name.strip().rstrip(".")
    return name.lower() if _HOSTNAME_RE.match(name) else None


def parse_sni(data):
    try:
        if not data or data[0] != 0x16:        # TLS handshake record
            return None
        if data[5] != 0x01:                    # ClientHello
            return None
        idx = 5 + 4 + 2 + 32                    # record + hs hdr + ver + random
        sid_len = data[idx]; idx += 1 + sid_len
        cs_len = struct.unpack_from("!H", data, idx)[0]; idx += 2 + cs_len
        comp_len = data[idx]; idx += 1 + comp_len
        ext_total = struct.unpack_from("!H", data, idx)[0]; idx += 2
        end = idx + ext_total
        while idx + 4 <= end:
            etype, elen = struct.unpack_from("!HH", data, idx); idx += 4
            if etype == 0x0000:                # server_name extension
                ni = idx + 2 + 1               # list len + name type
                nlen = struct.unpack_from("!H", data, ni)[0]; ni += 2
                return data[ni:ni + nlen].decode("ascii", "replace")
            idx += elen
    except Exception:
        return None
    return None


def parse_http_host(data):
    try:
        first = data[:16].split(b" ", 1)[0]
        if not first.isalpha():
            return None
        for line in data.split(b"\r\n")[1:]:
            if line[:5].lower() == b"host:":
                return line.split(b":", 2)[1].strip().decode("latin1", "replace")
    except Exception:
        return None
    return None


async def read_head(reader):
    # Peek the first bytes for SNI/Host. A TLS ClientHello can span segments, so
    # keep reading (bounded, timed) until the record is complete, else a split
    # ClientHello hides the SNI and downgrades to a bare-IP prompt.
    try:
        head = await asyncio.wait_for(reader.read(4096), timeout=10)
    except Exception:
        return b""
    if head[:1] == b"\x16" and len(head) >= 5:
        need = 5 + struct.unpack_from("!H", head, 3)[0]
        while len(head) < need and len(head) < 16384:
            try:
                more = await asyncio.wait_for(reader.read(4096), timeout=5)
            except Exception:
                break
            if not more:
                break
            head += more
    return head


def _build_dns_query(qname, qid):
    # Minimal A-record query (recursion desired). Over-long labels clamped to 63
    # bytes so they fail to resolve rather than crash.
    q = struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    for label in qname.rstrip(".").split("."):
        lb = label.encode("ascii", "replace")[:63]
        q += bytes([len(lb)]) + lb
    return q + b"\x00" + struct.pack("!HH", 1, 1)   # QTYPE=A, QCLASS=IN


def _skip_dns_name(buf, idx):
    # Step over a (possibly compression-pointer'd) DNS name; return next offset.
    while idx < len(buf):
        n = buf[idx]
        if n == 0:
            return idx + 1
        if n & 0xC0 == 0xC0:                         # pointer: 2 bytes, name ends
            return idx + 2
        idx += 1 + n
    return idx


def _parse_dns_a(resp, qid):
    out = set()
    try:
        rid, _flags, qd, an, _ns, _ar = struct.unpack_from("!HHHHHH", resp, 0)
        if rid != qid:
            return out
        idx = 12
        for _ in range(qd):
            idx = _skip_dns_name(resp, idx) + 4      # + QTYPE + QCLASS
        for _ in range(an):
            idx = _skip_dns_name(resp, idx)
            rtype, _rclass, _ttl, rdlen = struct.unpack_from("!HHIH", resp, idx)
            idx += 10
            if rtype == 1 and rdlen == 4:            # A record
                out.add(socket.inet_ntoa(resp[idx:idx + 4]))
            idx += rdlen
    except Exception:
        pass
    return out


async def marked_resolve(host):
    # Resolve A records over a fwmark'd UDP socket to the pinned resolver. The
    # mark exempts these from the REDIRECT and FILTER drop, so the proxy can
    # resolve for its cross-check ungated. IPv4-only.
    global _dns_qid
    out = set()
    loop = asyncio.get_running_loop()
    for r in RESOLVER_V4:
        # Snapshot the id: this coroutine awaits below, and a concurrent
        # marked_resolve() bumping the shared global would make _parse_dns_a
        # check the wrong id and spuriously re-prompt.
        _dns_qid = (_dns_qid + 1) & 0xFFFF
        qid = _dns_qid
        query = _build_dns_query(host, qid)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, MARK)
            s.setblocking(False)
            await loop.sock_connect(s, (r, 53))
            await loop.sock_sendall(s, query)
            resp = await asyncio.wait_for(loop.sock_recv(s, 4096), timeout=3)
            out |= _parse_dns_a(resp, qid)
        except Exception:
            pass
        finally:
            s.close()
        if out:
            break
    return out


def _note_access(host, port):
    # Bump the session access log, evicting the least-active host at the cap.
    entry = access_log.get(host)
    if entry is None:
        if len(access_log) >= _ACCESS_LOG_MAX:
            del access_log[min(access_log, key=lambda h: access_log[h]["count"])]
        entry = access_log.setdefault(host, {"count": 0, "denied": 0, "ports": set()})
    entry["count"] += 1
    entry["ports"].add(port)
    return entry


async def name_matches_ip(host, ip):
    # Does the claimed name resolve (via our pinned resolver) to the IP the
    # sandbox is dialing? If not, the SNI/Host is spoofed and can't match a rule.
    # Cache + re-resolve on miss to cope with CDN/round-robin.
    # A literal-IP SNI/Host (e.g. `curl 1.1.1.1`, where Host: is the IP itself)
    # can't be DNS-resolved -- the lookup just fails and prints a spurious
    # "does not resolve" WARN. If the claimed name IS the dialed IP, it trivially
    # matches; no lookup needed.
    if host == ip:
        return True
    ips = _resolve_cache.get(host, set())
    if ip in ips:
        return True
    try:
        ips = ips | await marked_resolve(host)
    except Exception:
        pass
    _resolve_cache[host] = ips
    while len(_resolve_cache) > _RESOLVE_CACHE_MAX:
        # FIFO eviction (dicts preserve insertion order); drop the oldest entry.
        _resolve_cache.pop(next(iter(_resolve_cache)))
    return ip in ips


def parent_domain(host):
    # Best-effort registrable domain for the "domain + subdomains" scope: the
    # last two labels (api.anthropic.com -> anthropic.com). A literal IP or a
    # single-label name has no domain. This is necessarily a heuristic (it
    # doesn't know multi-part TLDs like .co.uk).
    if _IP_RE.match(host):
        return None
    labels = host.split(".")
    if len(labels) < 2:
        return None
    return ".".join(labels[-2:])


def scope_target(host, port, scope):
    # Map a scope letter to the rule key it should store and a human label.
    # None/"" -> this exact host:port (the default, narrowest scope).
    #   a -> "*"            any connection (every host, every port)
    #   p -> "*:PORT"       any host on this port
    #   h -> "host"         any port on this host (bare host)
    #   s -> "*.domain"     this domain and all its subdomains (any port)
    if scope == "a":
        return "*", "any connection"
    if scope == "p":
        return f"*:{port}", f"any host on port {port}"
    if scope == "h":
        return host, f"any port on {host}"
    if scope == "s":
        dom = parent_domain(host)
        if dom:
            return f"*.{dom}", f"*.{dom} (domain + subdomains)"
        # No domain to generalize to (IP / single label) -> fall back to exact.
    return f"{host}:{port}", f"{host}:{port}"


def _rule_live(key, store, expiry):
    # A timed session rule is live until its expiry; sweep it on expiry so it
    # stops matching (and the rules listing reflects reality).
    exp = expiry.get(key)
    if exp is None:
        return True
    if exp > time.time():
        return True
    store.discard(key)
    expiry.pop(key, None)
    return False


def _covered_by(store, host, port, expiry=None):
    # Returns the matching rule key in `store` covering (host, port), or None.
    # (A key string is truthy and None falsy, so boolean callers are unaffected.)
    # Handles the global wildcard, per-port wildcard, bare-host (any port), exact
    # host:port, and *.domain subdomain rules. Pass `expiry` for a session store
    # so expired timed rules are swept and don't count as matches. Keys are tried
    # most-specific first so the reported match is the meaningful one.
    keys = []
    hp = f"{host}:{port}"
    if hp in store:
        keys.append(hp)
    if host in store:
        keys.append(host)
    for rule in store:
        if rule.startswith("*."):
            base = rule[2:]                      # "*.anthropic.com" -> "anthropic.com"
            if host == base or host.endswith("." + base):
                keys.append(rule)
    pw = f"*:{port}"
    if pw in store:
        keys.append(pw)
    if "*" in store:
        keys.append("*")
    if not keys:
        return None
    if expiry is None:
        return keys[0]
    for k in keys:
        if _rule_live(k, store, expiry):
            return k
    return None


def matches(host, port):
    # Allow-list match (the name 'matches' is kept for existing callers).
    return (_covered_by(forever_allow, host, port)
            or _covered_by(session_allow, host, port, session_expiry))


def matches_deny(host, port):
    # Deny-list match; checked before the allow-list so an explicit block wins.
    return (_covered_by(forever_deny, host, port)
            or _covered_by(session_deny, host, port, deny_expiry))


def _log_deny(host, port, rule):
    # Surface auto-blocks once per (host,port) so deny rules aren't invisible,
    # without spamming a line per connection. `history`/deny counts show volume.
    if not log_blocks:
        return
    sig = (host, port)
    if sig in _deny_logged:
        return
    if len(_deny_logged) > _ACCESS_LOG_MAX:
        _deny_logged.clear()
    _deny_logged.add(sig)
    via = "" if rule == f"{host}:{port}" else f" {C_DIM}({rule}){C_RESET}"
    print(f"\n[boxwall] {C_NO}blocked{C_RESET} {host}:{port} by deny rule{via}")


async def decide(host, port, ip):
    # Explicit deny rules win and never prompt; then known allows skip the queue.
    dkey = matches_deny(host, port)
    if dkey:
        _log_deny(host, port, dkey)
        return False
    if matches(host, port):
        return True
    # Coalesce concurrent connections to the SAME destination onto one prompt.
    key = (host, port, ip)
    existing = _tcp_inflight.get(key)
    if existing is not None:
        return await asyncio.shield(existing)
    # Fail CLOSED under a flood of distinct destinations.
    if len(_tcp_inflight) >= _MAX_PENDING:
        return False
    # Hand the question to the console task and wait for the answer.
    loop = asyncio.get_running_loop()
    fut = loop.create_future()
    _tcp_inflight[key] = fut
    await decision_q.put((host, port, ip, fut))
    try:
        return await fut
    finally:
        _tcp_inflight.pop(key, None)


async def pipe(reader, writer):
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(reader, writer):
    peer_sock = writer.get_extra_info("socket")
    try:
        ip, port = original_dst(peer_sock)
    except Exception:
        writer.close(); return

    head = await read_head(reader)

    # Resolve a sandbox-supplied name ONLY to validate it against an approved
    # rule; resolving arbitrary names is itself a DNS exfil channel. So:
    #   * name in a rule -> cross-check it points at this IP (blocks
    #     SNI=github.com -> attacker IP);
    #   * unknown name -> don't resolve; prompt on the name but show the real IP.
    sni = clean_name(parse_sni(head) or parse_http_host(head))
    if sni and matches(sni, port):
        if await name_matches_ip(sni, ip):
            host = sni
        else:
            print(f"\n[boxwall] {C_NO}WARN{C_RESET} approved name {sni!r} does not "
                  f"resolve to {ip}; treating destination as {ip}.")
            host = ip
    else:
        host = sni or ip

    stats["seen"] += 1
    entry = _note_access(host, port)

    if not await decide(host, port, ip):
        stats["denied"] += 1
        entry["denied"] += 1
        writer.close(); return
    stats["allowed"] += 1
    if verbose:
        print(f"[boxwall] {C_OK}->{C_RESET} {host}:{port}")

    try:
        up = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        up.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, MARK)
        up.setblocking(False)
        await asyncio.get_running_loop().sock_connect(up, (ip, port))
        ur, uw = await asyncio.open_connection(sock=up)
    except Exception as e:
        print(f"[boxwall] upstream connect failed {host}:{port}: {e}", file=sys.stderr)
        writer.close(); return

    if head:
        uw.write(head)
        await uw.drain()

    await asyncio.gather(pipe(reader, uw), pipe(ur, writer))


def _origdst_from_ancdata(ancdata):
    # Recover the pre-REDIRECT dst (real resolver) from a datagram's
    # IP_ORIGDSTADDR cmsg. sockaddr_in: family, port(net), addr(net).
    for level, ctype, cdata in ancdata:
        if level == socket.IPPROTO_IP and ctype == IP_ORIGDSTADDR and len(cdata) >= 8:
            port = struct.unpack_from("!H", cdata, 2)[0]
            return socket.inet_ntoa(cdata[4:8]), port
    return None


async def _dns_allowed(rip, rport):
    # Gate DNS like any dest, but prompt once per resolver: coalesce concurrent
    # queries to the same resolver onto one decision.
    if matches(rip, rport):
        return True
    fut = _dns_inflight.get(rip)
    if fut is not None:
        return await fut
    fut = asyncio.ensure_future(decide(rip, rport, rip))
    _dns_inflight[rip] = fut
    try:
        return await fut
    finally:
        _dns_inflight.pop(rip, None)


async def serve_dns(listener, data, src, origdst):
    # One redirected DNS datagram: prompt once for the resolver, relay over a
    # marked socket, hand the reply back. conntrack rewrites the reply source to
    # resolver:53 so the sandbox's stub sees a normal answer.
    #
    # Recover which pinned resolver this datagram targeted. On some kernels the
    # REDIRECT'd UDP arrives without a usable conntrack original-dst, so
    # IP_ORIGDSTADDR comes back as the interceptor's OWN 127.0.0.1:DNS_PORT. We
    # only ever REDIRECT the pinned resolver(s), so when the recovered dst is
    # loopback/missing, fall back to the first pinned resolver rather than relaying
    # to ourselves (which just loops: "dns relay failed 127.0.0.1:<DNS_PORT>").
    if origdst is not None and not origdst[0].startswith("127."):
        rip, rport = origdst
    elif RESOLVER_V4:
        rip, rport = RESOLVER_V4[0], 53
    else:
        return
    stats["seen"] += 1
    entry = _note_access(rip, rport)
    if not await _dns_allowed(rip, rport):
        stats["denied"] += 1
        entry["denied"] += 1
        return
    stats["allowed"] += 1
    if verbose:
        print(f"[boxwall] {C_OK}->{C_RESET} {rip}:{rport} (dns)")
    loop = asyncio.get_running_loop()
    up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        up.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, MARK)
        up.setblocking(False)
        await loop.sock_connect(up, (rip, rport))
        await loop.sock_sendall(up, data)
        resp = await asyncio.wait_for(loop.sock_recv(up, 4096), timeout=5)
    except Exception as e:
        print(f"[boxwall] dns relay failed {rip}:{rport}: {e}", file=sys.stderr)
        return
    finally:
        up.close()
    try:
        listener.sendto(resp, src)          # conntrack un-NATs source -> rip:53
    except Exception:
        pass


def make_dns_listener():
    # UDP socket the sandbox's DNS is REDIRECT'd to; IP_RECVORIGDSTADDR recovers
    # which resolver each datagram targeted.
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.IPPROTO_IP, IP_ORIGDSTADDR, 1)
    s.bind(("127.0.0.1", DNS_PORT))
    s.setblocking(False)
    return s


async def _serve_dns_tracked(listener, data, src, origdst):
    global _dns_serving
    try:
        await serve_dns(listener, data, src, origdst)
    finally:
        _dns_serving -= 1


def on_dns_readable(listener):
    # add_reader callback: drain one datagram + its orig-dst, hand off async.
    # Never raise out of the reader (would kill the loop).
    global _dns_serving
    try:
        data, ancdata, _flags, src = listener.recvmsg(4096, socket.CMSG_SPACE(64))
    except Exception:
        return
    if _dns_serving >= _MAX_DNS_INFLIGHT:    # flood: drop datagram, DNS fails closed
        return
    _dns_serving += 1
    asyncio.ensure_future(
        _serve_dns_tracked(listener, data, src, _origdst_from_ancdata(ancdata)))


def cmd_help(args):
    print(
        f"{C_HDR}commands{C_RESET} (type and press Enter):\n"
        f"  {_key('help')}, {_key('h')}, {_key('?')}           show this help\n"
        f"  {_key('rules')}, {_key('ls')}            list active allow + deny rules (forever + session)\n"
        f"  {_key('history')}, {_key('log')}         hosts accessed this session (history clear to reset)\n"
        f"  {_key('config')}               show settings + stats ({_key('config verbose on|off')})\n"
        f"  {_key('allow')} <target>...    add allow-forever rule(s) (scopes below)\n"
        f"  {_key('deny')}, {_key('block')} <target> add deny-forever rule(s) (auto-blocked, no prompt)\n"
        f"  {_key('forget')} <target>...   remove rule(s) from allow + deny (forever + session)\n"
        f"  {_key('reload')}               re-read the rules file from disk\n"
        f"  {_key('clear')}                drop all session rules (until-quit + timed)\n"
        f"  {_key('quit')}, {_key('exit')}           stop the boxwall (sandbox then has no network)\n"
        f"\n{C_HDR}connection prompt{C_RESET} = {C_B}<action><duration>{C_RESET}[{C_ASK}scope{C_RESET}]:\n"
        f"  {C_OK}allow{C_RESET}   {_key('ao')} once   {_key('aq')} until-quit   {_key('a1m')}/{_key('a1h')} timed   {_key('af')} forever\n"
        f"  {C_NO}deny{C_RESET}    {_key('do')} once   {_key('dq')} until-quit   {_key('d1m')}/{_key('d1h')} timed   {_key('df')} forever\n"
        f"  {C_ASK}scope{C_RESET}   append a letter (default = this exact host:port):\n"
        f"            {_key('h')} this host, any port  (host:*)   "
        f"{_key('p')} this port, any host  (*:port)\n"
        f"            {_key('s')} this domain + subdomains (*.dom)   {_key('*')} anything (*)\n"
        f"  plain {_key('⏎')} (or a bare {_key('d')}) = deny just this one connection.\n"
        f"\n{C_HDR}rule targets{C_RESET} (for allow/deny/forget) use the same scope keys as stored:\n"
        f"  {C_B}host:port{C_RESET}  exact   {C_DIM}·{C_RESET}   {C_B}host{C_RESET}  any port   {C_DIM}·{C_RESET}   {C_B}*:port{C_RESET}  any host on port\n"
        f"  {C_B}*.domain{C_RESET}   domain + subdomains   {C_DIM}·{C_RESET}   {C_B}*{C_RESET}  any connection"
    )


def _print_rule_set(title, forever_set, session_set, expiry):
    now = time.time()
    print(title)
    if not forever_set and not session_set:
        print("  (none)")
        return
    for h in sorted(forever_set):
        print(f"  {h}  (forever)")
    for h in sorted(session_set):
        exp = expiry.get(h)
        if exp is None:
            suffix = "until quit"
        else:
            rem = int(exp - now)
            suffix = f"{rem // 60}m{rem % 60:02d}s left" if rem > 0 else "expired"
        print(f"  {h}  ({suffix})")


def cmd_rules(args):
    _print_rule_set("allow:", forever_allow, session_allow, session_expiry)
    _print_rule_set("deny:", forever_deny, session_deny, deny_expiry)


def cmd_history(args):
    if args and args[0] == "clear":
        access_log.clear()
        print("[boxwall] session history cleared")
        return
    if not access_log:
        print("no connections seen this session yet")
        return
    # Flag reflects coverage by ANY rule (incl. wildcard/domain). Deny wins, so
    # check it first: X=deny rule, F=allow-forever, U=allow-session, -=neither.
    print(f"     {'host':<34} {'hits':>5} {'deny':>5}  ports")
    for host, e in sorted(access_log.items(), key=lambda kv: kv[1]["count"], reverse=True):
        ports = sorted(e["ports"])
        if any(_covered_by(forever_deny, host, p) for p in ports) or \
           any(_covered_by(session_deny, host, p, deny_expiry) for p in ports):
            flag = "X"
        elif any(_covered_by(forever_allow, host, p) for p in ports):
            flag = "F"
        elif any(_covered_by(session_allow, host, p, session_expiry) for p in ports):
            flag = "U"
        else:
            flag = "-"
        portstr = ",".join(str(p) for p in ports)
        print(f"[{flag}] {host:<34} {e['count']:>5} {e['denied']:>5}  {portstr}")


def cmd_config(args):
    global verbose, log_blocks
    if args and args[0] == "verbose" and len(args) >= 2:
        verbose = args[1].lower() in ("on", "true", "1", "yes")
        print(f"[boxwall] verbose {'on' if verbose else 'off'}")
        return
    if args and args[0] == "blocks" and len(args) >= 2:
        log_blocks = args[1].lower() in ("on", "true", "1", "yes")
        print(f"[boxwall] blocks logging {'on' if log_blocks else 'off'}")
        return
    if args:
        print("usage: config              show settings + stats")
        print("       config verbose on|off   (log every allowed connection)")
        print("       config blocks on|off    (log deny-rule auto-blocks)")
        return
    print(f"  port        {PORT}")
    print(f"  rules-file  {RULES_FILE}")
    print(f"  verbose     {'on' if verbose else 'off'}")
    print(f"  blocks      {'on' if log_blocks else 'off'} (log deny-rule auto-blocks)")
    print(f"  default     deny (prompt on every new destination)")
    print(f"  allow       {len(forever_allow)} forever, {len(session_allow)} session"
          f" ({len(session_expiry)} timed)")
    print(f"  deny        {len(forever_deny)} forever, {len(session_deny)} session"
          f" ({len(deny_expiry)} timed)")
    print(f"  stats       seen={stats['seen']} "
          f"allowed={stats['allowed']} denied={stats['denied']}")


def cmd_allow(args):
    if not args:
        print("usage: allow <target>...  (host:port | host | *:port | *.domain | *)")
        return
    for t in args:
        forever_allow.add(t)
        forever_deny.discard(t); session_deny.discard(t); deny_expiry.pop(t, None)
    save_rules()
    print(f"[boxwall] {C_OK}allow forever{C_RESET} {' '.join(args)}")


def cmd_deny(args):
    if not args:
        print("usage: deny <target>...  (host:port | host | *:port | *.domain | *)")
        return
    for t in args:
        forever_deny.add(t)
        forever_allow.discard(t); session_allow.discard(t); session_expiry.pop(t, None)
    _deny_logged.clear()
    save_rules()
    print(f"[boxwall] {C_NO}deny forever{C_RESET} {' '.join(args)}")


def cmd_forget(args):
    if not args:
        print("usage: forget <host[:port]>...")
        return
    # `forget host` drops the bare-host rule and all its host:port rules;
    # `forget host:port` drops just that one. Clears both allow and deny.
    removed = []
    for h in args:
        for store, expiry in ((forever_allow, session_expiry),
                              (session_allow, session_expiry),
                              (forever_deny, deny_expiry),
                              (session_deny, deny_expiry)):
            for key in list(store):
                base = key.rsplit(":", 1)[0] if ":" in key else key
                if key == h or base == h:
                    store.discard(key)
                    expiry.pop(key, None)
                    removed.append(key)
    _deny_logged.clear()
    save_rules()
    print(f"[boxwall] forgot {' '.join(removed) if removed else '(nothing matched)'}")


def cmd_reload(args):
    forever_allow.clear()
    forever_deny.clear()
    _deny_logged.clear()
    load_rules()
    print(f"[boxwall] reloaded {len(forever_allow)} allow + {len(forever_deny)} "
          f"deny rule(s) from {RULES_FILE}")


def cmd_clear(args):
    n = len(session_allow) + len(session_deny)
    session_allow.clear(); session_expiry.clear()
    session_deny.clear(); deny_expiry.clear()
    _deny_logged.clear()
    print(f"[boxwall] cleared {n} session rule(s)")


COMMANDS = {
    "help": cmd_help, "h": cmd_help, "?": cmd_help,
    "rules": cmd_rules, "ls": cmd_rules,
    "history": cmd_history, "log": cmd_history,
    "config": cmd_config, "cfg": cmd_config,
    "allow": cmd_allow,
    "deny": cmd_deny, "block": cmd_deny,
    "forget": cmd_forget, "unblock": cmd_forget,
    "reload": cmd_reload,
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
        print(f"[boxwall] unknown command: {name!r} (try 'help')")
        return
    fn(cargs)


_TIMED_RE = re.compile(r"(\d+)\s*([mh])")


def parse_answer(raw):
    # Answer grammar: <action><duration>[scope], read left-to-right (and order-
    # tolerant). Returns (action, dur, scope) where:
    #   action: "allow" (a, also the default) | "deny" (d)
    #   dur:    "o" once | "q" until-quit | "f" forever | ("t", secs) timed | None
    #   scope:  None (this host:port) | "h" | "p" | "s" | "a" (typed as *)
    # Examples: ao=allow once · af=allow forever · do=deny once · df=deny forever
    # · dfs=deny *.domain forever · af*=allow anything forever · a1m=allow 1 min.
    # Empty Enter (or a bare d) = deny just this one connection.
    # ('u' is accepted as an alias for 'q' until-quit.)
    s = raw.strip().lower()
    action, dur, scope = "allow", None, None
    m = _TIMED_RE.search(s)
    if m:
        n = int(m.group(1))
        dur = ("t", n * (3600 if m.group(2) == "h" else 60))
        s = s[:m.start()] + s[m.end():]          # strip so its digits/suffix don't re-parse
    for ch in s:
        if ch == "d":
            action = "deny"
        elif ch == "a":
            action = "allow"                     # a = allow action (no longer a scope)
        elif dur is None and ch in "oqfu":
            dur = "q" if ch in "qu" else ch      # q = until-quit (u is an alias)
        elif ch in "hps*":
            scope = "a" if ch == "*" else ch     # * = the "any connection" scope
    return action, dur, scope


def _fmt_duration(secs):
    if secs < 3600:
        return f"{secs // 60} min"
    return f"{secs // 3600}h{(secs % 3600) // 60:02d}m"


def _commit(store_f, store_s, expiry_s, other_f, other_s, key, dur):
    # Add `key` to the forever or session set for a given action, dropping the
    # exact same key from the opposite action's sets so it lives in one place.
    other_f.discard(key); other_s.discard(key)
    if dur == "f":
        store_f.add(key); save_rules()
    elif dur == "q":
        store_s.add(key); expiry_s.pop(key, None)
    else:                                          # ("t", secs)
        store_s.add(key); expiry_s[key] = time.time() + dur[1]


def apply_answer(host, port, raw):
    # Returns True (allow), False (deny), or None (incomplete -> reprompt, don't
    # resolve the pending decision).
    action, dur, scope = parse_answer(raw)
    denying = action == "deny"

    if dur is None:
        # No duration named. An empty Enter or a bare 'd' = deny just this one
        # connection (the default policy). Anything else named WHO (action/scope)
        # but not HOW LONG -- guide to the full form, don't guess.
        raws = raw.strip().lower()
        if raws in ("", "d"):
            print(f"[boxwall] {C_NO}deny{C_RESET} {host}:{port}")
            return False
        pre = "d" if denying else "a"
        ex = ""
        if scope is not None:
            disp = "*" if scope == "a" else scope
            ex = f"  (e.g. {C_B}{pre}f{disp}{C_RESET})"
        print(f"[boxwall] add a duration — {C_B}{pre}o{C_RESET} once  "
              f"{C_B}{pre}q{C_RESET} quit  {C_B}{pre}f{C_RESET} forever  "
              f"{C_B}{pre}1m{C_RESET} timed{ex}.  just {C_B}⏎{C_RESET} = deny once.")
        return None

    if dur == "o":
        # Once applies to just this single connection; no rule is stored.
        verb = ("deny", C_NO) if denying else ("allow", C_OK)
        print(f"[boxwall] {verb[1]}{verb[0]} once{C_RESET} {host}:{port}")
        return not denying

    key, label = scope_target(host, port, scope)
    word = _fmt_duration(dur[1]) if isinstance(dur, tuple) else (
        "forever" if dur == "f" else "until quit")
    if denying:
        _commit(forever_deny, session_deny, deny_expiry,
                forever_allow, session_allow, key, dur)
        print(f"[boxwall] {C_NO}deny {word}{C_RESET} {label}")
        return False
    _commit(forever_allow, session_allow, session_expiry,
            forever_deny, session_deny, key, dur)
    print(f"[boxwall] {C_OK}allow {word}{C_RESET} {label}")
    return True


def _key(k):
    # A typeable key, bold so it stands out from the surrounding label text.
    return f"{C_B}{k}{C_RESET}"


def prompt_line(pending):
    if pending:
        host, port, ip, _ = pending[0]
        where = f"{host}:{port}" if host == ip else f"{host}:{port} {C_DIM}({ip}){C_RESET}"
        dom = parent_domain(host)
        # Scope line offers how widely to apply the rule. Show the domain
        # option only when there's a domain to generalize to (not for bare IPs).
        # Label each scope by the rule it stores, with concrete values, so the
        # letter lines up with what stays fixed: h -> host:* , p -> *:port.
        scope = (f"  scope  {C_DIM}append{C_RESET} {_key('h')} {host}:* {C_DIM}(any port){C_RESET}  "
                 f"{_key('p')} *:{port} {C_DIM}(any host){C_RESET}"
                 + (f"  {_key('s')} *.{dom}" if dom else "")
                 + f"  {_key('*')} {C_DIM}anything{C_RESET}")
        sys.stdout.write(
            f"\n{C_ASK}[boxwall]{C_RESET} connection → {C_B}{where}{C_RESET}\n"
            f"  allow  {_key('ao')} once  {_key('aq')} until quit"
            f"  {_key('a1m')}/{_key('a1h')} timed  {_key('af')} forever\n"
            f"  deny   {_key('do')} once  {_key('dq')} until quit"
            f"  {_key('d1m')}/{_key('d1h')} timed  {_key('df')} forever"
            f"   {_key('⏎')} {C_DIM}= do{C_RESET}\n"
            f"{scope}\n"
            f"  {C_DIM}e.g.{C_RESET}  {_key('af*')} allow anything forever  {C_DIM}·{C_RESET}  "
            f"{_key('dfs')} deny domain forever  {C_DIM}·{C_RESET}  "
            f"{_key('aqs')} allow domain till quit\n"
            f"{C_ASK}>{C_RESET} "
        )
    else:
        sys.stdout.write(f"{C_HDR}boxwall>{C_RESET} ")
    sys.stdout.flush()


async def decision_printer(pending):
    # Sole consumer of decision_q; prompts when a decision is first in line.
    while True:
        item = await decision_q.get()
        pending.append(item)
        if len(pending) == 1:
            prompt_line(pending)


async def console(reader, pending):
    # Sole owner of stdin; never cancels a readline. Each line answers the front
    # pending decision if one waits, else parses as a command.
    print(f"{C_DIM}type {C_RESET}{C_B}help{C_RESET}{C_DIM} for commands and prompt keys.{C_RESET}")
    prompt_line(pending)
    while True:
        line = await reader.readline()
        if not line:                               # EOF (Ctrl-D)
            print("\n[boxwall] stdin closed; stopping.")
            return
        text = line.decode("utf-8", "replace").strip()
        if pending:
            host, port, ip, fut = pending[0]
            decision = apply_answer(host, port, text)
            if decision is None:
                # Incomplete answer; keep this decision pending and reprompt.
                pass
            else:
                pending.pop(0)
                if not fut.cancelled():
                    fut.set_result(decision)
        else:
            try:
                run_command(text)
            except QuitConsole:
                print("[boxwall] quit requested.")
                return
        prompt_line(pending)


async def connect_stdin():
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin
    )
    return reader


async def main():
    global decision_q
    load_rules()
    setup_iptables()
    decision_q = asyncio.Queue()
    pending = []
    # REDIRECT delivers to loopback, so binding 127.0.0.1 suffices and keeps the
    # proxy off the holder's bridge IP.
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    print(f"{C_HDR}[boxwall]{C_RESET} proxy listening on :{PORT}  rules={RULES_FILE}")
    dns_listener = None
    if RESOLVER_V4:
        try:
            dns_listener = make_dns_listener()
            asyncio.get_running_loop().add_reader(dns_listener.fileno(),
                                                  on_dns_readable, dns_listener)
            print(f"{C_HDR}[boxwall]{C_RESET} DNS interceptor on :{DNS_PORT} -> "
                  f"resolver(s) {', '.join(RESOLVER_V4)}")
        except Exception as e:
            print(f"[boxwall] WARN: DNS interceptor unavailable ({e}); DNS will be "
                  "blocked (egress stays fail-closed).", file=sys.stderr)
    print(f"{C_HDR}[boxwall]{C_RESET} {len(forever_allow)} allow + {len(forever_deny)} "
          f"deny rule(s) loaded.")
    reader = await connect_stdin()
    printer_task = asyncio.ensure_future(decision_printer(pending))
    console_task = asyncio.ensure_future(console(reader, pending))
    serve_task = asyncio.ensure_future(server.serve_forever())
    async with server:
        await asyncio.wait(
            {console_task, serve_task}, return_when=asyncio.FIRST_COMPLETED
        )
    if dns_listener is not None:
        asyncio.get_running_loop().remove_reader(dns_listener.fileno())
        dns_listener.close()
    printer_task.cancel()
    console_task.cancel()
    serve_task.cancel()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[boxwall] shutting down.")
