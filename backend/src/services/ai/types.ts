/** Shared AI types (provider-neutral). */
import { env } from '../../config/env.js';

export type AiInput =
  | { kind: 'image'; mediaType: 'image/jpeg' | 'image/png'; base64: string }
  | { kind: 'pdf'; base64: string }
  | { kind: 'text'; text: string };

export interface AiUsage {
  provider: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  costUsd: number;
  latencyMs: number;
}

export class AiProviderError extends Error {
  constructor(public readonly code: 'provider_error' | 'invalid_output' | 'refused' | 'timeout' | 'rate_limited' | 'disabled',
              message: string, public readonly retryable: boolean, public readonly usage?: AiUsage) {
    super(message);
    this.name = 'AiProviderError';
  }
}

/** USD cost from token counts using the configured per-million prices. */
export function costOf(inputTokens: number, outputTokens: number, cachedInputTokens = 0): number {
  const e = env();
  const cached = Math.min(cachedInputTokens, inputTokens);
  const cachedPrice = e.AI_PRICE_CACHED_INPUT_PER_MTOK ?? e.AI_PRICE_INPUT_PER_MTOK;
  const cost = ((inputTokens - cached) * e.AI_PRICE_INPUT_PER_MTOK + cached * cachedPrice + outputTokens * e.AI_PRICE_OUTPUT_PER_MTOK) / 1_000_000;
  return Math.round(cost * 1e6) / 1e6;
}
