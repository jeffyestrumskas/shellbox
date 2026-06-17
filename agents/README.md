# agents

Default config templates for `shellbox.sh --agent NAME`. Each subdirectory is
one supported agent; shellbox mounts the chosen agent's directory read-only into
the box and renders the templates into the box's persistent state mount on first
run.

> Part of [shellbox](../README.md#architecture) — see the architecture diagram for how `--agent` fits with the sandbox box, boxwall, and boxwatch.

`--agent` defaults to **`claude`** (used when `--agent` is omitted): installs Claude
Code, uses your host Claude config, no extra services, runs in any posture — so it
has no template dir here. The two **cloud agents** below each REQUIRE `--claw` and
`--boxwall`:

| Agent | Source-of-truth installer | Rendered config |
|---|---|---|
| `openclaw` | `curl -fsSL https://openclaw.ai/install.sh \| bash` | `~/.config/openclaw/config.json5` |
| `hermes` | `git clone https://github.com/NousResearch/hermes-agent && pip install -e .` | `~/.hermes/config.yaml` + `~/.hermes/.env` |

Both cloud agents are wired to **Ollama Cloud** (OpenAI-compatible) for models.

## Placeholders

The `${...}` tokens in the templates are substituted from the container's
environment on first run. shellbox **never overwrites** an already-rendered
config, so edits you make survive across runs.

| Placeholder | Source | Default |
|---|---|---|
| `${OLLAMA_BASE_URL}` | env (`-e OLLAMA_BASE_URL=...`) | `https://ollama.com/v1` |
| `${OLLAMA_MODEL}` | `--agent-model` / env | `qwen3-coder:480b-cloud` |
| `${OLLAMA_API_KEY}` | host env, forwarded | _required_ (ollama.com/settings/keys) |
| `${TELEGRAM_BOT_TOKEN}` | host env (optional) | empty — from @BotFather, if you add a Telegram channel |
| `${TELEGRAM_ALLOW_FROM}` | host env (optional) | empty — your numeric Telegram user id |

## Messaging channel

Use a **separate-identity** bot so a misbehaving agent can't impersonate you or
read your personal chats. A **Telegram** bot (created via @BotFather) is the
low-friction choice — it's its own account by construction. Configure it in the
rendered agent config (see the commented Telegram block in each template) and lock
`allow_from` to your own user id. Until a channel is set, drive the agent from the
box terminal.

## Adding an agent

Add `agents/<name>/` with its config template(s), then teach `shellbox.sh` about
it: extend `SUPPORTED_AGENTS`, add the build/install steps in the embedded
Dockerfile, and add the render mapping in the entrypoint's config helper.
