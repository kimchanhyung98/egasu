// 랜딩 페이지 런타임. 외부 요청은 같은 출처 /appcast.xml 하나뿐.
// 실패·차단 시 정적 링크(releases/latest)와 표시 상태를 그대로 유지.
import { initPopoverNav } from './nav';
import { setPreviewPreference } from './settings';
import { initFeatureTour } from './tour';
import { initMenus, openMenu, closeMenu } from './menus';

const SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle';
const DOWNLOAD_PREFIXES = [
  'https://github.com/kimchanhyung98/egasu/releases/download/',
  'https://github.com/kimchanhyung98/openusage/releases/download/',
];

// hero 단어 리빌. 인라인 style 속성은 CSP가 막으므로 CSSOM으로 delay 변수 부여.
function initHero(): void {
  document.querySelectorAll<HTMLElement>('.hero .device').forEach((device) => {
    const mock = device.querySelector<HTMLElement>('[data-mock]');
    if (!mock) return;
    // 원본 배치를 유지하며 가시 폭에 맞춰 축소. 화면 전환 중 높이도 같은 배율로 반영.
    const fit = () => {
      const scale = Math.min(1, device.clientWidth / mock.offsetWidth);
      mock.style.setProperty('--hero-scale', String(scale));
      const height = scale < 1 ? `${mock.getBoundingClientRect().height}px` : '';
      if (device.style.height !== height) device.style.height = height;
    };
    const observer = new ResizeObserver(() => requestAnimationFrame(fit));
    observer.observe(device);
    observer.observe(mock);
    fit();
  });
  document.querySelectorAll<HTMLElement>('[data-words] .w').forEach((w) => {
    w.style.setProperty('--i', w.dataset.i ?? '0');
  });
  requestAnimationFrame(() => {
    document.querySelectorAll('[data-words]').forEach((el) => el.classList.add('is-in'));
  });
}

function initReveal(): void {
  const els = document.querySelectorAll('.reveal');
  if (!('IntersectionObserver' in window)) {
    els.forEach((el) => el.classList.add('is-in'));
    return;
  }
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          e.target.classList.add('is-in');
          io.unobserve(e.target);
        }
      }
    },
    { threshold: 0.15, rootMargin: '0px 0px -10% 0px' },
  );
  els.forEach((el) => io.observe(el));
}

function initNav(): void {
  const nav = document.querySelector('[data-nav]');
  const sentinel = document.querySelector('[data-nav-sentinel]');
  if (!nav || !sentinel) return;
  new IntersectionObserver(([entry]) => {
    nav.classList.toggle('is-scrolled', !entry.isIntersecting);
  }).observe(sentinel);
}

// 사용량·초기화 표시와 Total Spend 선택은 예시 화면 안에서만 적용.
function initAppMock(): void {
  const roots = document.querySelectorAll<HTMLElement>('[data-mock]');
  if (!roots.length) return;

  document.addEventListener('click', (event) => {
    const target = event.target as Element | null;
    if (!target || !target.closest) return;

    const headline = target.closest<HTMLElement>('[data-toggle-meter]');
    if (headline) {
      const root = headline.closest<HTMLElement>('[data-mock]');
      const next = root?.dataset.mode === 'left' ? 'used' : 'left';
      setPreviewPreference('showUsageAs', next === 'left' ? 'Left' : 'Used');
      return;
    }

    const reset = target.closest<HTMLElement>('[data-toggle-reset]');
    if (reset) {
      const root = reset.closest<HTMLElement>('[data-mock]');
      const next = root?.dataset.reset === 'relative' ? 'absolute' : 'relative';
      setPreviewPreference('resetTimes', next === 'relative' ? 'Countdown' : 'Exact Time');
      return;
    }

    const period = target.closest<HTMLButtonElement>('[data-period]');
    if (period) {
      selectSpend(period, 'period');
      return;
    }

    const cycle = target.closest<HTMLButtonElement>('[data-cycle-spend]');
    if (cycle) { selectSpend(cycle, 'metric'); return; }
  });
  document.addEventListener('keydown', (event) => {
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
    const period = event.target instanceof Element ? event.target.closest<HTMLButtonElement>('[data-period]') : null;
    if (!period) return;
    const direction = ['ArrowRight', 'ArrowDown'].includes(event.key) ? 1 : ['ArrowLeft', 'ArrowUp'].includes(event.key) ? -1 : 0;
    if (!direction) return;
    event.preventDefault();
    const options = Array.from(period.closest('[role="radiogroup"]')!.querySelectorAll<HTMLButtonElement>('[data-period]'));
    const next = options[(options.indexOf(period) + direction + options.length) % options.length];
    selectSpend(next, 'period');
    next.focus({ preventScroll: true });
  });
}

function initResetDetails(): void {
  document.querySelectorAll<HTMLElement>('[data-mock] .am-resets').forEach((row, index) => {
    const trigger = row.querySelector<HTMLButtonElement>('.am-reset-trigger')!;
    const detail = row.querySelector<HTMLElement>('.am-reset-detail')!;
    detail.id = `reset-detail-${index}`;
    trigger.setAttribute('aria-controls', detail.id);
    let timer = 0;
    const cancel = (): void => window.clearTimeout(timer);
    const open = (): void => {
      cancel();
      openMenu(detail, trigger);
      const anchor = trigger.getBoundingClientRect();
      const bounds = detail.getBoundingClientRect();
      const center = (anchor.left + anchor.right) / 2;
      const left = Math.max(8, Math.min(center - bounds.width / 2, document.documentElement.clientWidth - bounds.width - 8));
      detail.style.left = `${left}px`;
      detail.style.setProperty('--reset-arrow-x', `${Math.max(14, Math.min(center - left, bounds.width - 14))}px`);
      detail.dataset.side = bounds.bottom <= anchor.top ? 'above' : 'below';
    };
    const leave = (event: PointerEvent): void => {
      cancel();
      if (event.pointerType === 'touch' || detail.contains(document.activeElement)) return;
      timer = window.setTimeout(() => closeMenu(detail), 180);
    };
    trigger.addEventListener('pointerenter', (event) => {
      if (event.pointerType === 'touch') return;
      cancel();
      timer = window.setTimeout(open, 400);
    });
    trigger.addEventListener('pointerleave', leave);
    detail.addEventListener('pointerenter', cancel);
    detail.addEventListener('pointerleave', leave);
    trigger.addEventListener('click', () => {
      cancel();
      if (!detail.hidden) closeMenu(detail);
      else {
        open();
        detail.focus({ preventScroll: true });
      }
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') cancel();
    });
  });
}

const spendKey = 'openusage.site.spend.v1';
const metrics = ['cost', 'costPerMtok', 'tokens'];
const periods = ['today', 'yesterday', 'last30'];

function renderSpend(card: HTMLElement): void {
  const period = card.dataset.spendPeriod!;
  const metric = card.dataset.spendMetric!;
  card.querySelectorAll<HTMLButtonElement>('[data-period]').forEach((button) => {
    const on = button.dataset.period === period;
    button.setAttribute('aria-checked', String(on));
    button.tabIndex = on ? 0 : -1;
  });
  card.querySelectorAll<HTMLElement>('[data-state]').forEach((state) => { state.hidden = state.dataset.state !== `${period}:${metric}`; });
}

function restoreSpend(): void {
  const card = document.querySelector<HTMLElement>('[data-mock] .am-spend-card');
  if (!card) return;
  try {
    const raw = localStorage.getItem(spendKey);
    if (!raw) return;
    const stored = JSON.parse(raw);
    if (!periods.includes(stored.period) || !metrics.includes(stored.metric)) throw new Error('Invalid saved spend selection');
    card.dataset.spendPeriod = stored.period;
    card.dataset.spendMetric = stored.metric;
    renderSpend(card);
  } catch (error) { console.warn('Saved spend selection could not be loaded', error); }
}

function selectSpend(clicked: HTMLButtonElement, kind: 'period' | 'metric'): void {
  const card = clicked.closest<HTMLElement>('.am-spend-card');
  if (!card) return;
  if (kind === 'period') card.dataset.spendPeriod = clicked.dataset.period!;
  else card.dataset.spendMetric = metrics[(metrics.indexOf(card.dataset.spendMetric!) + 1) % metrics.length];
  renderSpend(card);
  if (kind === 'metric') {
    const state = card.querySelector<HTMLElement>('[data-state]:not([hidden])')!;
    (clicked.dataset.spendProvider
      ? state.querySelector<HTMLElement>(`[data-spend-provider="${clicked.dataset.spendProvider}"]`)
      : state.querySelector<HTMLElement>('[data-cycle-spend]'))?.focus({ preventScroll: true });
  }
  try { localStorage.setItem(spendKey, JSON.stringify({ period: card.dataset.spendPeriod, metric: card.dataset.spendMetric })); }
  catch (error) { console.warn('Spend selection could not be saved', error); }
}

interface FeedItem {
  channel: string;
  build: number;
  short: string;
  url: string;
  pub: number;
}

// 같은 출처 appcast에서 stable 최신 item을 골라 다운로드 링크·버전을 승격.
// 규칙: channel 없는 정식 버전 + sparkle:version 최대, 동률이면 pubDate 늦은 것.
async function initDownload(): Promise<void> {
  const links = document.querySelectorAll<HTMLAnchorElement>('[data-download]');
  const meta = document.querySelector<HTMLElement>('[data-download-meta]');
  if (!links.length) return;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 5000);
  try {
    const res = await fetch('/appcast.xml', { signal: ctrl.signal });
    if (!res.ok) throw new Error(`Appcast returned HTTP ${res.status}`);
    const doc = new DOMParser().parseFromString(await res.text(), 'application/xml');
    if (doc.querySelector('parsererror')) throw new Error('Appcast contains invalid XML');
    const items: FeedItem[] = Array.from(doc.getElementsByTagName('item'))
      .map((it) => {
        const ns = (name: string): string => it.getElementsByTagNameNS(SPARKLE_NS, name)[0]?.textContent?.trim() ?? '';
        const enclosure = it.querySelector('enclosure');
        return {
          channel: ns('channel'),
          build: Number(ns('version')),
          short: ns('shortVersionString'),
          url: enclosure?.getAttribute('url') ?? '',
          pub: Date.parse(it.querySelector('pubDate')?.textContent ?? '') || 0,
        };
      })
      .filter((i) => i.channel === '' && /^\d+\.\d+\.\d+$/.test(i.short)
        && Number.isSafeInteger(i.build) && i.build > 0
        && DOWNLOAD_PREFIXES.some((prefix) => i.url.startsWith(prefix) && new URL(i.url).href.startsWith(prefix)));
    if (!items.length) throw new Error('Appcast contains no valid stable release');
    const latest = items.reduce((a, b) => (b.build > a.build || (b.build === a.build && b.pub > a.pub) ? b : a));
    links.forEach((a) => {
      a.href = latest.url;
    });
    if (meta && latest.short) {
      meta.textContent = `v${latest.short}`;
      meta.hidden = false;
    }
  } catch (error) {
    console.warn('egasu release metadata unavailable; keeping the release-page link', error);
  } finally {
    clearTimeout(timer);
  }
}

// 초기화 중 오류가 나면 .js를 떼어 JS 없는 렌더링(전부 표시)으로 되돌림.
try {
  document.documentElement.classList.add('js');
  // js-flag.js의 안전장치에 "런타임이 실제로 떴다"고 알림.
  document.documentElement.dataset.ready = '1';
  initHero();
  initReveal();
  initNav();
  initFeatureTour();
  initMenus();
  initResetDetails();
  initAppMock();
  restoreSpend();
  initPopoverNav();
} catch (error) {
  document.documentElement.classList.remove('js');
  delete document.documentElement.dataset.ready;
  throw error;
}
// 버전 fetch는 홈에서만(404 페이지는 정적 링크 유지).
if (document.body.dataset.page === 'home') void initDownload();
