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
# SNI / HTTP Host (no decryption) and prompts o/u/f/d; DNS prompts once per
# resolver; everything else (ICMP/SCTP/QUIC/IPv6) drops.

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

Prompts (per new destination):
  o = allow once      u = allow until boxwall quits
  f = allow forever   d = deny (default if you just press Enter)

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

session_allow = set()   # allow-until-quit (memory only)
forever_allow = set()   # allow-forever (persisted)
decision_q = None       # Queue of (host, port, future); set in main()
verbose = False         # log every allowed connection
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
            for h in json.load(f).get("allow", []):
                forever_allow.add(h)
    except Exception:
        pass


def save_rules():
    try:
        os.makedirs(os.path.dirname(RULES_FILE), exist_ok=True)
        tmp = RULES_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"allow": sorted(forever_allow)}, f, indent=2)
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


def matches(host, port):
    # Rules key on (host, port): a bare "host" matches any port; an f/u rule
    # pins the port.
    hp = f"{host}:{port}"
    return (host in forever_allow or hp in forever_allow
            or host in session_allow or hp in session_allow)


async def decide(host, port, ip):
    # Known destinations skip the queue.
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
        "commands (type and press Enter):\n"
        "  help, h, ?           show this help\n"
        "  rules, ls            list active allow rules (forever + until-quit)\n"
        "  history, log         hosts accessed this session (history clear to reset)\n"
        "  config               show settings + stats\n"
        "  config verbose on|off  log every allowed connection\n"
        "  allow <host[:port]>  add allow-forever rule(s) (bare host = any port)\n"
        "  forget <host[:port]> remove rule(s) from forever + until-quit\n"
        "  reload               re-read the rules file from disk\n"
        "  clear                drop all until-quit rules\n"
        "  quit, exit           stop the boxwall (sandbox then has no network)\n"
        "\nconnection prompts: [o]nce  [u]ntil-quit  [f]orever  [d]eny"
    )


def cmd_rules(args):
    if forever_allow:
        print("forever (persisted):")
        for h in sorted(forever_allow):
            print(f"  {h}")
    else:
        print("forever (persisted): (none)")
    if session_allow:
        print("until-quit (session):")
        for h in sorted(session_allow):
            print(f"  {h}")
    else:
        print("until-quit (session): (none)")


def cmd_history(args):
    if args and args[0] == "clear":
        access_log.clear()
        print("[boxwall] session history cleared")
        return
    if not access_log:
        print("no connections seen this session yet")
        return
    # Flag: F=allow-forever, U=until-quit, -=denied/once (not a standing rule).
    print(f"     {'host':<34} {'hits':>5} {'deny':>5}  ports")
    for host, e in sorted(access_log.items(), key=lambda kv: kv[1]["count"], reverse=True):
        flag = "F" if host in forever_allow else ("U" if host in session_allow else "-")
        ports = ",".join(str(p) for p in sorted(e["ports"]))
        print(f"[{flag}] {host:<34} {e['count']:>5} {e['denied']:>5}  {ports}")


def cmd_config(args):
    global verbose
    if args and args[0] == "verbose" and len(args) >= 2:
        verbose = args[1].lower() in ("on", "true", "1", "yes")
        print(f"[boxwall] verbose {'on' if verbose else 'off'}")
        return
    if args:
        print("usage: config              show settings + stats")
        print("       config verbose on|off")
        return
    print(f"  port        {PORT}")
    print(f"  rules-file  {RULES_FILE}")
    print(f"  verbose     {'on' if verbose else 'off'}")
    print(f"  default     deny (prompt on every new destination)")
    print(f"  rules       {len(forever_allow)} forever, {len(session_allow)} until-quit")
    print(f"  stats       seen={stats['seen']} "
          f"allowed={stats['allowed']} denied={stats['denied']}")


def cmd_allow(args):
    if not args:
        print("usage: allow <host>...")
        return
    forever_allow.update(args)
    save_rules()
    print(f"[boxwall] {C_OK}allow forever{C_RESET} {' '.join(args)}")


def cmd_forget(args):
    if not args:
        print("usage: forget <host[:port]>...")
        return
    # `forget host` drops the bare-host rule and all its host:port rules;
    # `forget host:port` drops just that one.
    removed = []
    for h in args:
        for store in (forever_allow, session_allow):
            for key in list(store):
                base = key.rsplit(":", 1)[0] if ":" in key else key
                if key == h or base == h:
                    store.discard(key)
                    removed.append(key)
    save_rules()
    print(f"[boxwall] forgot {' '.join(removed) if removed else '(nothing matched)'}")


def cmd_reload(args):
    forever_allow.clear()
    load_rules()
    print(f"[boxwall] reloaded {len(forever_allow)} rule(s) from {RULES_FILE}")


def cmd_clear(args):
    n = len(session_allow)
    session_allow.clear()
    print(f"[boxwall] cleared {n} until-quit rule(s)")


COMMANDS = {
    "help": cmd_help, "h": cmd_help, "?": cmd_help,
    "rules": cmd_rules, "ls": cmd_rules,
    "history": cmd_history, "log": cmd_history,
    "config": cmd_config, "cfg": cmd_config,
    "allow": cmd_allow,
    "forget": cmd_forget, "deny": cmd_forget,
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


def apply_answer(host, port, raw):
    ans = raw.strip().lower()
    key = f"{host}:{port}"
    if ans == "f":
        forever_allow.add(key); save_rules()
        print(f"[boxwall] {C_OK}allow forever{C_RESET} {key}")
        return True
    if ans == "u":
        session_allow.add(key)
        print(f"[boxwall] {C_OK}allow until quit{C_RESET} {key}")
        return True
    if ans == "o":
        print(f"[boxwall] {C_OK}allow once{C_RESET} {key}")
        return True
    print(f"[boxwall] {C_NO}deny{C_RESET} {key}")
    return False


def prompt_line(pending):
    if pending:
        host, port, ip, _ = pending[0]
        where = f"{host}:{port}" if host == ip else f"{host}:{port} ({ip})"
        sys.stdout.write(
            f"\n{C_ASK}[boxwall]{C_RESET} connection -> \033[1m{where}{C_RESET}\n"
            f"  [o]nce  [u]ntil-quit  [f]orever  [d]eny (default): "
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
    cmd_help([])
    prompt_line(pending)
    while True:
        line = await reader.readline()
        if not line:                               # EOF (Ctrl-D)
            print("\n[boxwall] stdin closed; stopping.")
            return
        text = line.decode("utf-8", "replace").strip()
        if pending:
            host, port, ip, fut = pending.pop(0)
            if not fut.cancelled():
                fut.set_result(apply_answer(host, port, text))
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
    print(f"{C_HDR}[boxwall]{C_RESET} {len(forever_allow)} persisted allow rule(s) loaded.")
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
