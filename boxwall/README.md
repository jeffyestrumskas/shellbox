# boxwall

An opt-in, interactive egress firewall for a docker container. It is a single self-contained file with the Dockerfile and proxy embedded inline; no extra files to manage. Run it in a second window/pane; every new outbound connection from the sandbox is paused and approved by hand.

## Requirements

- Docker Desktop / Docker Engine **28+** (boxwall sets a per-interface `route_localnet` sysctl via the network endpoint driver option that 28 introduced; the script does this automatically, but older engines won't run it)
- Linux container support for `iptables` / `NET_ADMIN` (the firewall runs inside the container, not on the host)

## Usage

```bash
# window 1: start the firewall (stays running). --name is required: it's the namespace.
./boxwall.sh --name proj-a

# window 2: start a sandbox that routes all egress through it (same name)
shellbox.sh --boxwall proj-a
```

When the sandbox opens a connection, boxwall shows the destination (from TLS SNI / HTTP Host) and prompts:

```
[boxwall] connection -> api.anthropic.com:443
  [o]nce  [u]ntil-quit  [f]orever  [d]eny (default):
```

The SNI / Host is attacker-controllable, so before a name can match a rule, boxwall cross-checks that it resolves to the real destination IP using the host's `/etc/resolv.conf`. Mismatches and unknown names fall back to the raw IP.

Rules are keyed on host and port, so approving `host:443` does not approve `host:22`. `forever` rules persist to `./.shellbox/boxwall-rules-<name>.json` (under the directory you run from), `until-quit` lasts the session, and `once` is a single connection; the default policy is deny.

The `--name` namespace is required and scopes the rules file, so the rules dir (`./.shellbox` by default) can hold several independent rule sets at once. `./boxwall.sh --name proj-a` uses `boxwall-rules-proj-a.json`; attach a sandbox to it with `./shellbox.sh --boxwall proj-a`.

> If Docker isn't sharing the rules directory (Docker Desktop bind mounts only work for paths in **Settings → Resources → File Sharing**), boxwall prints a warning and persists rules in a managed Docker named volume (`<name>-rules`) instead, so the firewall still runs — the rules just aren't a host-visible file. Add the directory to File Sharing, or pass `--rules-dir` a shared path, to get the host file back.

## How it works

boxwall runs a persistent netns holder that the sandbox joins and a foreground proxy/console, so you can rerun `boxwall.sh` without dropping the sandbox's network. The sandbox keeps `--cap-drop ALL` so it can't rewrite the rules, and since it shares the holder's namespace, `-p`/`-N` don't work with `--boxwall`.

All TCP is gated by the prompt, and DNS is prompted once per resolver. Everything else is dropped, including QUIC, ICMP, IPv6, and DNS to any other resolver.

> Tunnelling through the approved resolver (data in subdomains) is still possible, out of scope for a no-decryption filter.

## Console commands

Type these in the boxwall window (`help` lists them):

| Command | Description |
|---|---|
| `rules` / `ls` | List active allow rules (forever + until-quit) |
| `history` / `log` | Hosts accessed this session (`history clear` resets) |
| `config` | Show settings + stats; `config verbose on\|off` logs every allowed connection |
| `allow <host[:port]>...` | Add allow-forever rule(s); a bare host matches any port |
| `forget <host[:port]>...` | Remove rule(s) from both sets (bare host drops all its ports) |
| `reload` | Re-read the rules file from disk |
| `clear` | Drop all until-quit rules |
| `quit` / `exit` | Stop the firewall |

## Options

| Flag | Description |
|---|---|
| `--name NAME` | **Required.** Boxwall namespace: names the firewall containers and scopes the rules file to `boxwall-rules-NAME.json`. Match with `shellbox.sh --boxwall NAME` |
| `--port PORT` | Internal proxy port (default `12345`) |
| `--rules-dir DIR` | Where to persist allow-forever rules (default `./.shellbox`, i.e. under the current directory) |
| `--image IMAGE` | Full image name override (e.g. `myrepo:tag`) |
| `--rebuild` | Force a clean rebuild (needed to pick up proxy changes) |
| `--no-build` | Skip the build step (assume the image already exists) |
| `--down` | Stop the firewall; attached sandboxes lose network until it's restarted |

> Note: the proxy is baked into the image, so after editing `boxwall.sh` rerun with `--rebuild` to pick up the changes.
