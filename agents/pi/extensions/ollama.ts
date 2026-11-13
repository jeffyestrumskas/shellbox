// Ollama providers for pi, each with a live model catalog:
//   - ollama:     Ollama Cloud (ollama.com), when OLLAMA_API_KEY is set.
//   - ollama-lan: an Ollama server on your network, when OLLAMA_LAN_URL is set
//                 (e.g. http://192.168.1.50:11434; no key needed).
//
// At startup this fetches each server's model list and registers every model that
// supports tool calling, so they appear in pi's /model picker as ollama/<model> or
// ollama-lan/<model>. `/reload` re-fetches. This is the extension's own request, so
// PI_OFFLINE doesn't suppress it. Ollama doesn't report prices (Cloud is a
// subscription), so pi shows these models' cost as $0.
//
// shellbox installs this into pi boxes; to use it on the host, copy it to
// ~/.pi/agent/extensions/.
import type { ExtensionAPI, ProviderModelConfig } from "@earendil-works/pi-coding-agent";

const FETCH_TIMEOUT_MS = 8000;
const MAX_OUTPUT_TOKENS = 32768; // Ollama doesn't publish per-model output limits
const FREE = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

// Used when Ollama Cloud's catalog can't be fetched, so shellbox's default model
// still works. Mirrors Ollama's live entry. (A LAN server has no known default.)
const CLOUD_FALLBACK: ProviderModelConfig = {
  id: "deepseek-v4-pro:0813",
  name: "deepseek-v4-pro:0813",
  reasoning: true,
  input: ["text"],
  cost: FREE,
  contextWindow: 1048576,
  maxTokens: MAX_OUTPUT_TOKENS,
};

async function api(host: string, path: string, apiKey: string, body?: object) {
  const res = await fetch(`${host}${path}`, {
    method: body ? "POST" : "GET",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: body && JSON.stringify(body),
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} from ${host}${path}`);
  return res.json();
}

// /api/show has each model's capabilities and its context size (model_info's
// "<architecture>.context_length"). Returns undefined for models without tools.
async function toPiModel(host: string, name: string, apiKey: string): Promise<ProviderModelConfig | undefined> {
  const { capabilities = [], model_info = {} } = await api(host, "/api/show", apiKey, { model: name });
  if (!capabilities.includes("tools")) return undefined; // pi needs tools
  const ctxKey = Object.keys(model_info).find((k) => k.endsWith(".context_length"));
  return {
    id: name,
    name,
    reasoning: capabilities.includes("thinking"),
    input: capabilities.includes("vision") ? ["text", "image"] : ["text"],
    cost: FREE,
    contextWindow: ctxKey ? Number(model_info[ctxKey]) : 128000,
    maxTokens: MAX_OUTPUT_TOKENS,
  };
}

async function fetchModels(host: string, apiKey: string): Promise<ProviderModelConfig[]> {
  const { models = [] } = (await api(host, "/api/tags", apiKey)) as { models?: { name: string }[] };
  const all = await Promise.all(models.map((m) => toPiModel(host, m.name, apiKey).catch(() => undefined)));
  return all.filter((m): m is ProviderModelConfig => !!m);
}

async function register(
  pi: ExtensionAPI,
  id: string,
  name: string,
  host: string,
  apiKey: string, // what we send; pi's own requests use providerKey
  providerKey: string,
  fallback: ProviderModelConfig[],
) {
  let models = fallback;
  try {
    const fetched = await fetchModels(host, apiKey);
    if (fetched.length) models = fetched;
  } catch (err) {
    console.error(`[${id}] model list unavailable from ${host} (${(err as Error).message})`);
  }
  if (!models.length) return;
  pi.registerProvider(id, { name, baseUrl: `${host}/v1`, apiKey: providerKey, api: "openai-completions", models });
}

export default async function (pi: ExtensionAPI) {
  const cloudKey = process.env.OLLAMA_API_KEY;
  const lanUrl = process.env.OLLAMA_LAN_URL?.replace(/\/+$/, "");
  await Promise.all([
    cloudKey && register(pi, "ollama", "Ollama Cloud", "https://ollama.com", cloudKey, "$OLLAMA_API_KEY", [CLOUD_FALLBACK]),
    // A LAN server needs no key, but pi only lists models whose provider has one.
    lanUrl && register(pi, "ollama-lan", "Ollama (LAN)", lanUrl, "ollama", "ollama", []),
  ]);
}
