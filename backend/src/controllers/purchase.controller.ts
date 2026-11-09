/** Purchases, items, coverage, payment-card labels, reference data, Action Center. */
import type { Request, Response } from 'express';
import { z } from 'zod';
import { authOf } from '../middleware/auth.js';
import { check } from '../lib/errors.js';
import { expectedVersion, idempotencyKey, PaginationQuery, parseOrThrow } from '../lib/http.js';
import { PaymentCards } from '../models/index.js';
import { coverage } from '../services/coverage.service.js';
import * as items from '../services/item.service.js';
import * as purchases from '../services/purchase.service.js';
import { itemView, list, one, registrationView, returnWindowView, warrantyView } from '../views/index.js';
import * as V from '../validators/index.js';

const id = (req: Request) => parseOrThrow(z.object({ id: V.Uuid }), req.params, 'params').id;

export const PurchaseController = {
  create: async (req: Request, res: Response) => {
    const a = authOf(req);
    const result = await purchases.createPurchase(a.db, a.userId, idempotencyKey(req)!, parseOrThrow(V.PurchaseInput, req.body, 'body'));
    res.status(result.created ? 201 : 200).json(one(result));
  },
  get: async (req: Request, res: Response) => {
    res.json(one(await purchases.getPurchase(authOf(req).db, id(req))));
  },
  list: async (req: Request, res: Response) => {
    const p = parseOrThrow(PaginationQuery, req.query, 'query');
    const rows = check(await authOf(req).db.from('purchase_groups').select('id, retailer, order_number, purchase_date, delivery_date, currency, total_paid, source, created_at, items(id, name)')
      .order('purchase_date', { ascending: false, nullsFirst: false }).range(p.offset, p.offset + p.limit - 1));
    res.json(list(rows as unknown[], p));
  },
  update: async (req: Request, res: Response) => {
    const patch = parseOrThrow(V.PurchaseInput.pick({ retailer: true, order_number: true, purchase_date: true, delivery_date: true, notes: true, payment_card_id: true }).partial(), req.body, 'body');
    const row = check(await authOf(req).db.from('purchase_groups').update(patch).eq('id', id(req)).select('*').maybeSingle());
    res.json(one(row));
  },
  remove: async (req: Request, res: Response) => {
    // Deleting a purchase keeps its items (they lose the group link) and keeps documents in the vault.
    check(await authOf(req).db.from('purchase_groups').delete().eq('id', id(req)));
    res.status(204).end();
  },
  trackLine: async (req: Request, res: Response) => {
    const lineId = parseOrThrow(z.object({ lineId: V.Uuid }), req.params, 'params').lineId;
    res.status(201).json(one(itemView(await purchases.trackLine(authOf(req).db, lineId, parseOrThrow(V.TrackLineBody, req.body, 'body')))));
  },
};

export const ItemController = {
  quickAdd: async (req: Request, res: Response) => {
    const a = authOf(req);
    const result = await purchases.quickAddItem(a.db, a.userId, idempotencyKey(req)!, parseOrThrow(V.QuickAddItemInput, req.body, 'body'));
    res.status(result.created ? 201 : 200).json(one(result, { next: 'Ask for notification permission after the first saved item.' }));
  },
  list: async (req: Request, res: Response) => {
    const q = parseOrThrow(V.ItemListQuery, req.query, 'query');
    const { rows, total } = await items.listItems(authOf(req).db, q);
    res.json(list(rows.map(itemView), { limit: q.limit, offset: q.offset }, { total }));
  },
  get: async (req: Request, res: Response) => {
    const detail = await items.getItemDetail(authOf(req).db, id(req));
    const cov = detail.coverage;
    res.json(one({
      ...itemView(detail),
      coverage: {
        warranties: cov.warranties.map(warrantyView),
        return_windows: cov.return_windows.map(returnWindowView),
        registrations: cov.registrations.map(registrationView),
      },
    }));
  },
  update: async (req: Request, res: Response) => {
    res.json(one(itemView(await items.updateItem(authOf(req).db, id(req), parseOrThrow(V.ItemPatch, req.body, 'body'), expectedVersion(req)))));
  },
  remove: async (req: Request, res: Response) => {
    await items.deleteItem(authOf(req).db, id(req));
    res.status(204).end();
  },
  timeline: async (req: Request, res: Response) => {
    res.json(list(check(await authOf(req).db.rpc('get_item_timeline', { p_item_id: id(req) })) as unknown[]));
  },
  suggestions: async (req: Request, res: Response) => {
    res.json(one(await coverage.suggestions(authOf(req).db, id(req))));
  },
  actionCenter: async (req: Request, res: Response) => {
    const horizon = parseOrThrow(z.object({ horizon_days: z.coerce.number().int().min(1).max(365).default(60) }), req.query, 'query').horizon_days;
    res.json(one(await items.actionCenter(authOf(req).db, horizon)));
  },
};

export const CoverageController = {
  listForItem: async (req: Request, res: Response) => {
    const c = await coverage.listForItem(authOf(req).db, id(req));
    res.json(one({ warranties: c.warranties.map(warrantyView), return_windows: c.return_windows.map(returnWindowView), registrations: c.registrations.map(registrationView) }));
  },
  addWarranty: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(warrantyView(await coverage.addWarranty(a.db, a.userId, id(req), parseOrThrow(V.WarrantyInput, req.body, 'body')))));
  },
  updateWarranty: async (req: Request, res: Response) => {
    res.json(one(warrantyView(await coverage.updateWarranty(authOf(req).db, id(req), parseOrThrow(V.WarrantyPatch, req.body, 'body'), expectedVersion(req)))));
  },
  removeWarranty: async (req: Request, res: Response) => {
    await coverage.removeWarranty(authOf(req).db, id(req));
    res.status(204).end();
  },
  addReturnWindow: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(returnWindowView(await coverage.addReturnWindow(a.db, a.userId, id(req), parseOrThrow(V.ReturnWindowInput, req.body, 'body')))));
  },
  updateReturnWindow: async (req: Request, res: Response) => {
    res.json(one(returnWindowView(await coverage.updateReturnWindow(authOf(req).db, id(req), parseOrThrow(V.ReturnWindowPatch, req.body, 'body'), expectedVersion(req)))));
  },
  removeReturnWindow: async (req: Request, res: Response) => {
    await coverage.removeReturnWindow(authOf(req).db, id(req));
    res.status(204).end();
  },
  addRegistration: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(registrationView(await coverage.addRegistration(a.db, a.userId, id(req), parseOrThrow(V.RegistrationInput, req.body, 'body')))));
  },
  updateRegistration: async (req: Request, res: Response) => {
    res.json(one(registrationView(await coverage.updateRegistration(authOf(req).db, id(req), parseOrThrow(V.RegistrationPatch, req.body, 'body'), expectedVersion(req)))));
  },
  removeRegistration: async (req: Request, res: Response) => {
    await coverage.removeRegistration(authOf(req).db, id(req));
    res.status(204).end();
  },
};

export const CardController = {
  list: async (req: Request, res: Response) => {
    res.json(list(check(await authOf(req).db.from('payment_cards').select('*, card_benefits(id, card_name, issuer, benefit_summary, source_url, last_verified_at)').order('created_at'))));
  },
  create: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await PaymentCards(a.db).insert({ ...parseOrThrow(V.PaymentCardBody, req.body, 'body'), user_id: a.userId })));
  },
  update: async (req: Request, res: Response) => {
    res.json(one(await PaymentCards(authOf(req).db).update(id(req), parseOrThrow(V.PaymentCardBody.partial(), req.body, 'body'), undefined, 'card_not_found')));
  },
  remove: async (req: Request, res: Response) => {
    await PaymentCards(authOf(req).db).remove(id(req), 'card_not_found');
    res.status(204).end();
  },
};

export const ReferenceController = {
  categories: async (req: Request, res: Response) => {
    res.json(list(check(await authOf(req).db.from('categories').select('id, slug, name').order('sort_order'))));
  },
  brands: async (req: Request, res: Response) => {
    const q = typeof req.query.q === 'string' ? req.query.q.trim().slice(0, 60) : '';
    let query = authOf(req).db.from('brands').select('id, name, support_url, registration_url, support_email, support_phone, last_verified_at').order('name').limit(50);
    if (q) query = query.ilike('name', `%${q.replace(/[%_]/g, '')}%`);
    res.json(list(check(await query) as unknown[], undefined, { note: 'Brand contact details are reference information; verify before relying on them.' }));
  },
  cardBenefits: async (req: Request, res: Response) => {
    res.json(list(check(await authOf(req).db.from('card_benefits').select('id, card_name, issuer, network, country_code, extension_months, max_original_warranty_months, maximum_coverage_amount, coverage_currency, benefit_summary, exclusions, enrollment_required, terms_url, source_url, effective_from, effective_to, last_verified_at').order('issuer')) as unknown[],
      undefined, { note: 'Review the card issuer\'s official terms before relying on any benefit.' }));
  },
};
