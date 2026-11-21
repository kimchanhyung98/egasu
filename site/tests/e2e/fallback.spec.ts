import { test, expect } from './fixtures';

test.use({ javaScriptEnabled: false });

test('the page remains readable and downloadable with JavaScript disabled', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'AI 사용량을 한눈에 확인하세요.' })).toBeVisible();
  await expect(page.locator('.tour-fallback')).toBeVisible();
  await expect(page.locator('[data-tour-description="menu-bar"]')).toBeVisible();
  const preview = page.locator('[data-mock]');
  await expect(preview.getByRole('button', { name: 'Options', exact: true })).toBeHidden();
  const allUsage = preview.getByRole('tabpanel', { name: 'All Usage' });
  await expect(allUsage).toBeVisible();
  await expect(preview.locator('[data-dashboard-panel="Priority"]')).toBeHidden();
  const session = allUsage.locator('[data-card="claude-account-1"] [data-metric="claude.session"]');
  await expect(session).toBeVisible();
  await expect(session.locator('.am-metric-label')).toHaveText('Session');
  await expect(session.locator('.am-headline .u')).toHaveText('3%');

  const activeCodex = allUsage.locator('[data-card="codex-account-1"]');
  const inactiveCodex = allUsage.locator('[data-card="codex-account-2"]');
  for (const metric of ['codex.trend', 'codex.today', 'codex.yesterday', 'codex.last30', 'codex.resetWatch']) {
    await expect(activeCodex.locator(`[data-row="${metric}"]`)).toBeVisible();
    const inactiveRow = inactiveCodex.locator(`[data-row="${metric}"]`);
    await expect(inactiveRow).toHaveCount(1);
    await expect(inactiveRow).toBeHidden();
  }
  await expect(inactiveCodex.locator('[data-row="codex.session"]')).toBeVisible();
  await expect(page.locator('[data-tour-mock]')).toHaveAttribute('data-dashboard-tab', 'Priority');
  const downloads = page.locator('[data-download]');
  expect(await downloads.count()).toBeGreaterThan(0);
  for (const link of await downloads.all()) {
    await expect(link).toHaveAttribute('href', 'https://github.com/kimchanhyung98/egasu/releases/latest');
  }
});
