import { test, expect, openHome, openSettings, chooseSetting, allUsage, accountDetail, openAccounts } from './fixtures';

test('account metrics hide independently and pin once in Priority', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await accountDetail(page, 'claude');
  const detail = app.locator('[data-scr="account:claude:account-1"]');
  await detail.locator('[data-pin="claude.weekly"]').click();
  await detail.locator('[data-metric-toggle="claude.session"]').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  const pinned = app.locator('[data-priority-group="pinned"]');
  await expect(pinned.locator('[data-line-id="claude.weekly"]')).toHaveCount(1);
  await expect(pinned.locator('[data-priority-key="claude.weekly@account-1"]')).toBeVisible();
  await expect(app.locator('[data-priority-group="runningOut"] [data-priority-key="claude.weekly@account-1"]')).toHaveCount(0);
  await allUsage(page);
  await expect(app.locator('[data-card="claude-account-1"] [data-row="claude.session"]')).toBeHidden();
  await expect(app.locator('[data-card="claude-account-2"] [data-row="claude.session"]')).toBeVisible();
  await accountDetail(page, 'claude');
  await detail.locator('[data-metric-toggle="claude.session"]').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await expect(app.locator('[data-card="claude-account-1"] [data-row="claude.session"]')).toBeVisible();
});

test('metric order and custom names survive reload and privacy keeps Accounts editable', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await accountDetail(page, 'claude');
  const detail = app.locator('[data-scr="account:claude:account-1"]');
  const input = detail.locator('[data-rename-input]');
  await input.fill('Today');
  await detail.locator('.am-topbar > b').click();
  const title = detail.locator('.am-topbar > b');
  const titleName = title.locator('[data-account-name="claude"][data-account-id="account-1"]');
  await expect(title).toHaveText('Claude: Today');
  await expect(titleName).toHaveText('Today');
  await detail.locator('[data-drag-metric="claude.weekly"]').dragTo(detail.locator('[data-drag-metric="claude.session"]'));
  await expect(detail.locator('[data-metric-list][data-shared="false"] > div').first()).toHaveAttribute('data-metric-setting', 'claude.weekly');
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await openSettings(page);
  await chooseSetting(page, 'Language', '한국어');
  await app.locator('button[data-settings-tab="Advanced"]').click();
  await app.locator('[data-setting="privacyMode"]').click();
  await page.reload();
  await allUsage(page);
  const name = app.locator('[data-card="claude-account-1"] [data-account-name]');
  await expect(name).toHaveText('••••@example.com');
  await expect(name).toHaveAccessibleName('••••@example.com');
  await app.locator('[data-options]').click();
  await app.locator('.am-optmenu [data-go="accounts"]').click();
  const accountRow = app.locator('[data-account-list-row][data-provider="claude"][data-account-id="account-1"]');
  await expect(accountRow.locator('.am-open')).toHaveAccessibleName('Claude Today 열기');
  await expect(accountRow.locator('[data-drag-account]')).toHaveAccessibleName('Claude Today 순서 변경');
  await accountRow.locator('.am-open').click();
  await expect(input).toHaveValue('Today');
  await expect(title).toHaveText('Claude: Today');
  await expect(titleName).toHaveText('Today');
  await expect(input).toBeEditable();
  await expect(detail.locator('[data-metric-list][data-shared="false"] > div').first()).toHaveAttribute('data-metric-setting', 'claude.weekly');
});

test('a saved literal name stays distinct from a localized default after switching languages', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  const back = app.locator('.am-scr:not([hidden]) .am-back');
  await accountDetail(page, 'claude');
  const detail = app.locator('[data-scr="account:claude:account-1"]');
  await detail.locator('[data-rename-input]').fill('계정 2');
  await detail.locator('.am-topbar > b').click();
  await back.click();
  await back.click();
  await openSettings(page);
  await chooseSetting(page, 'Language', '한국어');
  await back.click();

  const verifyAccountNames = async (): Promise<void> => {
    await app.locator('[data-options]').click();
    await app.locator('.am-optmenu [data-go="accounts"]').click();
    const account = (id: string) => app.locator(`[data-account-list-row][data-provider="claude"][data-account-id="${id}"]`);
    await expect(account('account-1').locator('[data-account-name]')).toHaveText('계정 2');
    await expect(account('account-1').locator('.am-open')).toHaveAccessibleName('Claude 계정 2 열기');
    await expect(account('account-2').locator('[data-account-name]')).toHaveText('Account 2');
    await expect(account('account-2').locator('.am-open')).toHaveAccessibleName('Claude Account 2 열기');
  };
  await verifyAccountNames();
  await page.reload();
  await verifyAccountNames();
});

test('swapped account names and display settings survive reload', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await chooseSetting(page, 'Theme', 'Dark');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await accountDetail(page, 'claude');
  const firstDetail = app.locator('[data-scr="account:claude:account-1"]');
  const firstName = firstDetail.getByRole('textbox', { name: 'Name', exact: true });
  await firstName.fill(' account 2 ');
  await firstDetail.locator('.am-topbar > b').click();
  await expect(firstDetail.locator('[data-rename-error]')).toBeVisible();
  await expect(firstDetail.locator('.am-topbar > b')).toHaveText('Claude: Account 1');
  await firstName.focus();
  await expect(firstName).toHaveAttribute('aria-invalid', 'true');
  await expect(firstName).toHaveAccessibleDescription('This account name is already in use.');
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  for (const [id, name] of [['account-1', 'Temporary'], ['account-2', 'Account 1'], ['account-1', 'Account 2']]) {
    await accountDetail(page, 'claude', id);
    const detail = app.locator(`[data-scr="account:claude:${id}"]`);
    const input = detail.getByRole('textbox', { name: 'Name', exact: true });
    await input.fill(name);
    await detail.locator('.am-topbar > b').click();
    await expect(detail.locator('[data-rename-error]')).toBeHidden();
    await expect(input).not.toHaveAttribute('aria-invalid', 'true');
    await expect(input).toHaveAccessibleDescription('');
    await app.locator('.am-scr:not([hidden]) .am-back').click();
    await app.locator('.am-scr:not([hidden]) .am-back').click();
  }
  await page.reload();
  await allUsage(page);
  await expect(app).toHaveAttribute('data-theme', 'dark');
  await expect(app.locator('[data-card="claude-account-1"] [data-account-name]')).toHaveText('Account 2');
  await expect(app.locator('[data-card="claude-account-2"] [data-account-name]')).toHaveText('Account 1');
});

test('Accounts can add and remove a dormant provider while All Usage omits unreported limits', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const cursor = app.locator('[data-family="cursor"]');
  await expect(cursor).toBeHidden();
  await openAccounts(page);
  await app.locator('[data-add-account]').click();
  await app.locator('[data-add-provider="cursor"]').click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(cursor).toBeVisible();
  await expect(cursor.locator('[data-family-notice]')).toBeVisible();
  await expect(cursor.locator('[data-metric="cursor.credits"]')).toBeHidden();
  await expect(cursor.locator('.am-meter:visible')).toHaveCount(0);

  const notice = app.locator('[data-priority-notice="cursor"]');
  await app.getByRole('tab', { name: 'Priority', exact: true }).click();
  await notice.getByRole('button', { name: 'Fix', exact: true }).click();
  const detail = app.locator('[data-scr="account:cursor:default"]');
  await expect(detail.getByText('Sign-In Needed', { exact: true })).toBeVisible();
  await expect(detail.getByText('Add and sign in to accounts in the Mac app.', { exact: true })).toBeVisible();
  await detail.getByRole('button', { name: 'Remove From Preview', exact: true }).click();
  await expect(app).toHaveAttribute('data-screen', 'accounts');
  const cursorAccount = app.locator('[data-account-list-row][data-provider="cursor"]');
  await expect(cursorAccount).toBeHidden();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(notice).toBeHidden();

  await page.reload();
  await allUsage(page);
  await expect(cursor).toBeHidden();
  await accountDetail(page, 'claude');
  const claude = app.locator('[data-scr="account:claude:account-1"]');
  await expect(claude.getByText('Ready', { exact: true })).toBeVisible();
  await expect(claude.getByRole('button', { name: 'Remove Account…', exact: true })).toBeVisible();
  await expect(claude.locator('[data-remove-preview-provider]')).toHaveCount(0);
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await app.locator('[data-add-account]').click();
  await app.locator('[data-add-provider="cursor"]').click();
  await expect(cursorAccount).toBeVisible();
});

test('account Actions reports its menu state and preserves the active account history', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  await expect(app.locator('[data-family="antigravity"]')).toBeVisible();
  const first = app.locator('[data-card="codex-account-1"]');
  const second = app.locator('[data-card="codex-account-2"]');
  const more = second.getByRole('button', { name: 'Codex Actions', exact: true });
  const menu = second.locator('.am-account-actions');
  const history = ['codex.trend', 'codex.today', 'codex.yesterday', 'codex.last30'];
  for (const id of history) {
    await expect(first.locator(`[data-row="${id}"]`)).toBeVisible();
    await expect(second.locator(`[data-row="${id}"]`)).toBeHidden();
  }
  await expect(more).toHaveAttribute('aria-haspopup', 'menu');
  await expect(more).toHaveAttribute('aria-expanded', 'false');
  await expect(more).toHaveAttribute('aria-controls', (await menu.getAttribute('id'))!);
  await more.click();
  await expect(menu).toBeVisible();
  await expect(more).toHaveAttribute('aria-expanded', 'true');
  await page.keyboard.press('Escape');
  await expect(menu).toBeHidden();
  await expect(more).toHaveAttribute('aria-expanded', 'false');
  await expect(more).toBeFocused();
  await second.locator('.am-account-caption').press('Shift+F10');
  await expect(more).toHaveAttribute('aria-expanded', 'true');
  await menu.getByRole('menuitem', { name: 'Use Codex: Account 2', exact: true }).click();
  await app.getByRole('dialog').getByRole('button', { name: 'Switch Account', exact: true }).click();
  for (const id of history) {
    await expect(first.locator(`[data-row="${id}"]`)).toBeHidden();
    await expect(second.locator(`[data-row="${id}"]`)).toBeVisible();
  }
});

test('inline rename ignores composition keys and preserves focus when committing with Tab', async ({ page }) => {
  await page.addInitScript(() => {
    const key = 'openusage.site.preview.v1';
    if (!localStorage.getItem(key)) localStorage.setItem(key, JSON.stringify({
      preferences: { language: '日本語' }, activeAccounts: {},
    }));
  });
  await openHome(page);
  await allUsage(page);
  const card = page.locator('[data-mock] [data-card="claude-account-1"]');
  const more = card.locator('[data-open-account-menu]');
  const name = card.locator('[data-toggle-account-name]');
  const input = card.getByRole('textbox', { name: 'アカウント名' });
  const edit = async (): Promise<void> => {
    await more.press('Enter');
    await card.locator('[data-rename-account]').press('Enter');
    await expect(input).toBeFocused();
  };

  await edit();
  await input.fill('仕事');
  for (const key of ['Enter', 'Escape']) {
    await input.dispatchEvent('keydown', { key, isComposing: true });
    await expect(input).toBeFocused();
  }
  await input.press('Tab');
  await expect(input).toHaveCount(0);
  await expect(more).toBeFocused();
  await expect(name).toHaveText('仕事');

  await edit();
  await input.fill('Cancel this');
  await input.press('Escape');
  await expect(name).toBeFocused();
  await expect(name).toHaveText('仕事');

  await edit();
  await input.fill('チーム');
  await input.press('Enter');
  await expect(name).toBeFocused();
  await expect(name).toHaveText('チーム');

  await page.reload();
  await allUsage(page);
  await expect(name).toHaveText('チーム');
});

test('keyboard reorder moves providers, accounts and metrics within their sections and saves the order', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const families = app.locator('[data-dashboard-panel="All Usage"] [data-family]:visible');
  const claudeProvider = app.locator('[data-drag-provider="claude"]');
  await expect(families.first()).toHaveAttribute('data-family', 'claude');
  await expect(claudeProvider).toHaveAttribute('aria-keyshortcuts', 'ArrowUp ArrowDown');
  await claudeProvider.press('ArrowDown');
  await expect(families.nth(0)).toHaveAttribute('data-family', 'codex');
  await expect(families.nth(1)).toHaveAttribute('data-family', 'claude');
  await expect(claudeProvider).toBeFocused();

  await openAccounts(page);
  const claudeAccounts = app.locator('[data-account-list-row][data-provider="claude"]');
  const secondAccount = app.locator('[data-drag-account="claude:account-2"]');
  await expect(claudeAccounts.first()).toHaveAttribute('data-account-id', 'account-1');
  await secondAccount.press('ArrowDown');
  await expect(claudeAccounts.first()).toHaveAttribute('data-account-id', 'account-1');
  await expect(secondAccount).toBeFocused();
  await secondAccount.press('ArrowUp');
  await expect(claudeAccounts.first()).toHaveAttribute('data-account-id', 'account-2');
  await expect(secondAccount).toBeFocused();

  await app.locator('[data-scr="accounts"] .am-back').click();
  await accountDetail(page, 'claude', 'account-1');
  const detail = app.locator('[data-scr="account:claude:account-1"]');
  const accountMetrics = detail.locator('[data-metric-list][data-shared="false"] > div');
  const weekly = detail.locator('[data-drag-metric="claude.weekly"]');
  await expect(accountMetrics.first()).toHaveAttribute('data-metric-setting', 'claude.session');
  await weekly.press('ArrowUp');
  await expect(accountMetrics.first()).toHaveAttribute('data-metric-setting', 'claude.weekly');
  await expect(weekly).toBeFocused();

  await page.reload();
  await allUsage(page);
  await expect(families.nth(0)).toHaveAttribute('data-family', 'codex');
  await expect(families.nth(1)).toHaveAttribute('data-family', 'claude');
  const cards = app.locator('[data-family="claude"] [data-card]:visible');
  await expect(cards.first()).toHaveAttribute('data-card', 'claude-account-2');
  await expect(cards.last()).toHaveAttribute('data-card', 'claude-account-1');
  const firstAccountRows = cards.last().locator('[data-row]:visible');
  await expect(firstAccountRows.first()).toHaveAttribute('data-row', 'claude.weekly');
  await expect(firstAccountRows.nth(1)).toHaveAttribute('data-row', 'claude.session');
});

test('Privacy Mode masks dashboard names, emails, and accessible captions while Accounts keeps the name', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  const back = app.locator('.am-scr:not([hidden]) .am-back');
  await accountDetail(page, 'claude');
  const detail = app.locator('[data-scr="account:claude:account-1"]');
  const input = detail.locator('[data-rename-input]');
  const alias = 'Review Account';
  const email = 'claude.account-1@example.com';
  const masked = '••••@example.com';
  await input.fill(alias);
  await input.press('Enter');
  await back.click();
  await back.click();
  await allUsage(page);

  const allUsageCaption = app.locator('[data-card="claude-account-1"] .am-account-caption');
  const allUsageName = allUsageCaption.locator('[data-account-name]');
  const priorityName = app.locator('[data-priority-key="claude.weekly@account-1"] [data-account-name]');
  await expect(allUsageCaption).toHaveAccessibleName(`Claude ${alias}`);
  await expect(allUsageName).toHaveAccessibleName(alias);
  await allUsageName.click();
  await expect(allUsageCaption).toHaveAccessibleName(`Claude ${email}`);
  await expect(allUsageName).toHaveAccessibleName(email);
  await app.getByRole('tab', { name: 'Priority', exact: true }).click();
  await expect(priorityName).toHaveAccessibleName(email);

  await openSettings(page);
  await app.locator('button[data-settings-tab="Advanced"]').click();
  await app.locator('[data-setting="privacyMode"]').click();
  await back.click();
  await expect(priorityName).toHaveText(masked);
  await expect(priorityName).toHaveAccessibleName(masked);
  await allUsage(page);
  await expect(allUsageName).toHaveText(masked);
  await expect(allUsageName).toHaveAccessibleName(masked);
  await expect(allUsageCaption).toHaveAccessibleName(`Claude ${masked}`);
  await allUsageName.click();
  await expect(allUsageName).toHaveAccessibleName(masked);
  await app.getByRole('tab', { name: 'Priority', exact: true }).click();
  await expect(priorityName).toHaveAccessibleName(masked);
  await expect(app.locator('[data-scr="dashboard"]')).not.toContainText(alias);
  await expect(app.locator('[data-scr="dashboard"]')).not.toContainText(email);

  await accountDetail(page, 'claude');
  await expect(input).toHaveValue(alias);
  await expect(detail.locator('.am-topbar > b')).toHaveText(`Claude: ${alias}`);
});

test('metric drag only accepts targets in the same visible list', async ({ page }) => {
  await openHome(page);
  await accountDetail(page, 'claude');
  const detail = page.locator('[data-mock] [data-scr="account:claude:account-1"]');
  const session = detail.locator('[data-drag-metric="claude.session"]');
  const weekly = detail.locator('[data-drag-metric="claude.weekly"]');
  const yesterday = detail.locator('[data-drag-metric="claude.yesterday"]');
  const today = detail.locator('[data-drag-metric="claude.today"]');
  const privateRows = detail.locator('[data-metric-list][data-shared="false"] > [data-metric-setting]');
  const sharedRows = detail.locator('[data-metric-list][data-shared="true"] > [data-metric-setting]');
  const storedOrder = () => page.evaluate(() => JSON.parse(localStorage.getItem('openusage.site.preview.v1') ?? '{}').metricOrder ?? {});
  const before = await storedOrder();
  await session.dragTo(yesterday);
  expect(await storedOrder()).toEqual(before);
  await expect(privateRows.first()).toHaveAttribute('data-metric-setting', 'claude.session');

  await weekly.dragTo(session);
  await expect(privateRows.first()).toHaveAttribute('data-metric-setting', 'claude.weekly');
  await yesterday.dragTo(today);
  const shared = await sharedRows.evaluateAll((rows) => rows.map((row) => row.getAttribute('data-metric-setting')));
  expect(shared.filter((metric) => metric === 'claude.yesterday' || metric === 'claude.today'))
    .toEqual(['claude.yesterday', 'claude.today']);
});
