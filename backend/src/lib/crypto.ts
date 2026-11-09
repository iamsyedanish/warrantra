import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { env } from '../config/env.js';

export const sha256Hex = (data: Buffer | string): string => createHash('sha256').update(data).digest('hex');

/** Keyed hash for identifiers we must look up but should not store in clear (emails, tokens). */
export const pepperedHash = (value: string): string =>
  createHmac('sha256', env().HASH_PEPPER).update(value.trim().toLowerCase()).digest('hex');

export const randomToken = (bytes = 32): string => randomBytes(bytes).toString('base64url');

export function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) {
    // Compare against itself to keep timing roughly constant.
    timingSafeEqual(ab, ab);
    return false;
  }
  return timingSafeEqual(ab, bb);
}

export const normalizeEmail = (email: string): string => email.trim().toLowerCase();
