import type { AssistantMessage, ModelRef } from "./types.ts";
import { isDeepSeekPeak } from "./time.ts";

export interface Prices {
  inputPerMillion: number;
  outputPerMillion: number;
  cacheReadPerMillion: number;
  cacheWritePerMillion: number;
}

const ZERO_PRICES: Prices = {
  inputPerMillion: 0,
  outputPerMillion: 0,
  cacheReadPerMillion: 0,
  cacheWritePerMillion: 0,
};

const OPENCODE_GO_DEEPSEEK_FLASH = {
  offPeak: {
    inputPerMillion: 0.15,
    outputPerMillion: 0.6,
    cacheReadPerMillion: 0.003,
    cacheWritePerMillion: 0,
  },
  peak: {
    inputPerMillion: 0.3,
    outputPerMillion: 1.2,
    cacheReadPerMillion: 0.006,
    cacheWritePerMillion: 0,
  },
} satisfies Record<string, Prices>;

const CLAUDE_HAIKU_SMALL: Prices = {
  inputPerMillion: 0.1,
  outputPerMillion: 0.5,
  cacheReadPerMillion: 0.01,
  cacheWritePerMillion: 0.125,
};

const CLAUDE_HAIKU_LARGE: Prices = {
  inputPerMillion: 0.5,
  outputPerMillion: 2.5,
  cacheReadPerMillion: 0.05,
  cacheWritePerMillion: 0.625,
};

const GEMINI_ARGON: Prices = {
  inputPerMillion: 2,
  outputPerMillion: 10,
  cacheReadPerMillion: 0.1,
  cacheWritePerMillion: 0,
};

export function modelKey(model: ModelRef): string {
  return `${model.providerID}/${model.id}${model.variant ? `#${model.variant}` : ""}`;
}

export function promptTokens(message: AssistantMessage): number {
  return message.tokens.input + message.tokens.cache.read + message.tokens.cache.write;
}

export function completionTokens(message: AssistantMessage): number {
  return message.tokens.output + message.tokens.reasoning;
}

export function pricesFor(
  model: ModelRef,
  timestamp: number,
  promptTokenCount: number,
): Prices | undefined {
  if (model.providerID === "opencode") return ZERO_PRICES;
  if (model.id === "deepseek-v4.1-flash") {
    return isDeepSeekPeak(timestamp)
      ? OPENCODE_GO_DEEPSEEK_FLASH.peak
      : OPENCODE_GO_DEEPSEEK_FLASH.offPeak;
  }
  if (model.id === "claude-haiku-5-5") {
    return promptTokenCount > 100_000 ? CLAUDE_HAIKU_LARGE : CLAUDE_HAIKU_SMALL;
  }
  if (model.id === "gemini-4-argon") return GEMINI_ARGON;
  if (model.id.endsWith("-free")) return ZERO_PRICES;
  return undefined;
}

export function messageListCost(message: AssistantMessage): number | undefined {
  const prices = pricesFor(message.model, message.timeCreated, promptTokens(message));
  if (!prices) return undefined;
  const input = message.tokens.input;
  const output = completionTokens(message);
  const cacheRead = message.tokens.cache.read;
  const cacheWrite = message.tokens.cache.write;
  return (
    (input * prices.inputPerMillion +
      output * prices.outputPerMillion +
      cacheRead * prices.cacheReadPerMillion +
      cacheWrite * prices.cacheWritePerMillion) /
    1_000_000
  );
}

export function allowanceMultiplier(model: ModelRef): number {
  if (model.providerID === "opencode") return 0;
  if (model.id === "deepseek-v4.1-flash") return 0.75;
  if (model.id === "claude-haiku-5-5") return 4;
  return 1;
}

export function messageAllowance(message: AssistantMessage): number | undefined {
  const list = messageListCost(message);
  if (list === undefined) return undefined;
  return list * allowanceMultiplier(message.model);
}
