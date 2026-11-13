# boxwatch

boxwatch records what a shellbox does: the files it opens, the connections it makes and the programs it runs. It watches from a separate container and writes to a log on the host that the box cannot reach or change.

> Part of [shellbox](../README.md).

## Requirements

- Docker that can run a `--privileged` container
- A Linux kernel with cgroup v2 and BTF

## Usage

```bash
./boxwatch.sh --name proj-a       # window 1
shellbox.sh --boxwatch proj-a     # window 2
```

Program starts and network connections show up in the window as they happen (`config verbose` picks which events appear). Every event is also written to `~/.shellbox/watch/<name>/session-<stamp>/events.jsonl`:

```json
{"ts":1749571200.12,"container":"shellbox-watched-8123","ev":"connect","pid":4412,"comm":"curl","ip":"160.79.104.10","port":443}
{"ts":1749571201.05,"container":"shellbox-watched-8123","ev":"exec","pid":4490,"comm":"sh","file":"/usr/bin/apt-get"}
```

## How it works

shellbox tells the watcher which container to follow, and the watcher uses eBPF to trace only that container. It never touches the Docker socket. Recording starts when the window prints `capture live`, a moment after the box starts.

The box controls the file and process names in the events, so the watcher escapes them, marks anything it cannot attribute as `"suspect": true`, and limits how much the box can write.

### Limits

- Only `openat` file opens, IPv4 connections and program starts are traced. Other ways to open files or send data (`openat2`, `sendto` without `connect`, IPv6, `io_uring`) go unrecorded, and so do hostnames. Run `--boxwall` alongside it to see hostnames.
- Anything the box does before `capture live` can be missed.
- The log is capped at 4 × 64 MiB and 2000 events a second, so a box that floods it can push the earliest events out of the log within about 10 to 20 minutes.
- A box can fake events for itself. Faking events for another box needs an ID it cannot see, and a wrong guess is marked `suspect`.
