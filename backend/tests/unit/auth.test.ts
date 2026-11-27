import './setup-env.js';
import { describe, expect, it } from 'vitest';
import { idTokenEmail } from '../../src/services/auth.service.js';

const jwt = (payload: object) =>
  ['eyJhbGciOiJSUzI1NiJ9', Buffer.from(JSON.stringify(payload)).toString('base64url'), 'signature'].join('.');

describe('provider ID token email (sign-in gate)', () => {
  it('reads and lower-cases the email claim', () => {
    expect(idTokenEmail(jwt({ email: ' Someone@Gmail.com ', email_verified: true }))).toBe('someone@gmail.com');
  });
  it('returns null for tokens without a usable email', () => {
    expect(idTokenEmail(jwt({ sub: '123' }))).toBeNull();
    expect(idTokenEmail(jwt({ email: 'not-an-email' }))).toBeNull();
    expect(idTokenEmail('garbage')).toBeNull();
    expect(idTokenEmail('a.%%%.c')).toBeNull();
  });
});
