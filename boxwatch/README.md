# boxwatch

Opt-in, out-of-box activity recorder for a docker sandbox. Single self-contained file (Dockerfile + collector embedded inline). Run it in a second window; it records the sandbox's file, network, and process activity to a host log the sandbox can't see, kill, or scrub.

> Part of [shellbox](../README.md#architecture).

## Requirements

- Docker able to run a `--privileged` container
- eBPF-capable host kernel: **cgroup v2** + **BTF** (`bpftrace` runs in the watcher, against the host kernel)
- Incompatible with `shellbox.sh --runsc` — gVisor services syscalls in userspace, so eBPF never sees them

## Usage

```bash
./boxwatch.sh            # window 1: start the watcher (stays running)
shellbox.sh --boxwatch   # window 2: start a recorded sandbox
```

`--boxwatch` refuses to start unless the watcher is up, so a box can't run un-recorded. `exec`/`connect` stream to the window (`config verbose on|off`); all events are always written as JSONL:

```json
{"ts":1749571200.12,"container":"shellbox-watched-8123","ev":"connect","pid":4412,"comm":"curl","ip":"160.79.104.10","port":443}
{"ts":1749571201.05,"container":"shellbox-watched-8123","ev":"exec","pid":4490,"comm":"sh","file":"/usr/bin/apt-get"}
```

## How it works

`shellbox.sh` (which has docker access) registers the sandbox's container id under `~/.shellbox/watch/targets/`. The watcher maps it to the container's cgroup and runs `bpftrace` probes that bail unless the task is in that cgroup — recording only that one box, never touching the docker socket. Three event types: process **exec**, **file** opens (read vs write), outbound **network** connects (IPv4 + port). Logs land in `~/.shellbox/watch/session-<stamp>/events.jsonl`, mounted only into the watcher — so a rogue box can't disable its own watching.

On each (re)start it prints `attaching probes …` then `capture live …`. **Capture is authoritative only from `capture live` onward** — a command in the brief attach window can be missed.

Event fields (`comm`, file path) come from the untrusted box, so the collector hardens against them:

- **Sanitization** — untrusted strings escaped to printable ASCII, so a crafted path can't inject terminal escapes or smuggle delimiters.
- **Trusted numeric fields lead, untrusted strings trail** — a box can set its own `comm` to arbitrary bytes (`prctl(PR_SET_NAME)`), but with strings trailing it can only blur the comm/filename boundary, not displace a numeric field (which previously crashed the parse and let a box drop its own events).
- **`Z` cgroup confirmations accepted only at BEGIN** — refused after the first real event, so a `Z` smuggled via a filename newline can't poison the trusted-id map.
- **Attribution from confirmed cgroups only** — an event whose cgroup id isn't confirmed is logged `"suspect": true` with no container name, never attributed to another box.
- **Malformed lines logged, not dropped** — recorded as `{"ev":"malformed","suspect":true}`, so a box can't vanish activity by forcing a parse failure.
- **Bounded output** — size + per-second rate caps (excess → `_dropped` marker), so a flooding box can't fill the host disk through the watcher.
- **Hardened cgroup resolution** — target dirs matched on docker's id token (not a loose substring) and restricted to printable ASCII before embedding into the `bpftrace` program.

> Syscall-layer IPv4 only; raw payloads, IPv6 connect decoding, and DNS names are out of scope — pair with `--boxwall` for per-connection hostnames. Residual: a box can forge an event attributed to *its own* cgroup (provenance can't be re-checked at the eBPF-string layer); forging onto *another* box also needs that box's numeric cgroup id, which cgroup namespacing hides, and a wrong guess lands as `suspect`. Terminal injection, `comm`-based evasion, and `Z`-line cgroup poisoning are closed.

## Console commands

`help` lists them.

| Command | Description |
|---|---|
| `stats` | Event counts this session, incl. `suspect` (unconfirmed-cgroup) and `dropped` (rate-capped) |
| `tail [N] [types]` | Last N events (default 20); optionally filter to `exec`/`open`/`connect` |
| `targets` / `ls` | Containers currently being watched |
| `config` | Show settings; `config verbose <what>` echoes events live (`on`/`off` or any of `exec`/`open`/`connect`, combinable; default `exec,connect`) |
| `clear` | Clear the in-memory tail buffer |
| `quit` / `exit` | Stop the watcher (sandboxes keep running, unwatched) |

## Options

| Flag | Description |
|---|---|
| `--name NAME` | Watcher container name (default `shellbox-boxwatch`; match with `shellbox.sh --boxwatch-name`) |
| `--watch-dir DIR` | Logs + target registrations (default `~/.shellbox/watch`) |
| `--image IMAGE` | Full image name override (e.g. `myrepo:tag`) |
| `--rebuild` | Clean rebuild (needed to pick up collector changes) |
| `--no-build` | Skip the build step (assume the image exists) |
| `--down` | Stop the watcher; sandboxes keep running, unwatched |

> The collector is baked into the image — rerun with `--rebuild` after editing `boxwatch.sh`.
