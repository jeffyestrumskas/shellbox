# boxwatch

An opt-in, out-of-box activity recorder for a docker sandbox. It is a single self-contained file with the Dockerfile and collector embedded inline; no extra files to manage. Run it in a second window/pane; it records the sandbox's file, network, and process activity to a host log the sandbox can't see, kill, or scrub.

> Part of [shellbox](../README.md#architecture) — see the architecture diagram for how boxwatch fits with the sandbox box and boxwall.

## Requirements

- Docker Desktop / Docker Engine, able to run a `--privileged` container
- An eBPF-capable host kernel: **cgroup v2** + **BTF** (`bpftrace` runs inside the watcher, against the host kernel)
- Not compatible with `shellbox.sh --runsc` — gVisor services syscalls in userspace, so they never reach the host kernel for eBPF to see

## Usage

```bash
# window 1: start the watcher (stays running)
./boxwatch.sh

# window 2: start a sandbox whose activity is recorded
shellbox.sh --boxwatch
```

`shellbox.sh --boxwatch` refuses to start unless the watcher is already up, so a box can't run un-recorded. `exec` and `connect` stream to the window by default (`config verbose on`/`off` to change); all events are always written as JSONL:

```json
{"ts": 1749571200.12, "container": "shellbox-watched-8123", "ev": "connect", "pid": 4412, "comm": "curl", "ip": "160.79.104.10", "port": 443}
{"ts": 1749571200.34, "container": "shellbox-watched-8123", "ev": "open", "pid": 4412, "comm": "curl", "file": "/etc/ssl/certs/ca-certificates.crt", "write": false}
{"ts": 1749571201.05, "container": "shellbox-watched-8123", "ev": "exec", "pid": 4490, "comm": "sh", "file": "/usr/bin/apt-get"}
```

## How it works

shellbox.sh (which has docker access on the host) drops a small registration file under `~/.shellbox/watch/targets/` naming the sandbox's container id. The watcher reads it, maps the id to the container's cgroup, and (re)launches `bpftrace` with probes that bail unless the current task is in that cgroup — so it only ever records that one box. It never touches the docker socket.

On each (re)start the watcher prints `attaching probes …` then `capture live …`. **Capture is authoritative only from `capture live` onward** — a command in the brief attach window before it can be missed.

Three event types are captured: process **exec** (`sched:sched_process_exec`; `comm` is the exec'd program), **file** opens (`openat`, read vs write), and outbound **network** connects (`connect`, IPv4 + port). Because the watcher is a privileged container outside the box and its log dir is mounted only into the watcher — never into the sandbox — a rogue agent inside the box can't disable its own watching. Logs land in `~/.shellbox/watch/session-<stamp>/events.jsonl`.

Because event fields (process name, file path) come from the untrusted box, the collector hardens against them in several ways:

- **Sanitization** — every untrusted string is escaped to printable ASCII, so a crafted path can't inject terminal escapes into the operator's console or smuggle delimiters.
- **Trusted fields lead, untrusted strings trail** — the `bpftrace` wire format emits every trustworthy numeric field (cgroup, pid, open flags, ip, port) *before* `comm` and the filename. A box can set its own `comm` to arbitrary bytes (`prctl(PR_SET_NAME)`) including a tab; with the strings trailing, that can only blur the comm/filename boundary, not displace a numeric field — which previously crashed the parse and let a box silently drop its own `open`/`connect` events from the log.
- **`Z` confirmations are accepted only at BEGIN** — `bpftrace` reports each target's real cgroup id from its `BEGIN` block, before any syscall probe can fire. The collector refuses every `Z` line that arrives *after* the first real event, so a `Z` smuggled through a newline in a filename can't poison the trusted-id map. (This is now the load-bearing defense; the older "stop once all ids are known" cap silently failed when two targets shared one cgroup id.)
- **Attribution from confirmed cgroups only** — an event whose cgroup id isn't one of the confirmed ids is logged with `"suspect": true` and no container name, never attributed to another box.
- **Malformed lines are logged, not dropped** — a line we can't parse (e.g. a fragment left by a newline injected into a filename) is recorded as a `{"ev": "malformed", "suspect": true}` marker, so a box can't make activity vanish from the record by forcing a parse failure.
- **Bounded output** — the log rotates at a size cap and a per-second event rate cap drops excess (recorded as a `_dropped` marker), so a flooding box can't fill the host disk through the watcher.
- **Hardened cgroup resolution** — target cgroup dirs are matched on docker's id token (not a loose substring), and the resolved path is restricted to printable ASCII without `"`/`\` before it is embedded into the generated `bpftrace` program, so a path can neither mis-resolve to another container nor break out of the program's string literals.

> Capture is at the syscall layer for IPv4; raw-payload inspection, IPv6 connect decoding, and DNS-name resolution are out of scope — pair with `--boxwall` if you also want per-connection hostnames. One residual remains: a box can still forge an event line (via a newline in a filename) attributed to *its own* cgroup — provenance can't be re-checked at the eBPF-string layer. Forging an event onto *another* box additionally requires guessing that box's numeric cgroup id, which cgroup namespacing keeps hidden; such a guess, if wrong, lands as `suspect`. Terminal injection, `comm`-based event evasion, and `Z`-line cgroup poisoning are closed.

## Console commands

Type these in the boxwatch window (`help` lists them):

| Command | Description |
|---|---|
| `stats` | Event counts this session, incl. `suspect` (unconfirmed-cgroup) and `dropped` (rate-capped) |
| `tail [N] [types]` | Show the last N events (default 20); optionally filter to `exec`/`open`/`connect` |
| `targets` / `ls` | Containers currently being watched |
| `config` | Show settings; `config verbose <what>` echoes events live, where `<what>` is `on`/`off` or any of `exec`/`open`/`connect` (combinable). Default: `exec,connect` |
| `clear` | Clear the in-memory tail buffer |
| `quit` / `exit` | Stop the watcher (sandboxes keep running, unwatched) |

## Options

| Flag | Description |
|---|---|
| `--name NAME` | Watcher container name (default `shellbox-boxwatch`; match with `shellbox.sh --boxwatch-name`) |
| `--watch-dir DIR` | Where to write logs + read target registrations (default `~/.shellbox/watch`) |
| `--image IMAGE` | Full image name override (e.g. `myrepo:tag`) |
| `--rebuild` | Force a clean rebuild (needed to pick up collector changes) |
| `--no-build` | Skip the build step (assume the image already exists) |
| `--down` | Stop the watcher; attached sandboxes keep running, unwatched |

> Note: the collector is baked into the image, so after editing `boxwatch.sh` rerun with `--rebuild` to pick up the changes.
