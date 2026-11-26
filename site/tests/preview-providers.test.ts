import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { providers } from '../src/data/providers.ts';

test('the site lists each native catalog provider in registration order', () => {
  const catalog = readFileSync(new URL('../../Sources/Egasu/Providers/ProviderCatalog.swift', import.meta.url), 'utf8');
  const make = catalog.slice(catalog.indexOf('static func make('), catalog.indexOf('return runtimes'));
  const families = Array.from(make.matchAll(/\b(\w+)Provider\(/g), ([, name]) =>
    name === 'OpenAICosts' ? 'openai-api' : name.toLowerCase());
  assert.deepEqual(providers.map((provider) => provider.id), families);
});
