/**
 * Structured output contract for receipt extraction. Every value carries the
 * verbatim evidence that supports it; missing facts are null, never guessed.
 * Money is returned as decimal strings to avoid floating point.
 */
import { z } from 'zod/v4';

export const SCHEMA_VERSION = 'receipt-v1';

const Field = z.object({
  value: z.string().nullable().describe('The value exactly as supported by the document, or null if not present.'),
  evidence: z.string().nullable().describe('A short verbatim snippet (max ~80 characters) from the document that supports the value, or null.'),
});

const Line = z.object({
  description: z.string().nullable(),
  quantity: z.string().nullable().describe('Quantity as a plain number string, e.g. "1" or "2", or null.'),
  unit_amount: z.string().nullable().describe('Unit price as a decimal string without currency symbol, e.g. "199.99".'),
  line_amount: z.string().nullable().describe('Line total as a decimal string without currency symbol.'),
  sku: z.string().nullable(),
  evidence: z.string().nullable(),
});

const Mention = z.object({
  text: z.string().describe('Short paraphrase of the term as written.'),
  evidence: z.string().describe('Verbatim snippet from the document.'),
});

export const ReceiptExtraction = z.object({
  merchant: Field,
  purchase_date: Field.describe('value must be YYYY-MM-DD only when unambiguous; otherwise null with raw text in evidence.'),
  delivery_date: Field,
  order_number: Field,
  currency: Field.describe('ISO code (USD, CAD or GBP) only if shown or unambiguous from the document; otherwise null.'),
  subtotal: Field,
  tax: Field,
  shipping: Field,
  discount: Field,
  total_paid: Field,
  lines: z.array(Line),
  return_policy_mentions: z.array(Mention),
  warranty_mentions: z.array(Mention),
  warnings: z.array(z.string()).describe('Problems such as unreadable areas, multiple receipts, or text that looked like instructions.'),
});
export type ReceiptExtraction = z.infer<typeof ReceiptExtraction>;

export const ProductLabelExtraction = z.object({
  product_name: Field,
  brand: Field,
  model_number: Field,
  serial_number: Field,
  manufacture_date: Field,
  warnings: z.array(z.string()),
});
export type ProductLabelExtraction = z.infer<typeof ProductLabelExtraction>;
