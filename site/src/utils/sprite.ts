// 앱 리소스 SVG를 인라인 sprite <symbol>로 변환.
// 앱 SVG가 없는 QwenCloud는 앱과 같은 구름 윤곽 아이콘 사용.
// fill 속성은 none만 남기고 제거해 currentColor로 통일.
// egasu.svg(앱 아이콘 글리프)는 상표 결정 전까지 sprite에 넣지 않음(providers.ts에 없음).
import { providers } from '../data/providers';

const files = import.meta.glob('../../../Sources/Egasu/Resources/ProviderIcons/*.svg', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const providerMarks = Object.fromEntries(Object.entries(files).map(([path, svg]) =>
  [path.slice(path.lastIndexOf('/') + 1, -4), svg]));

export interface SpriteSymbol {
  id: string;
  viewBox: string;
  body: string;
}

export function providerSymbols(): SpriteSymbol[] {
  return providers.map((provider) => {
    const { id } = provider;
    const mark = 'mark' in provider ? provider.mark : id;
    if (mark === 'cloud') {
      return {
        id, viewBox: '0 0 24 24',
        body: '<path d="M6.5 18.5a4.5 4.5 0 0 1-.6-9 6.5 6.5 0 0 1 12.3-1.1 5.1 5.1 0 0 1-.5 10.1Z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/>',
      };
    }
    const svg = providerMarks[mark];
    if (!svg) throw new Error(`Missing provider mark: ${id}`);
    const viewBox = svg.match(/viewBox="([^"]+)"/)?.[1] ?? '0 0 24 24';
    const body = svg
      .replace(/^[\s\S]*?<svg[^>]*>/, '')
      .replace(/<\/svg>\s*$/, '')
      .replace(/\sfill="(?!none")[^"]*"/g, '')
      .trim();
    return { id, viewBox, body };
  });
}
