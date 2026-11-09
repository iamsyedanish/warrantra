/** Transactional email (deletion verification, workspace invitations, support acks). */
import { env } from '../config/env.js';
import { AppError } from '../lib/errors.js';
import { logger } from '../lib/logger.js';

export interface MailMessage {
  to: string;
  subject: string;
  text: string;
}

export async function sendMail(msg: MailMessage): Promise<void> {
  const e = env();
  if (e.MAIL_PROVIDER === 'log' || !e.RESEND_API_KEY) {
    // Never log recipients or bodies (may contain one-time links).
    logger.info({ subject: msg.subject }, 'mail (log provider)');
    return;
  }
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${e.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: e.MAIL_FROM, to: [msg.to], subject: msg.subject, text: msg.text }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) throw new AppError(502, 'mail_failed', `Mail provider ${res.status}`);
}
