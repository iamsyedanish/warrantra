import './setup-env.js';
import { describe, expect, it } from 'vitest';
import { zodTextFormat } from 'openai/helpers/zod';
import { ProductLabelExtraction, ReceiptExtraction } from '../../src/services/ai/schema.js';
import { assertComplete, buildInput, usageFrom } from '../../src/services/ai/openai.js';
import { AiProviderError } from '../../src/services/ai/types.js';

/** OpenAI strict mode: every object lists all properties as required and forbids extras. */
function assertStrict(node: any, path = '$'): void {
  if (!node || typeof node !== 'object') return;
  if (node.type === 'object' || node.properties) {
    expect(node.additionalProperties, `${path} additionalProperties`).toBe(false);
    expect([...(node.required ?? [])].sort(), `${path} required`).toEqual(Object.keys(node.properties ?? {}).sort());
  }
  for (const [k, v] of Object.entries(node)) if (v && typeof v === 'object') assertStrict(v, `${path}.${k}`);
}

describe('OpenAI provider', () => {
  it('receipt and label schemas are valid strict structured-output schemas', () => {
    for (const [schema, name] of [[ReceiptExtraction, 'receipt_extraction'], [ProductLabelExtraction, 'product_label_extraction']] as const) {
      const fmt = zodTextFormat(schema, name) as any;
      expect(fmt.type).toBe('json_schema');
      expect(fmt.strict).toBe(true);
      assertStrict(fmt.schema);
    }
  });

  it('builds image, PDF and text inputs with the instruction last', () => {
    const img = buildInput({ kind: 'image', mediaType: 'image/png', base64: 'AAA' }, 'Extract.') as any;
    expect(img[0].content[0]).toEqual({ type: 'input_image', image_url: 'data:image/png;base64,AAA', detail: 'high' });
    expect(img[0].content[1]).toEqual({ type: 'input_text', text: 'Extract.' });
    const pdf = buildInput({ kind: 'pdf', base64: 'BBB' }, 'x') as any;
    expect(pdf[0].content[0].type).toBe('input_file');
    expect(pdf[0].content[0].file_data).toBe('data:application/pdf;base64,BBB');
    const txt = buildInput({ kind: 'text', text: '<receipt_document>x</receipt_document>' }, 'x') as any;
    expect(txt[0].content[0].type).toBe('input_text');
  });

  it('prices usage including cached input, and maps refusals/truncation', () => {
    const u = usageFrom({ model: 'gpt-5.4-mini', usage: { input_tokens: 2_000_000, output_tokens: 1_000_000, input_tokens_details: { cached_tokens: 1_000_000 } } }, Date.now());
    // 1M uncached @0.75 + 1M cached @0.75 (no cached price set) + 1M out @4.50
    expect(u.costUsd).toBeCloseTo(0.75 + 0.75 + 4.5, 6);
    expect(u.provider).toBe('openai');
    const refusal = { model: 'm', output: [{ type: 'message', content: [{ type: 'refusal', refusal: 'no' }] }] };
    expect(() => assertComplete(refusal, u)).toThrow(AiProviderError);
    try { assertComplete({ model: 'm', status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } }, u); } catch (e) {
      expect((e as AiProviderError).code).toBe('invalid_output');
      expect((e as AiProviderError).retryable).toBe(false);
    }
    expect(() => assertComplete({ model: 'm', status: 'completed', output: [] }, u)).not.toThrow();
  });
});

describe('claim draft output guard', () => {
  it('accepts claim letters and rejects off-topic or generated code', async () => {
    const { isClaimLetter } = await import('../../src/services/claim.service.js');
    expect(isClaimLetter('Subject: Warranty request — Dyson V15\n\nHello, my vacuum stops after two minutes...')).toBe(true);
    expect(isClaimLetter('OFF_TOPIC')).toBe(false);
    expect(isClaimLetter('Here is a poem about the sea')).toBe(false);
    expect(isClaimLetter('Subject: x\n```python\nprint(1)\n```')).toBe(false);
    expect(isClaimLetter('Subject: x ' + 'word '.repeat(500))).toBe(false);
  });
});
