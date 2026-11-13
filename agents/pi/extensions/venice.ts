// Venice (venice.ai) provider for pi, with a live model catalog.
//
// At startup this fetches Venice's text-model list and registers every PRIVATE
// (zero data retention) model that supports tool calling, so they all appear in
// pi's /model picker as venice/<id>. `/reload` re-fetches the list. This is the
// extension's own request, so PI_OFFLINE doesn't suppress it.
//
// Needs VENICE_API_KEY in the environment; without it nothing is registered.
// shellbox installs this into pi boxes; to use it on the host, copy it to
// ~/.pi/agent/extensions/.
import type { ExtensionAPI, ProviderModelConfig } from "@earendil-works/pi-coding-agent";

const BASE_URL = "https://api.venice.ai/api/v1";
const FETCH_TIMEOUT_MS = 8000;
const PI_THINKING_LEVELS = ["minimal", "low", "medium", "high", "xhigh", "max"];

type VeniceModel = {
  id: string;
  model_spec?: {
    name?: string;
    privacy?: string;
    offline?: boolean;
    availableContextTokens?: number;
    maxCompletionTokens?: number;
    pricing?: Partial<Record<"input" | "output" | "cache_input" | "cache_write", { usd?: number }>>;
    capabilities?: {
      supportsFunctionCalling?: boolean;
      supportsReasoning?: boolean;
      supportsReasoningEffort?: boolean;
      reasoningEffortOptions?: string[];
      supportsVision?: boolean;
    };
  };
};

// Used when the catalog can't be fetched (offline, timeout, boxwall denied), so
// shellbox's default model still works. Mirrors Venice's live entry.
const FALLBACK: VeniceModel = {
  id: "deepseek-v4-pro-0813",
  model_spec: {
    name: "DeepSeek V4 Pro 0813",
    privacy: "private",
    availableContextTokens: 1000000,
    maxCompletionTokens: 262144,
    pricing: { input: { usd: 1.65 }, output: { usd: 4.95 }, cache_input: { usd: 0.165 } },
    capabilities: {
      supportsFunctionCalling: true,
      supportsReasoning: true,
      supportsReasoningEffort: true,
      reasoningEffortOptions: ["none", "low", "high", "max"],
    },
  },
};

function isUsable({ model_spec: s = {} }: VeniceModel): boolean {
  return s.privacy === "private" && !s.offline && !!s.capabilities?.supportsFunctionCalling;
}

// Map pi's thinking levels onto the model's reasoning_effort values: pi "off" is
// Venice "none"; a level the model doesn't offer is null, which pi hides.
function thinkingLevelMap(options: string[] = []) {
  if (!options.length) return undefined;
  return Object.fromEntries([
    ["off", options.includes("none") ? "none" : null],
    ...PI_THINKING_LEVELS.map((level) => [level, options.includes(level) ? level : null]),
  ]);
}

// Venice prices are USD per million tokens, the same unit pi uses.
function toPiModel({ id, model_spec: s = {} }: VeniceModel): ProviderModelConfig {
  const c = s.capabilities ?? {};
  return {
    id,
    name: s.name ?? id,
    reasoning: !!c.supportsReasoning,
    thinkingLevelMap: thinkingLevelMap(c.reasoningEffortOptions),
    compat: { supportsReasoningEffort: !!c.supportsReasoningEffort },
    input: c.supportsVision ? ["text", "image"] : ["text"],
    cost: {
      input: s.pricing?.input?.usd ?? 0,
      output: s.pricing?.output?.usd ?? 0,
      cacheRead: s.pricing?.cache_input?.usd ?? 0,
      cacheWrite: s.pricing?.cache_write?.usd ?? 0,
    },
    contextWindow: s.availableContextTokens ?? 128000,
    maxTokens: s.maxCompletionTokens ?? 16384,
  };
}

async function fetchModels(apiKey: string): Promise<VeniceModel[]> {
  const res = await fetch(`${BASE_URL}/models?type=text`, {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const { data = [] } = (await res.json()) as { data?: VeniceModel[] };
  return data.filter(isUsable);
}

export default async function (pi: ExtensionAPI) {
  const apiKey = process.env.VENICE_API_KEY;
  if (!apiKey) return;

  let models = [FALLBACK];
  try {
    const fetched = await fetchModels(apiKey);
    if (fetched.length) models = fetched;
  } catch (err) {
    console.error(`[venice] model list unavailable (${(err as Error).message}); using fallback model only`);
  }

  pi.registerProvider("venice", {
    name: "Venice",
    baseUrl: BASE_URL,
    apiKey: "$VENICE_API_KEY",
    api: "openai-completions",
    models: models.map(toPiModel),
  });
}
