import { test, expect, openHome, openSettings, chooseSetting, allUsage, accountDetail } from './fixtures';

test('Settings information is named and opens while the info button has focus', async ({ page }) => {
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  const info = app.getByRole('button', { name: 'Open egasu from anywhere', exact: true });
  const tooltip = info.locator('[role="tooltip"]');
  await expect(info).toBeVisible();
  await expect(tooltip).toBeHidden();
  await app.getByRole('button', { name: 'Default Tab', exact: true }).focus();
  await page.keyboard.press('Tab');
  await expect(info).toBeFocused();
  await expect(tooltip).toBeVisible();
  await expect(tooltip).toHaveText('Open egasu from anywhere');
  await page.keyboard.press('Escape');
  await expect(tooltip).toBeHidden();
  await expect(info).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(info).not.toBeFocused();
  await page.keyboard.press('Shift+Tab');
  await expect(info).toBeFocused();
  await expect(tooltip).toBeVisible();
});

test('settings tooltips stay inside the popover near its left and bottom edges', async ({ page }) => {
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  await app.getByRole('tab', { name: 'Alerts', exact: true }).click();
  const body = app.locator('[data-scr="settings"] .am-body');
  for (const name of ['When a limit turns into a priority', 'Alert when Reset Watch expects Codex limits to reset soon']) {
    const info = app.getByRole('button', { name, exact: true });
    await info.focus();
    const tooltip = info.locator('[role="tooltip"]');
    await expect(tooltip).toBeVisible();
    await expect.poll(async () => {
      const bounds = (await tooltip.boundingBox())!;
      const panel = (await body.boundingBox())!;
      return {
        horizontal: bounds.x >= panel.x && bounds.x + bounds.width <= panel.x + panel.width,
        vertical: bounds.y >= panel.y && bounds.y + bounds.height <= panel.y + panel.height,
      };
    }, name).toEqual({ horizontal: true, vertical: true });
  }
});

test('Reset Watch keeps probability and votes when usage flips, and shares time preferences', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const codex = app.locator('[data-card="codex-account-1"]');
  const forecast = codex.locator('[data-metric="codex.resetWatch"]');
  await expect(forecast).toContainText('65% chance');
  await expect(forecast).toContainText('72% expect a reset');
  await codex.locator('[data-toggle-meter]').first().click();
  await expect(app).toHaveAttribute('data-mode', 'left');
  await expect(forecast).toContainText('65% chance');
  await expect(forecast.locator('.am-meter i')).toHaveClass('am-w65 is-warning');
  await expect(forecast.locator('.am-meter b')).toHaveClass('am-t72');
  await forecast.locator('[data-toggle-reset]').click();
  await expect(forecast.locator('.rel')).toBeVisible();
  await expect(forecast.locator('.rel')).toHaveText('Within 18h 30m');
  await expect(codex.locator('[data-metric="codex.weekly"] .rel')).toBeVisible();
  await openSettings(page);
  await chooseSetting(page, 'Time Format', '12-hour');
  await chooseSetting(page, 'Reset Times', 'Exact Time');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(forecast.locator('.abs')).toHaveText('By Oct 27 at 10:00 AM');
  await expect(forecast.locator('.abs')).toBeVisible();
});

test('Soft Limit validates percentages, mirrors its guide, and keeps forecast meters separate', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const weekly = app.locator('[data-card="claude-account-1"] [data-metric="claude.weekly"]');
  await expect(weekly.locator('.am-soft-marker')).toBeHidden();
  await openSettings(page);
  const threshold = app.getByRole('spinbutton', { name: 'Threshold' });
  await expect(threshold).toBeHidden();
  await app.locator('button[data-settings-tab="Advanced"]').click();
  await app.getByRole('switch', { name: 'Enable Soft Limit' }).click();
  await app.locator('[data-soft-confirm]').click();
  await threshold.fill('95');
  await app.locator('[data-settings-group="softLimit"] > b').click();
  await expect(app).toHaveAttribute('data-soft-limit', 'Weekly');
  await threshold.fill('101');
  await app.locator('[data-settings-group="softLimit"] > b').click();
  await expect(threshold).toHaveValue('95');
  await expect(app.getByRole('status')).toContainText('previous threshold is unchanged');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(weekly.locator('.am-soft-marker')).toBeVisible();
  const markerFraction = () => weekly.evaluate((element) => {
    const track = element.querySelector('.am-meter')!.getBoundingClientRect();
    const marker = element.querySelector('.am-soft-marker')!.getBoundingClientRect();
    return (marker.left - track.left) / track.width;
  });
  expect(await markerFraction()).toBeCloseTo(0.95, 2);
  await weekly.locator('[data-toggle-meter]').click();
  expect(await markerFraction()).toBeCloseTo(0.05, 2);
  await openSettings(page);
  await chooseSetting(page, 'Window', '5 Hours');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(weekly.locator('.am-soft-marker')).toBeHidden();
  await expect(app.locator('[data-card="claude-account-1"] [data-metric="claude.session"] .am-soft-marker')).toBeVisible();
  await expect(app.locator('.am-forecast .am-soft-marker')).toHaveCount(0);
  await page.reload();
  await expect(app).toHaveAttribute('data-soft-limit', '5 Hours');
  await openSettings(page);
  await app.locator('button[data-settings-tab="Advanced"]').click();
  await expect(threshold).toHaveValue('95');
});

test('Reset Watch notifications can be enabled without quota notifications', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  await app.locator('button[data-settings-tab="Alerts"]').click();
  const setting = app.getByRole('switch', { name: 'Codex Reset Watch', exact: true });
  await expect(setting).toHaveAttribute('aria-checked', 'false');
  await setting.click();
  await expect(app.getByRole('button', { name: 'Allow Notifications', exact: true })).toBeVisible();
  for (const name of ['Warning, Receive Alerts', 'Critical, Receive Alerts', 'Burning Fast, Receive Alerts', 'Use It or Lose It, Receive Alerts']) {
    await expect(app.getByRole('switch', { name, exact: true })).toHaveAttribute('aria-checked', 'false');
  }
  await page.reload();
  await openSettings(page);
  await app.locator('button[data-settings-tab="Alerts"]').click();
  await expect(setting).toHaveAttribute('aria-checked', 'true');
});

test('unused allowance reminders preserve their choice without enabling other alerts', async ({ page }) => {
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  const tab = app.getByRole('tab', { name: 'Alerts', exact: true });
  await tab.click();
  const setting = app.getByRole('switch', { name: 'Use It or Lose It, Receive Alerts', exact: true });
  await expect(setting).toHaveAttribute('aria-checked', 'false');
  await setting.click();
  await expect(app.getByRole('button', { name: 'Allow Notifications', exact: true })).toBeVisible();
  for (const name of ['Critical, Receive Alerts', 'Warning, Receive Alerts', 'Burning Fast, Receive Alerts', 'Codex Reset Watch']) {
    await expect(app.getByRole('switch', { name, exact: true })).toHaveAttribute('aria-checked', 'false');
  }
  await page.reload();
  await openSettings(page);
  await tab.click();
  await expect(setting).toHaveAttribute('aria-checked', 'true');
});

test('dashboard context menu confirms the selected account before switching', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const card = app.locator('[data-card="claude-account-2"]');
  await card.locator('[data-account-actions-trigger]').click({ button: 'right' });
  const action = card.getByRole('menuitem', { name: 'Use Claude: Account 2', exact: true });
  await expect(action).toBeEnabled();
  await action.click();
  const dialog = app.getByRole('dialog', { name: 'Switch Account?' });
  await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(card).toHaveAttribute('data-inactive-account', 'true');
  await card.locator('[data-account-actions-trigger]').press('Shift+F10');
  await expect(action).toBeFocused();
  await action.press('Enter');
  await dialog.getByRole('button', { name: 'Switch Account', exact: true }).click();
  await expect(card).toHaveAttribute('data-inactive-account', 'false');
  await card.locator('[data-account-actions-trigger]').press('Shift+F10');
  await expect(action).toBeDisabled();
  await expect(card.getByRole('menuitem', { name: 'Refresh', exact: true })).toBeFocused();
});

test('text-only account cards open context menus and restore focus to their headers', async ({ page }) => {
  await openHome(page);
  await accountDetail(page, 'codex');
  const app = page.locator('[data-mock]');
  const detail = app.locator('[data-scr="account:codex:account-1"]');
  for (const toggle of await detail.locator('[data-metric-toggle]').all()) {
    if (await toggle.getAttribute('data-metric-toggle') !== 'codex.today') await toggle.click();
  }
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await allUsage(page);
  const first = app.locator('[data-card="codex-account-1"]');
  const header = first.locator('[data-account-actions-trigger]');
  const rows = first.locator('[data-row]:visible');
  await expect(rows).toHaveCount(1);
  await expect(rows).toHaveAttribute('data-row', 'codex.today');
  await header.click({ button: 'right' });
  const refresh = first.getByRole('menuitem', { name: 'Refresh', exact: true });
  await expect(refresh).toBeFocused();
  await header.click();
  await expect(refresh).toBeHidden();
  await expect(header).toBeFocused();
  await header.press('Shift+F10');
  await expect(refresh).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(refresh).toBeHidden();
  await expect(header).toBeFocused();
});

test('Codex limits stay per account while Reset Watch follows the active account once', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const first = app.locator('[data-card="codex-account-1"]');
  const second = app.locator('[data-card="codex-account-2"]');
  await expect(first.locator('.am-forecast')).toBeVisible();
  await expect(second.locator('.am-forecast')).toBeHidden();
  await expect(first.locator('[data-metric="codex.session"]')).toContainText('28%');
  await expect(second.locator('[data-metric="codex.session"]')).toContainText('42%');
  await second.locator('[data-account-actions-trigger]').click({ button: 'right' });
  await second.getByRole('menuitem', { name: 'Use Codex: Account 2', exact: true }).click();
  await app.locator('[data-account-confirm]').click();
  await expect(first.locator('.am-forecast')).toBeHidden();
  await expect(second.locator('.am-forecast')).toBeVisible();
  await page.reload();
  await allUsage(page);
  await expect(first).toBeVisible();
  await expect(second).toHaveAttribute('data-inactive-account', 'false');
  await expect(second.locator('.am-forecast')).toBeVisible();
});

test('new feature tours show forecasts, credit count, and guides without leaking stage state', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const tour = page.locator('[data-feature-tour]');
  await tour.evaluate((element) => element.scrollIntoView({ block: 'start', behavior: 'instant' }));
  await tour.locator('[data-tour-tab="reset-watch"]').click();
  const forecast = tour.locator('[data-metric="codex.resetWatch"]');
  await expect(forecast).toBeInViewport();
  await expect(tour.locator('.am-reset-trigger')).toBeInViewport();
  await expect(tour.locator('.am-reset-detail')).toBeHidden();
  await expect(tour.locator('[data-tour-description="reset-watch"]')).toContainText('비공식 공개 예측');
  await tour.locator('[data-tour-tab="soft-limit"]').click();
  await expect(tour.locator('[data-metric="codex.weekly"] .am-soft-marker')).toBeVisible();
  await expect(tour.locator('[data-tour-description="soft-limit"]')).toContainText('현재 자동 작업 취소는 지원하지 않음');
  await tour.locator('[data-tour-tab="dashboard"]').click();
  await expect(tour.locator('[data-metric="codex.weekly"] .am-soft-marker')).toBeHidden();
  await expect(forecast).toBeHidden();
});

test('reset credit details float above the dashboard without changing card height or requesting provider data', async ({ page, isMobile }) => {
  const external: string[] = [];
  page.on('request', (request) => {
    if (!request.url().startsWith('http://127.0.0.1:')) external.push(request.url());
  });
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const card = app.locator('[data-card="codex-account-1"]');
  const trigger = card.locator('.am-reset-trigger');
  await trigger.scrollIntoViewIfNeeded();
  const height = await card.evaluate((element) => element.getBoundingClientRect().height);
  if (isMobile) await trigger.tap();
  else await trigger.click();
  const detail = card.getByRole('dialog', { name: 'Rate Limit Resets', exact: true });
  await expect(detail).toBeVisible();
  await expect(detail).toBeFocused();
  await expect(detail.locator('.am-reset-countdown')).toHaveText(['4d 19h', '11d 19h']);
  await expect(detail.getByRole('button')).toHaveCount(0);
  expect(await card.evaluate((element) => element.getBoundingClientRect().height)).toBeCloseTo(height, 1);
  const bounds = await detail.boundingBox();
  expect(bounds!.x).toBeGreaterThanOrEqual(8);
  expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(page.viewportSize()!.width - 8);
  await trigger.click();
  await expect(detail).toBeHidden();
  await trigger.press('Enter');
  await expect(detail).toBeVisible();
  await expect(detail).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(detail).toBeHidden();
  await expect(trigger).toBeFocused();
  await trigger.click();
  await expect(detail).toBeVisible();
  await app.getByRole('button', { name: 'Next update in 4m', exact: true }).click();
  await expect(detail).toBeHidden();
  await expect(app.getByRole('status')).toContainText('sample data');
  expect(external).toEqual([]);
});

test('reset credit hover opens only from the count and remains open while moving into the detail', async ({ page, isMobile }) => {
  test.skip(isMobile, 'Touch uses the tested tap path');
  await openHome(page);
  await allUsage(page);
  const card = page.locator('[data-mock] [data-card="codex-account-1"]');
  const row = card.locator('.am-resets');
  const detail = row.locator('.am-reset-detail');
  await row.locator('> b').hover();
  await expect(detail).toBeHidden();
  await row.locator('.am-reset-trigger').hover();
  await expect(detail).toBeVisible();
  await detail.hover();
  await expect(detail).toBeVisible();
  await card.locator('[data-account-actions-trigger]').hover();
  await expect(detail).toBeHidden();
});
