# boxwall

boxwall is a firewall for a shellbox. Run it in a separate window, and it asks about every new outbound connection the box makes.

> Part of [shellbox](../README.md).

## Requirements

- Docker 28 or newer

## Usage

```bash
./boxwall.sh --name proj-a      # window 1
shellbox.sh --boxwall proj-a    # window 2
```

For each new connection, boxwall shows the destination and waits for an answer:

```
[boxwall] connection → api.anthropic.com:443 (1.2.3.4)
  allow  ao once  aq until quit  a1m/a1h timed  af forever
  deny   do once  dq until quit  d1m/d1h timed  df forever   ⏎ = do
  scope  append h api.anthropic.com:* (any port)  p *:443 (any host)  s *.anthropic.com  * anything
  e.g.  af* allow anything forever  ·  dfs deny domain forever  ·  aqs allow domain till quit
>
```

An answer is an action, a duration and an optional scope. `a` allows and `d` denies. `o` means once, `q` until boxwall quits, `f` forever, and `1m` or `1h` sets a timer. Add `h` for any port on that host, `p` for any host on that port, `s` for the whole domain, or `*` for everything. Pressing Enter denies just that connection, and deny rules beat allow rules.

Forever rules are saved in `~/.shellbox/boxwall-rules-<name>.json`. A broad answer also settles any waiting prompts it covers. If Docker Desktop cannot share `~/.shellbox` (Settings → Resources → File Sharing), the rules go into a Docker volume named `<name>-rules` instead.

## How it works

boxwall runs two containers. `<name>` holds the network the box joins and keeps running after the console quits. `<name>-ctl` is the console in the boxwall window, and every TCP connection goes through it. DNS is asked about once per resolver, and all other traffic is dropped.

The box cannot change the firewall rules or send raw packets around them. Hostnames come from TLS and HTTP headers, which the box controls, so boxwall only trusts a name after checking that it resolves to the address the box is really connecting to.

boxwall does not decrypt anything, so it cannot stop data smuggled out in DNS lookups through an approved resolver.
