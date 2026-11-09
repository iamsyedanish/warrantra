/**
 * Recursively removes sensitive keys from objects destined for logs, analytics or
 * audit metadata. Keys are matched case-insensitively.
 */
const SENSITIVE_KEYS = new Set([
  'password', 'token', 'access_token', 'refresh_token', 'id_token', 'push_token', 'authorization',
  'serial_number', 'serialnumber', 'signedurl', 'signed_url', 'signeduploadurl', 'url', 'storage_path',
  'api_key', 'apikey', 'secret', 'receipt_text', 'ocr_text', 'candidate', 'raw', 'body', 'html', 'text',
  'email', 'contact_email', 'from', 'to', 'issue_description', 'ai_draft_text', 'snapshot', 'payload',
  'card_number', 'pan', 'cvv',
]);

export function redactDeep(value: unknown, depth = 0): unknown {
  if (depth > 6 || value === null || value === undefined) return value;
  if (Array.isArray(value)) return value.slice(0, 50).map((v) => redactDeep(v, depth + 1));
  if (typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (SENSITIVE_KEYS.has(k.toLowerCase())) {
        out[k] = '[redacted]';
      } else {
        out[k] = redactDeep(v, depth + 1);
      }
    }
    return out;
  }
  return value;
}
