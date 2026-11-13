/**
 * AI provider switch. AI_PROVIDER selects OpenAI (default) or Anthropic; both
 * receive the same prompts, schemas and limits, and report usage for cost
 * accounting. With no key configured, AI actions fail cleanly and release
 * their allowance — manual entry is never affected.
 */
import type { z } from 'zod/v4';
import { env } from '../../config/env.js';
import * as anthropic from './anthropic.js';
import * as openai from './openai.js';
import { AiProviderError, type AiInput, type AiUsage } from './types.js';

export { AiProviderError, costOf, type AiInput, type AiUsage } from './types.js';

export const PROVIDER_LABELS: Record<string, string> = { openai: 'OpenAI', anthropic: 'Anthropic' };

/** Human-readable name of the active provider (used in consent disclosures). */
export function providerName(): string {
  return PROVIDER_LABELS[env().AI_PROVIDER] ?? 'our AI provider';
}

function active(): 'openai' | 'anthropic' {
  const e = env();
  if (e.AI_PROVIDER === 'openai' && e.OPENAI_API_KEY) return 'openai';
  if (e.AI_PROVIDER === 'anthropic' && e.ANTHROPIC_API_KEY) return 'anthropic';
  throw new AiProviderError('disabled', 'AI provider not configured', false);
}

export async function extractStructured<S extends z.ZodType>(opts: {
  system: string; input: AiInput; instruction: string; schema: S; schemaName?: string; maxTokens?: number;
}): Promise<{ output: z.infer<S>; usage: AiUsage }> {
  return active() === 'openai'
    ? openai.extractStructured({ ...opts, schemaName: opts.schemaName ?? 'extraction' })
    : anthropic.extractStructured(opts);
}

/** Moderation of user-written input (OpenAI only; other providers rely on their own safety systems). */
export async function moderate(text: string): Promise<{ flagged: boolean; categories: string[] }> {
  return active() === 'openai' ? openai.moderate(text) : { flagged: false, categories: [] };
}

export async function generateText(opts: { system: string; prompt: string; maxTokens: number }): Promise<{ text: string; usage: AiUsage }> {
  return active() === 'openai' ? openai.generateText(opts) : anthropic.generateText(opts);
}
