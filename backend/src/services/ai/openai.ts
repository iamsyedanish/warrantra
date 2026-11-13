/**
 * OpenAI provider (Responses API) for receipt/label extraction and claim drafts.
 * - Strict structured output from the zod schema; the parser has no tools and
 *   cannot browse or reach other customers' data.
 * - `store: false`: request/response data is not stored for later retrieval.
 * - SDK retries are off; the job queue owns bounded retries and budgets.
 */
import OpenAI from 'openai';
import { zodTextFormat } from 'openai/helpers/zod';
import type { z } from 'zod/v4';
import { env } from '../../config/env.js';
import { AiProviderError, costOf, type AiInput, type AiUsage } from './types.js';

let client: OpenAI | undefined;
function openai(): OpenAI {
  client ??= new OpenAI({ apiKey: env().OPENAI_API_KEY, timeout: env().AI_TIMEOUT_MS, maxRetries: 0 });
  return client;
}

/** Reasoning effort is only accepted by reasoning-capable models (gpt-5 family, o-series). */
const isReasoningModel = (model: string) => /^(gpt-5|o\d)/.test(model);

export function buildInput(input: AiInput, instruction: string): OpenAI.Responses.ResponseInputItem[] {
  const content: OpenAI.Responses.ResponseInputContent[] = [];
  if (input.kind === 'image') {
    content.push({ type: 'input_image', image_url: `data:${input.mediaType};base64,${input.base64}`, detail: 'high' });
  } else if (input.kind === 'pdf') {
    content.push({ type: 'input_file', filename: 'document.pdf', file_data: `data:application/pdf;base64,${input.base64}` });
  } else {
    content.push({ type: 'input_text', text: input.text });
  }
  content.push({ type: 'input_text', text: instruction });
  return [{ role: 'user', content }];
}

interface ResponseLike {
  model: string;
  status?: string | null;
  incomplete_details?: { reason?: string | null } | null;
  usage?: { input_tokens: number; output_tokens: number; input_tokens_details?: { cached_tokens?: number | null } | null } | null;
  output?: Array<{ type: string; content?: Array<{ type: string; text?: string; refusal?: string }> }>;
}

export function usageFrom(res: ResponseLike, started: number): AiUsage {
  const input = res.usage?.input_tokens ?? 0;
  const output = res.usage?.output_tokens ?? 0; // includes reasoning tokens
  const cached = res.usage?.input_tokens_details?.cached_tokens ?? 0;
  return { provider: 'openai', model: res.model, inputTokens: input, outputTokens: output, costUsd: costOf(input, output, cached), latencyMs: Date.now() - started };
}

/** Throws the right AiProviderError for refusals and truncated output. */
export function assertComplete(res: ResponseLike, usage: AiUsage): void {
  const refused = (res.output ?? []).some((o) => o.type === 'message' && (o.content ?? []).some((c) => c.type === 'refusal'));
  if (refused) throw new AiProviderError('refused', 'Provider declined the request', false, usage);
  if (res.status === 'incomplete') {
    const reason = res.incomplete_details?.reason ?? 'incomplete';
    if (reason === 'content_filter') throw new AiProviderError('refused', 'Provider content filter', false, usage);
    throw new AiProviderError('invalid_output', `Output incomplete: ${reason}`, false, usage);
  }
}

function mapError(err: unknown): AiProviderError {
  if (err instanceof AiProviderError) return err;
  if (err instanceof OpenAI.RateLimitError) return new AiProviderError('rate_limited', 'Provider rate limited', true);
  if (err instanceof OpenAI.APIConnectionTimeoutError) return new AiProviderError('timeout', 'Provider timeout', true);
  if (err instanceof OpenAI.APIConnectionError) return new AiProviderError('provider_error', 'Provider unreachable', true);
  if (err instanceof OpenAI.BadRequestError) return new AiProviderError('provider_error', 'Provider rejected the request', false);
  if (err instanceof OpenAI.AuthenticationError || err instanceof OpenAI.PermissionDeniedError) {
    return new AiProviderError('provider_error', 'Provider authentication failed', false);
  }
  if (err instanceof OpenAI.APIError) {
    const status = err.status ?? 500;
    return new AiProviderError('provider_error', `Provider error ${status}`, status >= 500);
  }
  return new AiProviderError('provider_error', 'Unexpected provider failure', true);
}

export async function extractStructured<S extends z.ZodType>(opts: {
  system: string; input: AiInput; instruction: string; schema: S; schemaName: string; maxTokens?: number;
}): Promise<{ output: z.infer<S>; usage: AiUsage }> {
  const model = env().AI_MODEL;
  const started = Date.now();
  try {
    const res = await openai().responses.parse({
      model,
      instructions: opts.system,
      input: buildInput(opts.input, opts.instruction),
      text: { format: zodTextFormat(opts.schema, opts.schemaName) },
      max_output_tokens: opts.maxTokens ?? env().AI_MAX_OUTPUT_TOKENS,
      store: false,
      ...(isReasoningModel(model) ? { reasoning: { effort: env().AI_EFFORT } } : {}),
    });
    const usage = usageFrom(res, started);
    assertComplete(res, usage);
    if (!res.output_parsed) throw new AiProviderError('invalid_output', 'Output did not match schema', false, usage);
    return { output: res.output_parsed as z.infer<S>, usage };
  } catch (err) {
    throw mapError(err);
  }
}

export async function generateText(opts: { system: string; prompt: string; maxTokens: number }): Promise<{ text: string; usage: AiUsage }> {
  const model = env().AI_MODEL;
  const started = Date.now();
  try {
    const res = await openai().responses.create({
      model,
      instructions: opts.system,
      input: opts.prompt,
      max_output_tokens: opts.maxTokens,
      store: false,
      ...(isReasoningModel(model) ? { reasoning: { effort: env().AI_EFFORT } } : {}),
    });
    const usage = usageFrom(res, started);
    assertComplete(res, usage);
    const text = (res.output_text ?? '').trim();
    if (!text) throw new AiProviderError('invalid_output', 'Empty output', false, usage);
    return { text, usage };
  } catch (err) {
    throw mapError(err);
  }
}
