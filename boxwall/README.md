# boxwall

Opt-in, interactive egress firewall for a docker container. Single self-contained file (Dockerfile + proxy embedded inline). Run it in a second window; every new outbound connection from the sandbox is paused and approved by hand.

> Part of [shellbox](../README.md#architecture).

## Requirements

- Docker Desktop / Engine **28+** (boxwall sets a per-interface `route_localnet` sysctl via a network driver option 28 introduced; older engines won't run it)
- Linux container support for `iptables` / `NET_ADMIN` (the firewall runs inside the container, not on the host)

## Usage

```bash
./boxwall.sh --name proj-a    # window 1: firewall (stays running); --name is the namespace
shellbox.sh --boxwall proj-a  # window 2: sandbox routing all egress through it (same name)
```

On each new connection boxwall shows the destination (from TLS SNI / HTTP Host, no decryption) and waits for a decision you type as `<action><duration>[scope]`:

```
[boxwall] connection → api.anthropic.com:443 (1.2.3.4)
  allow  ao once  aq until quit  a1m/a1h timed  af forever
  deny   do once  dq until quit  d1m/d1h timed  df forever   ⏎ = do
  scope  append h api.anthropic.com:* (any port)  p *:443 (any host)  s *.anthropic.com  * anything
  e.g.  af* allow anything forever  ·  dfs deny domain forever  ·  aqs allow domain till quit
>
```

The action is always explicit — `a` = allow, `d` = deny — so the two vocabularies mirror each other. Durations: `o` once (no rule stored), `q` until the console quits, `f` forever (persisted), `1m`/`30m`/`1h` timed (re-prompts on expiry). Append an optional scope letter — `h` host (`host:*`), `p` port (`*:port`), `s` domain (`*.domain` + subdomains), `*` anything — or none for the exact `host:port`. A bare Enter (or `d`) denies just this one connection: the default policy.

So `af*` trusts everything forever, `aqs` allows a domain + subdomains until quit, `df*` denies everything forever. Deny rules win over allow, so `df` on something already allowed blocks it. `forever` rules persist to `./.shellbox/boxwall-rules-<name>.json`; `until-quit` and timed rules last the session.

The SNI / Host is attacker-controllable, so before a name matches a rule boxwall verifies it resolves to the real destination IP (via the host's `/etc/resolv.conf`); mismatches and unknown names fall back to the raw IP. Domain (`s`) rules match on real label boundaries, so `*.anthropic.com` covers `api.anthropic.com` but never `evilanthropic.com`.

> If Docker isn't sharing the rules dir (Docker Desktop: **Settings → Resources → File Sharing**), boxwall warns and persists to a managed named volume (`<name>-rules`) instead — the firewall still runs, the rules just aren't a host-visible file. Add the dir to File Sharing, or pass `--rules-dir` a shared path, to get the host file back.

## How it works

A persistent netns holder owns the namespace + egress (the sandbox joins it); a foreground proxy/console gates traffic — so you can rerun `boxwall.sh` without dropping the sandbox's network. The sandbox has no `NET_ADMIN`/`NET_RAW` (default boxes `--cap-drop ALL`; `--claw`/`--agent` boxes keep Docker's caps minus those), so it can't rewrite the rules or inject raw packets past them — and `-p`/`-N` don't work with `--boxwall`, since it shares the holder's namespace. All TCP is gated; DNS is prompted once per resolver; everything else drops (QUIC, ICMP, IPv6, other resolvers).

> Tunnelling through the approved resolver (data in subdomains) is still possible — out of scope for a no-decryption filter.

## Console commands

`help` lists them.

| Command | Description |
|---|---|
| `rules` / `ls` | List active allow + deny rules (forever + session) |
| `history` / `log` | Hosts seen this session (`history clear` resets). Flags: `F` allow-forever, `U` allow-session, `X` deny, `-` none |
| `config` | Settings + stats; `config verbose on\|off` logs every allowed connection; `config blocks on\|off` toggles deny-rule auto-block logging |
| `allow <target>...` | Add allow-forever rule(s); targets use the scope forms (`host:port`, `host`, `*:port`, `*.domain`, `*`) |
| `deny` / `block <target>...` | Add deny-forever rule(s) (same forms; auto-blocked, no prompt) |
| `forget` / `unblock <target>...` | Remove from allow + deny (bare host drops all its ports) |
| `reload` | Re-read the rules file from disk |
| `clear` | Drop all session rules (until-quit + timed) |
| `quit` / `exit` | Stop the firewall |

## Options

| Flag | Description |
|---|---|
| `--name NAME` | **Required** namespace: names the containers and scopes the rules file to `boxwall-rules-NAME.json`. Match with `shellbox.sh --boxwall NAME` |
| `--port PORT` | Internal proxy port (default `12345`) |
| `--rules-dir DIR` | Where to persist forever rules (default `./.shellbox`) |
| `--image IMAGE` | Full image name override (e.g. `myrepo:tag`) |
| `--rebuild` | Clean rebuild (needed to pick up proxy changes) |
| `--no-build` | Skip the build step (assume the image exists) |
| `--down` | Stop the firewall; attached sandboxes lose network until restarted |

> The proxy is baked into the image — rerun with `--rebuild` after editing `boxwall.sh`.
