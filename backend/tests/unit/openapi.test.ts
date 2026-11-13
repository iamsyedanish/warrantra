import './setup-env.js';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { generate, parseRoutes } from '../../scripts/openapi.js';

describe('OpenAPI spec', () => {
  it('docs/openapi.json matches the current routes and validators (run `npm run openapi`)', () => {
    expect(readFileSync(new URL('../../docs/openapi.json', import.meta.url), 'utf8')).toBe(generate());
  });

  it('covers every route and marks auth correctly', () => {
    const routes = parseRoutes(readFileSync(new URL('../../src/routes/index.ts', import.meta.url), 'utf8'));
    const spec = JSON.parse(generate());
    const ops = Object.values(spec.paths as Record<string, Record<string, any>>).flatMap((p) => Object.values(p));
    expect(ops).toHaveLength(routes.length);
    expect(spec.paths['/v1/items'].get.security).toEqual([{ bearer: [] }]);
    expect(spec.paths['/v1/public/plans'].get.security).toEqual([]);
    expect(spec.paths['/v1/purchases'].post.parameters.some((p: any) => p.name === 'Idempotency-Key' && p.required)).toBe(true);
  });
});
