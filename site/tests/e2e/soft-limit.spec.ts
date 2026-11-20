import type { Locator } from '@playwright/test';
import { test, expect, openHome, openSettings, enableLabs, chooseSetting, allUsage, openAccounts } from './fixtures';

async function markerFraction(row: Locator): Promise<number> {
  return row.evaluate((element) => {
    const track = element.querySelector('.am-meter')!.getBoundingClientRect();
    const marker = element.querySelector('.am-soft-marker')!.getBoundingClientRect();
    return (marker.left + marker.width / 2 - track.left) / track.width;
  });
}

test('disabling beta hides Labs and clears Soft Limit consent while retaining its settings', async ({ page }) => {
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  const tabs = app.getByRole('tablist', { name: 'Settings' }).getByRole('tab');
  const labs = app.getByRole('tab', { name: 'Labs', exact: true });
  const enable = app.getByRole('switch', { name: 'Enable Soft Limit' });
  const threshold = app.getByRole('spinbutton', { name: 'Threshold' });
  await expect(tabs).toHaveCount(4);
  await expect(labs).toBeHidden();
  await tabs.first().press('End');
  await expect(app.getByRole('tab', { name: 'Advanced', exact: true })).toBeFocused();
  await enableLabs(page);
  await expect(tabs).toHaveCount(5);
  await enable.click();
  await app.locator('[data-soft-confirm]').click();
  await chooseSetting(page, 'Window', 'Monthly');
  await threshold.fill('82');
  await threshold.press('Enter');
  await expect(app).toHaveAttribute('data-soft-limit', 'Monthly');

  await app.getByRole('tab', { name: 'General' }).click();
  await app.getByRole('switch', { name: 'Beta Updates', exact: true }).click();
  await expect(tabs).toHaveCount(4);
  await expect(labs).toBeHidden();
  await expect(app).toHaveAttribute('data-soft-limit', 'off');
  await page.reload();
  await openSettings(page);
  await enableLabs(page);
  await expect(enable).toHaveAttribute('aria-checked', 'false');
  await enable.click();
  await expect(app.locator('[data-soft-limit-dialog]')).toBeVisible();
  await app.locator('[data-soft-confirm]').click();
  await expect(threshold).toHaveValue('82');
  await expect(app).toHaveAttribute('data-soft-limit', 'Monthly');
});

test('Terminal Helper stays installed across beta changes until removal is confirmed', async ({ page }) => {
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  const helper = app.locator('[data-terminal-helper]');
  const dialog = app.locator('[data-remove-helper-dialog]');
  await expect(helper).toBeHidden();
  await enableLabs(page);
  await expect(helper).toHaveText('Install…');
  await helper.click();
  await expect(helper).toHaveText('Verifying…');
  await expect(helper).toBeDisabled();
  await expect(helper).toHaveText('Uninstall');

  await app.getByRole('tab', { name: 'General' }).click();
  await app.getByRole('switch', { name: 'Beta Updates', exact: true }).click();
  await expect(helper).toBeHidden();
  await page.reload();
  await openSettings(page);
  await enableLabs(page);
  await expect(helper).toHaveText('Uninstall');
  await helper.click();
  await expect(dialog).toBeVisible();
  await dialog.locator('[data-helper-cancel]').click();
  await expect(dialog).toBeHidden();
  await expect(helper).toHaveText('Uninstall');
  await helper.click();
  await dialog.locator('[data-helper-confirm]').click();
  await expect(dialog).toBeHidden();
  await expect(helper).toHaveText('Install…');
});

test('Soft Limit confirmation preserves navigation and shows coverage by account', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await enableLabs(page);
  const quotaStatus = app.getByText('Quota Status', { exact: true });
  const copyCommand = app.getByRole('button', { name: 'Copy Command', exact: true });
  await expect(quotaStatus).toBeHidden();
  await expect(copyCommand).toBeHidden();
  await app.getByRole('switch', { name: 'Enable Soft Limit' }).click();
  await expect(app.locator('[data-soft-limit-dialog]')).toContainText('Use a copied command to check the limit before starting a new CLI session.');
  await app.locator('[data-soft-confirm]').click();
  await copyCommand.click();
  await expect(app.locator('[data-pill]')).toHaveText('Open the Mac app to use this feature.');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(app).toHaveAttribute('data-soft-limit', 'Weekly and Monthly');
  const options = app.getByRole('button', { name: 'Options', exact: true });
  await options.scrollIntoViewIfNeeded();
  expect(await options.evaluate((button) => {
    const bounds = button.getBoundingClientRect();
    return button.contains(document.elementFromPoint(bounds.left + bounds.width / 2, bounds.top + bounds.height / 2));
  }), 'The visible notice must not intercept the Options button').toBe(true);
  await options.click();
  await app.getByRole('menuitem', { name: 'Settings', exact: true }).click();
  await expect(app).toHaveAttribute('data-screen', 'settings');
  await app.getByRole('tab', { name: 'Labs', exact: true }).click();
  await quotaStatus.click();
  const coverage = app.locator('[data-soft-statuses]');
  await expect(coverage).toBeVisible();
  await expect(coverage).toContainText('Codex');
  await expect(coverage).toContainText('Account 1');
  await expect(coverage).toContainText('Account 2');
});

test('Soft Limit selects weekly and monthly subscription meters and mirrors their guides in Left mode', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  await openAccounts(page);
  await app.locator('[data-add-account]').click();
  await app.locator('[data-add-provider="opencode"]').click();
  await app.locator('[data-add-account]').click();
  await app.locator('[data-add-provider="kiro"]').click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await openSettings(page);
  await enableLabs(page);
  await app.getByRole('switch', { name: 'Enable Soft Limit' }).click();
  await app.locator('[data-soft-confirm]').click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  const fable = app.locator('[data-card="claude-account-1"] [data-metric="claude.fable"]');
  const antigravity = app.locator('[data-card="antigravity"]');
  const session = antigravity.locator('[data-metric="antigravity.claude"]');
  const weekly = antigravity.locator('[data-metric="antigravity.claudeWeekly"]');
  const monthly = app.locator('[data-metric="opencode.monthly"]');
  const credits = app.locator('[data-metric="kiro.credits"]');

  for (const row of [fable, weekly, monthly, credits]) {
    await expect(row.locator('.am-soft-marker')).toBeVisible();
    expect(await markerFraction(row)).toBeCloseTo(0.9, 2);
  }
  await expect(session.locator('.am-soft-marker')).toBeHidden();
  await fable.locator('[data-toggle-meter]').click();
  for (const row of [fable, weekly, monthly, credits]) expect(await markerFraction(row)).toBeCloseTo(0.1, 2);

  await openSettings(page);
  await chooseSetting(page, 'Window', 'Weekly');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(weekly.locator('.am-soft-marker')).toBeVisible();
  for (const row of [monthly, credits]) await expect(row.locator('.am-soft-marker')).toBeHidden();
  await openSettings(page);
  await chooseSetting(page, 'Window', 'Monthly');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  for (const row of [fable, weekly]) await expect(row.locator('.am-soft-marker')).toBeHidden();
  await expect(session.locator('.am-soft-marker')).toHaveCount(0);
  for (const row of [monthly, credits]) await expect(row.locator('.am-soft-marker')).toBeVisible();
  expect(await markerFraction(monthly)).toBeCloseTo(0.1, 2);
  await monthly.locator('[data-toggle-meter]').click();
  expect(await markerFraction(monthly)).toBeCloseTo(0.9, 2);
});

for (const [layout, threshold] of [['Minimal', '100'], ['Cards', '1']] as const) {
  test(`Soft Limit stays inside the ${layout} track at ${threshold}% in Used and Left modes`, async ({ page }) => {
    await page.addInitScript(({ layout, threshold }) => {
      localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
        preferences: { defaultTab: 'All Usage', allUsageLayout: layout, betaUpdates: true,
          softLimitEnabled: true, softLimitWindow: 'Weekly', softLimitThreshold: threshold },
        activeAccounts: {},
      }));
    }, { layout, threshold });
    await openHome(page);
    const row = page.locator('[data-mock] [data-card="codex-account-1"] [data-metric="codex.weekly"]');
    const colors: string[] = [];
    for (const mode of ['Used', 'Left']) {
      const marker = row.locator('.am-soft-marker');
      await expect(marker).toBeVisible();
      const { guide, track, color } = await marker.evaluate((el) => ({
        guide: el.getBoundingClientRect().toJSON(),
        track: el.closest('.am-meter')!.getBoundingClientRect().toJSON(),
        color: getComputedStyle(el).backgroundColor,
      }));
      colors.push(color);
      expect(guide.width).toBeGreaterThan(0);
      expect(guide.height).toBeGreaterThan(0);
      expect(guide.height).toBeLessThanOrEqual(4);
      expect(guide.width).toBeLessThanOrEqual(2);
      expect(guide.left).toBeGreaterThanOrEqual(track.left - 0.01);
      expect(guide.right).toBeLessThanOrEqual(track.right + 0.01);
      expect(guide.top).toBeGreaterThanOrEqual(track.top - 0.01);
      expect(guide.bottom).toBeLessThanOrEqual(track.bottom + 0.01);
      const fraction = mode === 'Used' ? Number(threshold) / 100 : 1 - Number(threshold) / 100;
      const center = (guide.left + guide.right) / 2 - track.left;
      expect(Math.abs(center - track.width * fraction)).toBeLessThanOrEqual(track.height / 2);
      if (mode === 'Used') await row.locator('[data-toggle-meter]').click();
    }
    expect(colors[0]).not.toBe(colors[1]);
    if (threshold === '100') {
      const emptyTrackMarker = page.locator('[data-mock] [data-card="claude-account-1"] [data-metric="claude.fable"] .am-soft-marker');
      await expect(emptyTrackMarker).toHaveCSS('background-color', colors[0]);
    }
  });
}

test('Soft Limit does not add guides to supported metrics without data or the public forecast', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await enableLabs(page);
  await app.getByRole('switch', { name: 'Enable Soft Limit' }).click();
  await app.locator('[data-soft-confirm]').click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();

  for (const [provider, metric] of [['claude', 'claude.sonnet'], ['codex', 'codex.sparkMonthly']]) {
    const row = app.locator(`[data-card="${provider}-account-1"] [data-metric="${metric}"]`);
    await expect(row).toBeHidden();
    await expect(row.locator('.am-meter, .am-soft-marker')).toHaveCount(0);
  }
  const forecast = app.locator('[data-card="codex-account-1"] .am-forecast');
  await expect(forecast).toBeVisible();
  await expect(forecast).toContainText('65% chance');
  await expect(forecast.locator('.am-soft-marker')).toHaveCount(0);
  await openSettings(page);
  await chooseSetting(page, 'Window', 'Monthly');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(forecast).toContainText('65% chance');
  await expect(forecast.locator('.am-soft-marker')).toHaveCount(0);
  await expect(app.locator('[data-metric="codex.sparkMonthly"] .am-soft-marker')).toHaveCount(0);
});
