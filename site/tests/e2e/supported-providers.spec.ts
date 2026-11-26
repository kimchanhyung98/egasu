import { test, expect, openHome, openAccounts } from './fixtures';

const services = [
  { id: 'deepseek', name: 'DeepSeek', metrics: ['Balance (USD)', 'Balance (CNY)', 'API Access'] },
  { id: 'openai-api', name: 'OpenAI API', metrics: ['Last 30 Days', 'Billing Scope', 'Credit Balance', 'Last Updated'] },
];

for (const { id, name, metrics } of services) {
  test(`${name} appears on the home page and can be added without connecting an account`, async ({ page }) => {
    await openHome(page);
    const supportedList = page.getByRole('list', { name: '지원 AI 서비스' });
    const service = supportedList.getByRole('listitem').filter({ hasText: name });
    await expect(service).toHaveText(name);
    const count = await supportedList.getByRole('listitem').count();
    await expect(page.locator('meta[name="description"]')).toHaveAttribute('content', new RegExp(`^${count}개`));
    const symbol = await service.locator('use').getAttribute('href');
    expect(symbol).toBe(`#pi-${id}`);
    await expect(page.locator(`${symbol} path`)).not.toHaveCount(0);

    await openAccounts(page);
    const app = page.locator('[data-mock]');
    await app.locator('[data-add-account]').click();
    await app.getByRole('button', { name, exact: true }).click();
    await expect(app.getByRole('status')).toHaveText('Sample provider added. Connect your account in the Mac app.');
    await app.locator(`[data-account-list-row][data-provider="${id}"] .am-open`).click();
    const detail = app.locator(`[data-account-detail="${id}"]`);
    await expect(detail.locator('[data-metric-toggle]')).toHaveCount(metrics.length);
    for (const [index, label] of metrics.entries()) {
      await expect(detail.locator('[data-metric-toggle]').nth(index)).toHaveAccessibleName(label);
    }
    await expect(detail.getByText('Add and sign in to accounts in the Mac app.')).toBeVisible();
  });
}
