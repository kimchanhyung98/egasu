import { test, expect, openHome, openSettings, chooseSetting, allUsage, accountDetail, openAccounts } from './fixtures';

test('Accounts confirms switching and preserves both registered account limits', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await accountDetail(page, 'claude', 'account-2');
  const second = app.locator('[data-scr="account:claude:account-2"] [data-account-switch]');
  await second.click();
  const dialog = app.getByRole('dialog', { name: 'Switch Account?' });
  await expect(dialog).toBeVisible();
  await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(second).toBeFocused();
  await expect(second).toHaveAttribute('aria-checked', 'false');
  await second.click();
  await dialog.getByRole('button', { name: 'Switch Account', exact: true }).click();
  await expect(second).toHaveAttribute('aria-checked', 'true');
  await page.reload();
  await allUsage(page);
  for (const accountID of ['account-1', 'account-2']) {
    const card = app.locator(`[data-card="claude-${accountID}"]`);
    await expect(card).toBeVisible();
    await expect(card.locator('[data-row="claude.session"]')).toBeVisible();
  }
  await expect(app.locator('[data-card="claude-account-2"]')).toHaveAttribute('data-inactive-account', 'false');
});

test('reordering accounts updates All Usage and survives a reload', async ({ page }) => {
  await openHome(page);
  await openAccounts(page);
  const app = page.locator('[data-mock]');
  const accountRows = app.locator('[data-account-list-row][data-provider="claude"]');
  await app.locator('[data-drag-account="claude:account-2"]').dragTo(app.locator('[data-drag-account="claude:account-1"]'));
  await expect(accountRows.first()).toHaveAttribute('data-account-id', 'account-2');
  await expect(accountRows.locator('[data-in-use="claude"]:visible')).toHaveAttribute('data-account-id', 'account-1');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await page.reload();
  await allUsage(page);
  const cards = app.locator('[data-family="claude"] [data-card]');
  await expect(cards.first()).toHaveAttribute('data-card', 'claude-account-2');
  await expect(cards.last()).toHaveAttribute('data-card', 'claude-account-1');
});

test('display settings and separate account cards survive a reload', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await chooseSetting(page, 'Theme', 'Dark');
  await chooseSetting(page, 'All Usage Layout', 'Cards');
  await chooseSetting(page, 'Time Format', '12-hour');
  await chooseSetting(page, 'Show Usage As', 'Left');
  await chooseSetting(page, 'Reset Times', 'Countdown');
  await app.getByRole('switch', { name: 'Show Total Spend', exact: true }).click();
  await page.reload();
  await expect(app).toHaveAttribute('data-theme', 'dark');
  await expect(app).toHaveAttribute('data-layout', 'cards');
  await expect(app).toHaveAttribute('data-mode', 'left');
  await expect(app).toHaveAttribute('data-reset', 'relative');
  await allUsage(page);
  await expect(app.locator('.am-spend-card')).toBeHidden();
  await expect(app.locator('[data-family="claude"] .am-account-caption [data-account-name]')).toHaveText(['Account 1', 'Account 2']);
  await expect(app.locator('[data-card="claude-account-1"]')).toBeVisible();
  await expect(app.locator('[data-card="claude-account-2"]')).toBeVisible();
});

test('pinned-only guidance is beside the setting when the saved pin cannot show', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { menuBarItems: 'Pinned Only' }, activeAccounts: {}, enabledProviders: ['antigravity'],
    pinnedMetrics: ['claude.fable@account-1'],
  })));
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  await expect(app.locator('[data-menu-bar-preview]')).toHaveText('◉');
  const row = app.locator('.am-item').filter({ has: page.getByRole('button', { name: 'Menu Bar Items', exact: true }) });
  await expect(row.getByRole('button', {
    name: 'Choose Priority or Pinned Only, then pin metrics in All Usage to show them in the menu bar.', exact: true,
  })).toBeVisible();
});

test('menu bar preview applies pinned selection and filters text values in Bars mode', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await accountDetail(page, 'claude');
  const detail = app.locator('[data-scr="account:claude:account-1"]');
  await detail.locator('[data-pin="claude.today"]').click();
  await detail.locator('[data-pin="claude.fable"]').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await openSettings(page);
  await chooseSetting(page, 'Menu Bar Items', 'Pinned Only');
  await expect(app.locator('.am-menu-preview-item')).toHaveCount(2);
  await chooseSetting(page, 'Icon Style', 'Bars');
  await expect(app.locator('.am-menu-preview-item')).toHaveCount(1);
  await expect(app.locator('.am-menu-preview-bar')).toHaveAttribute('aria-label', 'Claude Fable 100%');
  await chooseSetting(page, 'Max Items In Menu Bar', 'App Icon Only');
  await expect(app.locator('[data-menu-bar-preview]')).toHaveText('◉');
});

test('preview parity keeps count and dollar amounts in All Usage and menu bar Text', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { defaultTab: 'All Usage', menuBarItems: 'Pinned Only' },
    activeAccounts: {}, enabledProviders: ['kiro', 'opencode'], pinnedMetrics: ['kiro.credits', 'opencode.monthly'],
  })));
  await openHome(page);
  const app = page.locator('[data-mock]');
  const kiro = app.locator('[data-metric="kiro.credits"] [data-toggle-meter]');
  const openCode = app.locator('[data-metric="opencode.monthly"] [data-toggle-meter]');
  await expect.soft(kiro.locator(':scope > :visible')).toHaveText('23', { timeout: 1000 });
  await expect.soft(openCode.locator(':scope > :visible')).toHaveText('$24.00', { timeout: 1000 });
  await kiro.click();
  await expect.soft(kiro.locator(':scope > :visible')).toHaveText('27', { timeout: 1000 });
  await expect.soft(openCode.locator(':scope > :visible')).toHaveText('$36.00', { timeout: 1000 });
  await openSettings(page);
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  const preview = app.getByRole('region', { name: 'Menu Bar Preview', exact: true });
  const kiroReading = preview.getByRole('img').filter({ hasText: 'Kiro' });
  const openCodeReading = preview.getByRole('img').filter({ hasText: 'OpenCode' });
  await expect.soft(kiroReading).toHaveAccessibleName('Kiro Credits 27', { timeout: 1000 });
  await expect.soft(openCodeReading).toHaveAccessibleName('OpenCode Monthly $36', { timeout: 1000 });
  await chooseSetting(page, 'Show Usage As', 'Used');
  await expect.soft(kiroReading).toHaveAccessibleName('Kiro Credits 23', { timeout: 1000 });
  await expect.soft(openCodeReading).toHaveAccessibleName('OpenCode Monthly $24', { timeout: 1000 });
});

test('preview parity preserves a literal account name in localized menu bar accessibility', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { menuBarItems: 'Pinned Only', menuBarAccountNames: true, menuBarResetCountdown: true },
    activeAccounts: {}, enabledProviders: ['codex'], pinnedMetrics: ['codex.session@account-1'],
  })));
  await openHome(page);
  const app = page.locator('[data-mock]');
  await accountDetail(page, 'codex');
  const name = 'Alpha · Settings · Beta';
  const input = app.locator('[data-rename-input]:visible');
  await input.fill(name);
  await input.press('Enter');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await openSettings(page);
  for (const [language, reading] of [
    ['한국어', 'Codex Alpha · Settings · Beta 세션 28%, 3시간+ 후 초기화'],
    ['日本語', 'Codex Alpha · Settings · Beta セッション 28%、3時間+後にリセット'],
  ]) {
    await chooseSetting(page, 'Language', language);
    await app.locator('[data-settings-tab="Display"]').click();
    const item = app.locator('[data-menu-bar-preview] [role="img"]');
    await expect(item.locator('.am-menu-preview-label')).toHaveText(name);
    await expect.soft(item).toHaveAccessibleName(reading, { timeout: 1000 });
  }
});

test('preview parity shows both ends of long menu bar account names', async ({ page }) => {
  const prefix = 'shared-long-account-email@example.com';
  await page.addInitScript((prefix) => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { menuBarItems: 'Pinned Only', menuBarAccountNames: true, menuBarResetCountdown: true },
    activeAccounts: {}, enabledProviders: ['codex'], pinnedMetrics: ['codex.session@account-1', 'codex.session@account-2'],
    accountNames: { 'codex:account-1': `${prefix} (North)`, 'codex:account-2': `${prefix} (South)` },
  })), prefix);
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  const preview = app.getByRole('region', { name: 'Menu Bar Preview', exact: true });
  for (const suffix of ['(North)', '(South)']) {
    const item = preview.getByRole('img', { name: `${prefix} ${suffix}`, exact: false });
    const label = item.locator('.am-menu-preview-label');
    await expect(label).toBeVisible();
    const ends = await label.evaluate((element, suffix) => {
      const bounds = element.getBoundingClientRect();
      const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
      const visible = (value: string) => {
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const offset = node.textContent?.indexOf(value) ?? -1;
          if (offset < 0) continue;
          const range = document.createRange();
          range.setStart(node, offset);
          range.setEnd(node, offset + value.length);
          const rect = range.getBoundingClientRect();
          return rect.width > 0 && rect.left >= bounds.left - 1 && rect.right <= bounds.right + 1;
        }
        return false;
      };
      walker.currentNode = element;
      const start = visible('shared');
      walker.currentNode = element;
      return { start, end: visible(suffix) };
    }, suffix);
    expect.soft(ends).toEqual({ start: true, end: true });
  }
});

test('menu bar reset countdown applies only to eligible Text items and keeps its saved choice', async ({ page }) => {
  await page.addInitScript(() => {
    if (localStorage.getItem('openusage.site.preview.v1')) return;
    localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
      preferences: { menuBarItems: 'Pinned Only', menuBarLimit: 'Up to 4' },
      activeAccounts: {},
      pinnedMetrics: ['codex.session@account-1', 'codex.weekly@account-1', 'antigravity.geminiPro', 'kiro.credits'],
      enabledProviders: ['codex', 'antigravity', 'kiro'],
    }));
  });
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  const countdown = app.getByRole('switch', { name: 'Show Reset Countdown', exact: true });
  const preview = app.getByRole('region', { name: 'Menu Bar Preview', exact: true });
  await expect(countdown).toBeEnabled();
  await expect(countdown).not.toBeChecked();
  await expect(preview.locator('.am-menu-preview-item')).toHaveCount(4);
  await expect(preview).not.toContainText('3h+');
  await countdown.click();
  await expect(countdown).toBeChecked();
  await expect(preview).toContainText('28% 3h+');
  await expect(preview).toContainText('97% 4d+');
  await expect(preview).not.toContainText('5h+');
  await expect(preview).not.toContainText('15d+');
  const session = preview.getByRole('img', { name: 'Codex Account 1 Session 28%, Resets in 3h+', exact: true });
  await expect(session).toBeVisible();
  await app.getByRole('switch', { name: 'Show Account Names', exact: true }).click();
  await expect(session.locator('.am-menu-preview-label')).toHaveText('Account 1');
  await expect(session).toContainText('5h');
  const sameLine = await session.locator('.am-menu-preview-countdown').evaluate((amount) => {
    const value = amount.firstChild;
    const duration = amount.lastElementChild;
    if (!value || !duration) return false;
    const range = document.createRange();
    range.selectNodeContents(value);
    return Math.abs(range.getBoundingClientRect().top - duration.getBoundingClientRect().top) < 1;
  });
  expect(sameLine, 'the value and countdown stay on one line when the preview wraps').toBe(true);
  await app.getByRole('switch', { name: 'Show Metric Labels', exact: true }).click();
  await expect(session).not.toContainText('5h');
  await expect(session).toContainText('28% 3h+');
  await chooseSetting(page, 'Show Usage As', 'Left');
  await expect(preview).toContainText('72% 3h+');
  await chooseSetting(page, 'Icon Style', 'Bars');
  await expect(countdown).toBeDisabled();
  await expect(preview).not.toContainText('3h+');
  await chooseSetting(page, 'Icon Style', 'Text');
  await chooseSetting(page, 'Max Items In Menu Bar', 'App Icon Only');
  await expect(countdown).toBeDisabled();
  await expect(preview).toHaveText('◉');
  await chooseSetting(page, 'Max Items In Menu Bar', 'Up to 4');
  await expect(countdown).toBeChecked();
  await page.reload();
  await openSettings(page);
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  await expect(countdown).toBeChecked();
  await expect(preview).toContainText('72% 3h+');
});

test('settings saved before the egasu rename are restored and remain editable', async ({ page }) => {
  await page.addInitScript(() => {
    if (localStorage.getItem('openusage.site.preview.v1')) return;
    localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
      preferences: { theme: 'Dark', showUsageAs: 'Left', usageCards: 'Single Card' },
      activeAccounts: { claude: 'account-1' },
      viewedAccounts: { claude: 'account-2' },
    }));
  });
  await openHome(page);
  const app = page.locator('[data-mock]');
  await expect(app).toHaveAttribute('data-theme', 'dark');
  await expect(app).toHaveAttribute('data-mode', 'left');
  await allUsage(page);
  await expect(app.locator('[data-card="claude-account-2"]')).toBeVisible();
  await expect(app.locator('[data-card="claude-account-1"]')).toBeVisible();
  await openSettings(page);
  await chooseSetting(page, 'Theme', 'Light');
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('openusage.site.preview.v1')!).preferences))
    .toMatchObject({ theme: 'Light', showUsageAs: 'Left', allUsageLayout: 'Minimal' });
  await page.reload();
  await expect(app).toHaveAttribute('data-theme', 'light');
  await expect(app).toHaveAttribute('data-mode', 'left');
  await allUsage(page);
  await expect(app.locator('[data-card="claude-account-2"]')).toBeVisible();
});

test('legacy meter and reset settings survive the egasu rename', async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('openusage.site.meterStyle', 'left');
    localStorage.setItem('openusage.site.resetDisplayMode', 'relative');
  });
  await openHome(page);
  const app = page.locator('[data-mock]');
  await expect(app).toHaveAttribute('data-mode', 'left');
  await expect(app).toHaveAttribute('data-reset', 'relative');
});

test('invalid saved settings recover with defaults and a visible explanation', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', '{broken'));
  await openHome(page);
  const app = page.locator('[data-mock]');
  await expect(app).toHaveAttribute('data-mode', 'used');
  await expect(app.getByRole('status')).toContainText('Saved preview settings could not be loaded');
  await expect(app.locator('[data-dashboard-panel="Priority"]')).toBeVisible();
});

test('blocked storage reports unsaved changes while the current preview still works', async ({ page }) => {
  await page.addInitScript(() => {
    Storage.prototype.setItem = () => { throw new DOMException('Storage is blocked', 'SecurityError'); };
  });
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await chooseSetting(page, 'Theme', 'Dark');
  await expect(app).toHaveAttribute('data-theme', 'dark');
  await expect(app.getByRole('status')).toContainText('Preview changes could not be saved');
  await page.reload();
  await expect(app).toHaveAttribute('data-theme', 'light');
});

test('active account switch announces unavailability and keeps focus after switching', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await accountDetail(page, 'claude');
  const firstDetail = app.locator('[data-scr="account:claude:account-1"]');
  const first = firstDetail.getByRole('switch', { name: 'Use This Account' });
  const second = app.locator('[data-scr="account:claude:account-2"] [data-account-switch]');
  const dialog = app.locator('[data-account-dialog]');
  await expect(first).toHaveAttribute('aria-disabled', 'true');
  await expect(first).toHaveJSProperty('disabled', false);
  await first.press('Enter');
  await expect(first).toBeFocused();
  await expect(dialog).toBeHidden();

  await firstDetail.locator('.am-back').click();
  await app.locator('[data-account-list] .am-open[data-go="account:claude:account-2"]').click();
  await expect(second).toHaveAttribute('aria-disabled', 'false');
  await second.click();
  await dialog.getByRole('button', { name: 'Switch Account', exact: true }).click();
  await expect(second).toHaveAttribute('aria-checked', 'true');
  await expect(second).toHaveAttribute('aria-disabled', 'true');
  await expect(second).toHaveJSProperty('disabled', false);
  await expect(second).toBeFocused();
  await expect(firstDetail.locator('[data-account-switch]')).toHaveAttribute('aria-disabled', 'false');
});

test('dashboard account display describes its localized action while preserving the visible accessible name', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { language: '한국어' }, activeAccounts: {},
  })));
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const cardName = app.locator('[data-card="claude-account-1"] [data-toggle-account-name]');
  const priorityName = app.locator('[data-priority-key="claude.weekly@account-1"] [data-toggle-account-name]');
  const showEmails = '대시보드에 예시 이메일 주소를 표시합니다.';
  const showNames = '대시보드에 계정 이름을 표시합니다.';
  const masked = 'Privacy Mode에서는 이름과 이메일 주소가 가려집니다.';
  await expect(cardName).toHaveAccessibleDescription(showEmails);
  await expect(cardName).toHaveAccessibleName((await cardName.textContent())!.trim());
  await cardName.press('Enter');
  await expect(cardName).toHaveAccessibleName('claude.account-1@example.com');
  await expect(cardName).toHaveAccessibleDescription(showNames);
  await expect(cardName).toBeFocused();

  await app.locator('button[role="tab"][data-dashboard-tab="Priority"]').click();
  await expect(priorityName).toHaveAccessibleDescription(showNames);
  await priorityName.press('Enter');
  await expect(priorityName).toHaveAccessibleDescription(showEmails);
  await expect(priorityName).toBeFocused();

  await app.locator('[data-options]').click();
  await app.locator('.am-optmenu [data-go="settings"]').click();
  await app.locator('button[data-settings-tab="Advanced"]').click();
  await app.locator('[data-setting="privacyMode"]').click();
  await app.locator('[data-scr="settings"] .am-back').click();
  await expect(priorityName).toHaveAccessibleName('••••@example.com');
  await expect(priorityName).toHaveAccessibleDescription(masked);
  await allUsage(page);
  await expect(cardName).toHaveAccessibleName('••••@example.com');
  await expect(cardName).toHaveAccessibleDescription(masked);
});


test('menu bar text options update names and periods, survive reload and disable for non-text styles', async ({ page }) => {
  await page.addInitScript(() => {
    if (localStorage.getItem('openusage.site.preview.v1')) return;
    localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
      preferences: { menuBarItems: 'Pinned Only', menuBarLimit: 'Up to 1' },
      activeAccounts: {},
      pinnedMetrics: ['claude.weekly@account-1'], accountNames: { 'claude:account-1': 'Personal' },
    }));
  });
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  const names = app.getByRole('switch', { name: 'Show Account Names', exact: true });
  const metrics = app.getByRole('switch', { name: 'Show Metric Labels', exact: true });
  const preview = app.locator('[data-menu-bar-preview]');
  await expect(names).toHaveAttribute('aria-checked', 'false');
  await expect(metrics).toHaveAttribute('aria-checked', 'true');
  await expect(preview.locator('.am-menu-preview-label')).toHaveText('Weekly');
  await names.click();
  await expect(preview.locator('.am-menu-preview-label')).toHaveText('Personal');
  await expect(preview).toContainText('7d');
  await expect(preview.getByRole('img')).toHaveAccessibleName(/Claude Personal Weekly/);
  await metrics.click();
  await expect(preview).not.toContainText('7d');
  await expect(preview.locator('.am-menu-preview-label')).toHaveText('Personal');
  await page.reload();
  await openSettings(page);
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  await expect(names).toHaveAttribute('aria-checked', 'true');
  await expect(metrics).toHaveAttribute('aria-checked', 'false');
  await chooseSetting(page, 'Icon Style', 'Bars');
  await expect(names).toBeDisabled();
  await expect(metrics).toBeDisabled();
  await chooseSetting(page, 'Icon Style', 'Text');
  await expect(names).toBeEnabled();
  await chooseSetting(page, 'Max Items In Menu Bar', 'App Icon Only');
  await expect(names).toBeDisabled();
  await expect(metrics).toBeDisabled();
  await chooseSetting(page, 'Max Items In Menu Bar', 'Up to 1');
  await app.getByRole('tab', { name: 'Advanced', exact: true }).click();
  await app.getByRole('switch', { name: 'Privacy Mode', exact: true }).click();
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  await expect(preview).not.toContainText('Personal');
  await expect(preview.getByRole('img')).toHaveAccessibleName(/Claude Weekly/);
  await expect(preview.getByRole('img')).not.toHaveAccessibleName(/Personal/);
});

test('menu bar names and initials use the selected language', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { menuBarItems: 'Pinned Only', menuBarLimit: 'Up to 1', language: '한국어' },
    activeAccounts: {}, pinnedMetrics: ['claude.weekly@account-1'],
  })));
  await openHome(page);
  const app = page.locator('[data-mock]');
  await app.locator('[data-options]').click();
  await app.locator('[data-go="settings"]').click();
  await app.locator('[data-settings-tab="Display"]').click();
  const preview = app.locator('[data-menu-bar-preview]');
  await expect(preview.locator('.am-menu-preview-item > span:first-child')).toHaveText('Claude 계1');
  await app.locator('[data-setting="menuBarAccountNames"]').click();
  await expect(preview.locator('.am-menu-preview-label')).toHaveText('계정 1');
  await expect(preview.getByRole('img')).toHaveAccessibleName(/Claude 계정 1 주간/);
  await app.locator('[data-settings-tab="General"]').click();
  await app.locator('[data-picker="language"]').click();
  await app.locator('[data-pick="language"][data-value="日本語"]').click();
  await app.locator('[data-settings-tab="Display"]').click();
  await expect(preview.locator('.am-menu-preview-label')).toHaveText('アカウント1');
  await expect(preview.getByRole('img')).toHaveAccessibleName(/Claude アカウント1 週間/);
  await app.locator('[data-setting="menuBarAccountNames"]').click();
  await expect(preview.locator('.am-menu-preview-item > span:first-child')).toHaveText('Claude ア');
});


test('preview account names keep a joined emoji intact when split in the middle', async ({ page }) => {
  const name = 'A👩‍💻';
  await page.addInitScript((name) => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { menuBarItems: 'Pinned Only', menuBarAccountNames: true },
    activeAccounts: {}, enabledProviders: ['codex'], pinnedMetrics: ['codex.session@account-1'],
    accountNames: { 'codex:account-1': name },
  })), name);
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  const item = app.getByRole('img', { name: `Codex ${name} Session 28%`, exact: true });
  const label = item.locator('.am-menu-preview-label');
  await expect(label).toHaveText(name);
  const visibleParts = await label.evaluate((element) => {
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    const parts: string[] = [];
    for (let node = walker.nextNode(); node; node = walker.nextNode()) parts.push(node.textContent ?? '');
    return parts;
  });
  expect(visibleParts).toEqual(expect.arrayContaining([expect.stringContaining('👩‍💻')]));
});


test('preview follow-up preserves Priority and Bars units while keeping percentage fills', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { defaultTab: 'Priority', menuBarItems: 'Pinned Only', iconStyle: 'Bars' },
    activeAccounts: {}, enabledProviders: ['kiro', 'opencode'], pinnedMetrics: ['kiro.credits', 'opencode.monthly'],
  })));
  await openHome(page);
  const app = page.locator('[data-mock]');
  const kiro = app.locator('[data-priority-key="kiro.credits@default"]');
  const openCode = app.locator('[data-priority-key="opencode.monthly@default"]');
  const amount = (row: typeof kiro) => row.locator('[data-toggle-meter] > :visible');
  const ring = (row: typeof kiro) => row.locator('.am-ring-progress');
  await expect.soft(amount(kiro)).toHaveText('23 used', { timeout: 1000 });
  await expect.soft(amount(openCode)).toHaveText('$24.00 used', { timeout: 1000 });
  await expect(ring(kiro)).toHaveAttribute('stroke-dasharray', '46 100');
  await expect(ring(openCode)).toHaveAttribute('stroke-dasharray', '40 100');
  await kiro.locator('[data-toggle-meter]').click();
  await expect.soft(amount(kiro)).toHaveText('27 left', { timeout: 1000 });
  await expect.soft(amount(openCode)).toHaveText('$36.00 left', { timeout: 1000 });
  await expect(ring(kiro)).toHaveAttribute('stroke-dasharray', '54 100');
  await expect(ring(openCode)).toHaveAttribute('stroke-dasharray', '60 100');
  await openSettings(page);
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  const bars = app.getByRole('region', { name: 'Menu Bar Preview', exact: true }).locator('.am-menu-preview-bar');
  const kiroBar = bars.and(app.locator('[aria-label^="Kiro "]'));
  const openCodeBar = bars.and(app.locator('[aria-label^="OpenCode "]'));
  await expect.soft(kiroBar).toHaveAccessibleName('Kiro Credits 27', { timeout: 1000 });
  await expect.soft(openCodeBar).toHaveAccessibleName('OpenCode Monthly $36', { timeout: 1000 });
  expect(await kiroBar.evaluate((element) => getComputedStyle(element).getPropertyValue('--bar-fill'))).toBe('54%');
  expect(await openCodeBar.evaluate((element) => getComputedStyle(element).getPropertyValue('--bar-fill'))).toBe('60%');
  await chooseSetting(page, 'Show Usage As', 'Used');
  await expect.soft(kiroBar).toHaveAccessibleName('Kiro Credits 23', { timeout: 1000 });
  await expect.soft(openCodeBar).toHaveAccessibleName('OpenCode Monthly $24', { timeout: 1000 });
  expect(await kiroBar.evaluate((element) => getComputedStyle(element).getPropertyValue('--bar-fill'))).toBe('46%');
  expect(await openCodeBar.evaluate((element) => getComputedStyle(element).getPropertyValue('--bar-fill'))).toBe('40%');
});

test('preview follow-up preserves the visible space between short account name words', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { menuBarItems: 'Pinned Only', menuBarAccountNames: true },
    activeAccounts: {}, enabledProviders: ['codex'], pinnedMetrics: ['codex.session@account-1'],
    accountNames: { 'codex:account-1': 'Work Team' },
  })));
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  const label = app.getByRole('img', { name: 'Codex Work Team Session 28%', exact: true }).locator('.am-menu-preview-label');
  await expect(label).toHaveText('Work Team');
  const { actual, reference } = await label.evaluate((element) => {
    function gap(scope: Element) {
      const positions = new Map<string, DOMRect>();
      const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        for (const letter of ['k', 'T']) {
          const offset = node.textContent?.indexOf(letter) ?? -1;
          if (offset < 0) continue;
          const range = document.createRange();
          range.setStart(node, offset);
          range.setEnd(node, offset + 1);
          positions.set(letter, range.getBoundingClientRect());
        }
      }
      return positions.get('T')!.left - positions.get('k')!.right;
    }
    const sample = element.cloneNode(false);
    if (!(sample instanceof Element)) throw new Error('Expected a reference label');
    sample.textContent = 'Work Team';
    element.after(sample);
    try {
      return { actual: gap(element), reference: gap(sample) };
    } finally {
      sample.remove();
    }
  });
  expect(reference).toBeGreaterThan(0);
  expect(actual).toBeGreaterThan(0);
  expect(Math.abs(actual - reference)).toBeLessThanOrEqual(1);
});

test('preview follow-up keeps a joined emoji in a multi-account initial badge', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { menuBarItems: 'Pinned Only', menuBarAccountNames: false },
    activeAccounts: {}, enabledProviders: ['codex'], pinnedMetrics: ['codex.session@account-1'],
    accountNames: { 'codex:account-1': '👩‍💻 Team' },
  })));
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  const item = app.getByRole('img', { name: 'Codex 👩‍💻 Team Session 28%', exact: true });
  await expect(item).toContainText('Codex 👩‍💻T');
});
