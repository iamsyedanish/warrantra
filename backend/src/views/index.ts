/**
 * Views (presenters): shape database rows into API responses. They remove
 * internal fields and add explicit labels so clients always separate known,
 * suggested and unconfirmed information.
 */
type Row = Record<string, unknown>;

const omit = (row: Row, keys: string[]): Row => {
  const out: Row = {};
  for (const [k, v] of Object.entries(row)) if (!keys.includes(k)) out[k] = v;
  return out;
};

export const list = <T>(rows: T[] | null, page?: { limit: number; offset: number }, extra: Row = {}) => {
  const data = rows ?? [];
  return {
  data,
  ...(page ? { page: { limit: page.limit, offset: page.offset, returned: data.length } } : {}),
  ...extra,
  };
};

export const one = <T>(data: T, extra: Row = {}) => ({ data, ...extra });

export const CERTAINTY_LABELS: Record<string, string> = {
  document_verified: 'Verified from a document',
  user_confirmed: 'Confirmed by you',
  estimated: 'Estimated — confirm your actual terms',
  unknown: 'Unknown',
};

export const TERM_LABELS: Record<string, string> = {
  fixed_date: 'Fixed end date',
  duration: 'Fixed duration',
  lifetime: 'Lifetime (as stated by the provider; conditions may apply)',
  conditional: 'Conditional terms',
  unknown: 'Terms unknown',
};

export function itemView(row: Row): Row {
  return omit(row, ['search_text']);
}

export function warrantyView(row: Row): Row {
  const certainty = String(row.date_certainty ?? 'unknown');
  return {
    ...row,
    labels: {
      certainty: CERTAINTY_LABELS[certainty],
      term: TERM_LABELS[String(row.term_kind ?? 'unknown')],
      alerts_enabled:
        row.contract_state === 'active' &&
        row.end_date !== null &&
        (certainty === 'document_verified' || certainty === 'user_confirmed' || row.estimate_accepted_at !== null),
      needs_confirmation: certainty === 'estimated' && !row.estimate_accepted_at,
      disclaimer:
        row.coverage_type === 'statutory_note'
          ? 'Warrantra does not calculate statutory rights. This is your own note.'
          : 'Warrantra records coverage information; it does not insure purchases or guarantee claims.',
    },
  };
}

export function returnWindowView(row: Row): Row {
  const certainty = String(row.date_certainty ?? 'unknown');
  return {
    ...row,
    labels: {
      certainty: CERTAINTY_LABELS[certainty],
      deadline_meaning:
        {
          request_by: 'Start the return by this date',
          postmark_by: 'Item must be postmarked by this date',
          merchant_receipt_by: 'Item must reach the merchant by this date',
          unknown: 'What this deadline means is unknown — check the retailer policy',
        }[String(row.deadline_basis)] ?? null,
      terms: row.terms_state === 'unknown' ? 'Return terms unknown — no default window is assumed' : null,
      needs_confirmation: certainty === 'estimated' && !row.estimate_accepted_at,
    },
  };
}

export function registrationView(row: Row): Row {
  return {
    ...row,
    labels: {
      requirement:
        {
          unknown: 'Whether registration is required is unknown',
          optional: 'Registration is optional',
          extra_benefit: 'Registration may add a benefit',
          terms_stated_required: 'The terms state registration is required',
        }[String(row.requirement_state)] ?? null,
      completion_note: row.status === 'link_opened' ? 'Opening the registration page does not confirm registration.' : null,
    },
  };
}

export function attachmentView(row: Row): Row {
  return omit(row, ['usage_reservation_id', 'idempotency_key', 'bucket', 'preview_path']);
}

export function claimView(row: Row): Row {
  return {
    ...row,
    labels: {
      submission: 'Warrantra does not submit claims. Send it through the provider; opening an email app is not submission.',
      ai_draft: row.ai_draft_text ? 'AI-assisted draft — review every statement before sending.' : null,
    },
  };
}

export function deviceView(row: Row): Row {
  return omit(row, ['push_token']);
}

export function entitlementView(summary: Row): Row {
  return {
    ...summary,
    note: 'Cancelling a subscription stops renewal; paid access continues until the end of the paid period.',
  };
}
