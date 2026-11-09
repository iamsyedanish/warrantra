/** Support contact (in-app and public), ticket threads, staff replies. */
import type { z } from 'zod';
import { env } from '../config/env.js';
import { check, notFound } from '../lib/errors.js';
import { serviceClient, type Db } from '../lib/supabase.js';
import type { PublicSupportBody, SupportTicketBody } from '../validators/index.js';
import { sendMail } from './mail.service.js';
import { audit } from './ops.service.js';

type Row = Record<string, unknown>;
const retentionDate = () => new Date(Date.now() + 730 * 86_400_000).toISOString().slice(0, 10);

export async function openTicket(userId: string | null, body: z.infer<typeof SupportTicketBody> & { contact_email?: string }) {
  const svc = serviceClient();
  const ticket = check(await svc.from('support_tickets').insert({
    user_id: userId, contact_email: body.contact_email ?? null, subject: body.subject, category: body.category, retention_until: retentionDate(),
    priority: body.category === 'privacy' || body.category === 'deletion' ? 'high' : 'normal',
  }).select('*').single()) as Row;
  check(await svc.from('support_messages').insert({ ticket_id: ticket.id, author_type: 'user', author_id: userId, body: body.message }));
  if (body.contact_email) {
    await sendMail({ to: body.contact_email, subject: `We received your request: ${body.subject}`,
      text: `Thanks for contacting Warrantra support. Reference: ${String(ticket.id).slice(0, 8)}.\nWe'll reply to this address.\n\n${env().SUPPORT_EMAIL}` });
  }
  await audit({ actorType: userId ? 'user' : 'system', actorId: userId, action: 'support.ticket_opened', targetType: 'support_ticket', targetId: String(ticket.id),
                metadata: { category: body.category } });
  return { id: ticket.id, status: ticket.status, support_email: env().SUPPORT_EMAIL };
}

export const openPublicTicket = (body: z.infer<typeof PublicSupportBody>) => openTicket(null, body);

export async function myTickets(db: Db) {
  return check(await db.from('support_tickets').select('id, subject, category, status, created_at, updated_at').order('created_at', { ascending: false }));
}

export async function ticketThread(db: Db, id: string) {
  const t = check(await db.from('support_tickets').select('*').eq('id', id).maybeSingle()) as Row | null;
  if (!t) throw notFound('ticket_not_found');
  const msgs = check(await db.from('support_messages').select('author_type, body, created_at').eq('ticket_id', id).order('created_at'));
  return { ...t, messages: msgs };
}

export async function replyAsUser(db: Db, userId: string, ticketId: string, message: string) {
  await ticketThread(db, ticketId); // RLS ownership check
  const svc = serviceClient();
  check(await svc.from('support_messages').insert({ ticket_id: ticketId, author_type: 'user', author_id: userId, body: message }));
  await svc.from('support_tickets').update({ status: 'open' }).eq('id', ticketId);
  return { sent: true };
}
