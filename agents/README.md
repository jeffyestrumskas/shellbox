# agents

Extra files for `shellbox.sh --agent`.

> Part of [shellbox](../README.md).

| Agent | Copied in from the host | Extra files here |
|---|---|---|
| `claude` (default) | Settings and login from `~/.claude` | none |
| `pi` | Config from `~/.pi/agent` | `pi/extensions/`, copied into the box (a host extension with the same name wins) |

`ollama.ts` adds Ollama (Cloud and LAN) to pi, and `venice.ts` adds Venice. The [main README](../README.md#agent) lists the variables.

## Adding an agent

Add it to `SUPPORTED_AGENTS` in `shellbox.sh`, add an install step to the embedded Dockerfile, and give it a branch in the entrypoint `case`. If it has config on the host, add a list of what to copy.
