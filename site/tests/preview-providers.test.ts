import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { initialPreviewState, restorePreviewState } from '../src/data/preview-state.ts';
import { providers } from '../src/data/providers.ts';

test('the site lists each native catalog provider in registration order', () => {
  const catalog = readFileSync(new URL('../../Sources/Egasu/Providers/ProviderCatalog.swift', import.meta.url), 'utf8');
  const make = catalog.slice(catalog.indexOf('static func make('), catalog.indexOf('return runtimes'));
  const families = Array.from(make.matchAll(/\b(\w+)Provider\(/g), ([, name]) =>
    name === 'OpenAICosts' ? 'openai-api' : name.toLowerCase());
  assert.deepEqual(providers.map((provider) => provider.id), families);
});

test('saved catalogs keep customized state and append new providers in default order', () => {
  const legacyOrder = ['zai', 'codex', 'claude', 'cursor', 'antigravity', 'copilot', 'devin', 'grok', 'kimi', 'kiro', 'opencode', 'openrouter'];
  const current = initialPreviewState();
  const additions = current.providerOrder.filter((id) => !legacyOrder.includes(id));
  assert.ok(additions.length > 0);
  for (let adopted = 0; adopted < additions.length; adopted++) {
    const providerOrder = [...additions.slice(0, adopted).reverse(), ...legacyOrder];
    const saved = {
      ...current,
      preferences: { ...current.preferences, language: '한국어', theme: 'Dark' },
      activeAccounts: { ...current.activeAccounts, claude: 'account-2' },
      enabledProviders: ['codex', 'claude'],
      hiddenMetrics: ['claude.session@account-1'], pinnedMetrics: ['codex.weekly@account-1'],
      accountNames: { 'claude:account-1': 'Work' },
      accountOrder: { ...current.accountOrder, claude: ['account-2', 'account-1'] },
      providerOrder,
    };
    assert.deepEqual(restorePreviewState(saved), { ...saved, providerOrder: [...providerOrder, ...additions.slice(adopted)] });
  }
});

test('restoring provider order rejects duplicates, unknown IDs and malformed values', () => {
  const current = initialPreviewState();
  for (const providerOrder of [['claude', 'claude'], ['unknown'], [null], 'claude']) {
    assert.throws(() => restorePreviewState({ ...current, providerOrder }), /Invalid preview order/);
  }
});
