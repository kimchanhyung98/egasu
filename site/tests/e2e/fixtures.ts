import { settingGroups } from '../../src/data/settings';
import { test as base, expect, type Page } from '@playwright/test';

export const downloadURL = 'https://github.com/kimchanhyung98/egasu/releases/download/v0.99.2/egasu.dmg';
export const stableFeed = `<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
  <sparkle:version>992</sparkle:version><sparkle:shortVersionString>0.99.2</sparkle:shortVersionString>
  <pubDate>Fri, 11 Sep 2026 00:00:00 GMT</pubDate>
  <enclosure url="${downloadURL}" length="10485760" type="application/octet-stream"/>
</item></channel></rss>`;

export const test = base.extend<{ runtimeErrors: string[]; expectXMLParserCsp: boolean }>({
  expectXMLParserCsp: [false, { option: true }],
  runtimeErrors: [async ({ page, browserName, expectXMLParserCsp }, use) => {
    const errors: string[] = [];
    const cspErrors: string[] = [];
    page.on('pageerror', (error) => errors.push(error.message));
    page.on('console', (message) => {
      if (message.type() === 'error' && /content security policy|refused to|violat.*directive/i.test(message.text())) cspErrors.push(message.text());
    });
    await page.route('**/appcast.xml', (route) => route.fulfill({ contentType: 'application/xml', body: stableFeed }));
    await use(errors);
    expect(errors, 'No runtime errors').toEqual([]);
    // 이전 Chromium은 잘못된 XML에 고정 스타일 두 개를 보고하고, 새 버전은 진단 없이 처리.
    const parserHashes = expectXMLParserCsp && browserName === 'chromium'
      ? ['ICa0DhwZQJsOd/Rn0N8H6FdQ71GfNL+op2zhAQ+Y4mM=', 'ZD0chCyBaNHl+4UwQHJIHGoYhKwMeyCXGgJTKW5/67E='] : [];
    const webkitParserStyle = "Refused to apply a stylesheet because its hash, its nonce, or 'unsafe-inline' does not appear in the style-src directive of the Content Security Policy.";
    const unexpected = cspErrors.filter(message =>
      !(expectXMLParserCsp && browserName === 'webkit' && message === webkitParserStyle)
      && !parserHashes.some(hash => message.includes(`sha256-${hash}`)));
    expect(cspErrors.length).toBeLessThanOrEqual(2);
    expect(unexpected, 'Only explicitly expected XML parser diagnostics').toEqual([]);
  }, { auto: true }],
});

export { expect };

export async function openHome(page: Page): Promise<void> {
  await page.goto('/');
  await expect(page.locator('html')).toHaveAttribute('data-ready', '1');
  await expect(page.locator('html')).toHaveAttribute('data-scroll-ready', 'true');
  // 준비 속성 이후에도 폰트 배치와 WebKit의 초기 스크롤 보정이 이어질 수 있음.
  await page.evaluate(async () => {
    await document.fonts.ready;
    window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
  });
  await expect.poll(() => page.evaluate(() => scrollY), 'Home starts at the top').toBe(0);
  await page.evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
}

export async function openSettings(page: Page): Promise<void> {
  const app = page.locator('[data-mock]');
  await app.getByRole('button', { name: 'Options', exact: true }).click();
  await app.getByRole('menuitem', { name: 'Settings', exact: true }).click();
  await expect(app).toHaveAttribute('data-screen', 'settings');
}

export async function enableLabs(page: Page): Promise<void> {
  const app = page.locator('[data-mock]');
  await app.getByRole('tab', { name: 'General', exact: true }).click();
  const beta = app.getByRole('switch', { name: 'Beta Updates', exact: true });
  if (await beta.getAttribute('aria-checked') !== 'true') await beta.click();
  await app.getByRole('tab', { name: 'Labs', exact: true }).click();
}

export async function chooseSetting(page: Page, label: string, value: string): Promise<void> {
  const app = page.locator('[data-mock]');
  const group = settingGroups.find((group) => group.rows.some((row) => row.label === label));
  if (group) await app.locator(`button[data-settings-tab="${group.tab}"]`).click();
  const id = group!.rows.find((row) => row.label === label)!.id;
  const picker = app.locator(`[data-picker="${id}"]`);
  await picker.click();
  await app.locator(`[data-pick="${id}"][data-value="${value}"]`).click();
  await expect(picker).toBeFocused();
}

export async function allUsage(page: Page): Promise<void> {
  await expect(page.locator('html')).toHaveAttribute('data-ready', '1');
  const mock = page.locator('[data-mock]');
  const tab = mock.locator('button[data-dashboard-tab="All Usage"][role="tab"]');
  if (await tab.getAttribute('aria-selected') !== 'true') await tab.click();
  await expect(mock.locator('[data-dashboard-panel="All Usage"]')).toBeVisible();
}

export async function openAccounts(page: Page): Promise<void> {
  const app = page.locator('[data-mock]');
  await app.locator('[data-options]').click();
  await app.getByRole('menuitem', { name: 'Accounts', exact: true }).click();
}

export async function accountDetail(page: Page, provider: string, account = 'account-1'): Promise<void> {
  await openAccounts(page);
  await page.locator(`[data-mock] [data-account-list] .am-open[data-go="account:${provider}:${account}"]`).click();
}
