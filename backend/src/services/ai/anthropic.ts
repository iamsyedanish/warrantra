/**
 * Anthropic (Claude) provider — used when AI_PROVIDER=anthropic.
 * The parser never browses, never runs tools and never sees other customers' data.
 */
import Anthropic from '@anthropic-ai/sdk';
import { betaZodOutputFormat } from '@anthropic-ai/sdk/helpers/beta/zod';
import type { z } from 'zod/v4';
import { env } from '../../config/env.js';

import { AiProviderError, costOf, type AiInput, type AiUsage } from './types.js';

/** Claude has no 'minimal' effort level; map it to 'low'. */
const claudeEffort = (): 'low' | 'medium' | 'high' => {
  const e = env().AI_EFFORT;
  return e === 'minimal' ? 'low' : e;
};

let client: Anthropic | undefined;
function anthropic(): Anthropic {
  client ??= new Anthropic({ apiKey: env().ANTHROPIC_API_KEY, timeout: env().AI_TIMEOUT_MS, maxRetries: 0 });
  return client;
}

function contentBlocks(input: AiInput, instruction: string): Anthropic.Beta.BetaContentBlockParam[] {
  const blocks: Anthropic.Beta.BetaContentBlockParam[] = [];
  if (input.kind === 'image') {
    blocks.push({ type: 'image', source: { type: 'base64', media_type: input.mediaType, data: input.base64 } });
  } else if (input.kind === 'pdf') {
    blocks.push({ type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: input.base64 } });
  } else {
    blocks.push({ type: 'text', text: input.text });
  }
  blocks.push({ type: 'text', text: instruction });
  return blocks;
}

function usageFrom(res: { usage: { input_tokens: number; output_tokens: number; cache_read_input_tokens?: number | null; cache_creation_input_tokens?: number | null }; model: string }, started: number): AiUsage {
  const input = res.usage.input_tokens + (res.usage.cache_read_input_tokens ?? 0) + (res.usage.cache_creation_input_tokens ?? 0);
  const output = res.usage.output_tokens;
  return { provider: 'anthropic', model: res.model, inputTokens: input, outputTokens: output, costUsd: costOf(input, output), latencyMs: Date.now() - started };
}

function mapError(err: unknown): AiProviderError {
  if (err instanceof AiProviderError) return err;
  if (err instanceof Anthropic.RateLimitError) return new AiProviderError('rate_limited', 'Provider rate limited', true);
  if (err instanceof Anthropic.APIConnectionTimeoutError) return new AiProviderError('timeout', 'Provider timeout', true);
  if (err instanceof Anthropic.APIConnectionError) return new AiProviderError('provider_error', 'Provider unreachable', true);
  if (err instanceof Anthropic.BadRequestError) return new AiProviderError('provider_error', 'Provider rejected the request', false);
  if (err instanceof Anthropic.APIError) {
    const status = err.status ?? 500;
    return new AiProviderError('provider_error', `Provider error ${status}`, status >= 500 || status === 529);
  }
  return new AiProviderError('provider_error', 'Unexpected provider failure', true);
}

const fallbackOptions = () =>
  env().AI_SERVER_FALLBACKS ? { betas: ['server-side-fallback-2026-07-01'] as Anthropic.Beta.AnthropicBeta[], fallbacks: 'default' as const } : {};

/** Structured extraction with a strict output schema. */
export async function extractStructured<S extends z.ZodType>(opts: {
  system: string;
  input: AiInput;
  instruction: string;
  schema: S;
  maxTokens?: number;
}): Promise<{ output: z.infer<S>; usage: AiUsage }> {
  const started = Date.now();
  try {
    const res = await anthropic().beta.messages.parse({
      model: env().AI_MODEL,
      max_tokens: opts.maxTokens ?? env().AI_MAX_OUTPUT_TOKENS,
      system: opts.system,
      messages: [{ role: 'user', content: contentBlocks(opts.input, opts.instruction) }],
      output_config: { effort: claudeEffort(), format: betaZodOutputFormat(opts.schema) },
      ...fallbackOptions(),
    });
    const usage = usageFrom(res, started);
    if (res.stop_reason === 'refusal') throw new AiProviderError('refused', 'Provider declined the request', false, usage);
    if (res.stop_reason === 'max_tokens') throw new AiProviderError('invalid_output', 'Output truncated', false, usage);
    if (!res.parsed_output) throw new AiProviderError('invalid_output', 'Output did not match schema', false, usage);
    return { output: res.parsed_output as z.infer<S>, usage };
  } catch (err) {
    throw mapError(err);
  }
}

/** Bounded plain-text generation (claim drafts). */
export async function generateText(opts: { system: string; prompt: string; maxTokens: number }): Promise<{ text: string; usage: AiUsage }> {
  const started = Date.now();
  try {
    const res = await anthropic().beta.messages.create({
      model: env().AI_MODEL,
      max_tokens: opts.maxTokens,
      system: opts.system,
      messages: [{ role: 'user', content: opts.prompt }],
      output_config: { effort: claudeEffort() },
      ...fallbackOptions(),
    });
    const usage = usageFrom(res, started);
    if (res.stop_reason === 'refusal') throw new AiProviderError('refused', 'Provider declined the request', false, usage);
    const text = res.content
      .filter((b): b is Anthropic.Beta.BetaTextBlock => b.type === 'text')
      .map((b) => b.text)
      .join('\n')
      .trim();
    if (!text) throw new AiProviderError('invalid_output', 'Empty output', false, usage);
    return { text, usage };
  } catch (err) {
    throw mapError(err);
  }
}
