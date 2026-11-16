import assert from 'node:assert/strict';
import test from 'node:test';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, matchesGlob } from 'node:path';
import { spawnSync } from 'node:child_process';

function workflow(file: string) {
  return readFileSync(new URL(`../../.github/workflows/${file}`, import.meta.url), 'utf8');
}

function step(file: string, name: string) {
  const lines = workflow(file).split('\n');
  const start = lines.indexOf(`      - name: ${name}`);
  assert.notEqual(start, -1);
  assert.equal(lines[start + 1], '        run: |');
  const body: string[] = [];
  for (const line of lines.slice(start + 2)) {
    if (line && !line.startsWith('          ')) break;
    body.push(line.slice(10));
  }
  return body.join('\n');
}

for (const file of ['release.yml', 'publish-site.yml', 'pricing-supplement.yml']) {
  test(`${file}: 자동 게시에 버전 태그 필수, 수동 게시에 대상 태그 필수`, () => {
    const triggers = workflow(file).split('\non:\n')[1].split('\npermissions:')[0].split('\nconcurrency:')[0];
    assert.match(triggers, /  push:\n    tags: \["v\*"\]/);
    assert.doesNotMatch(triggers, /\bbranches:|\bpaths:/);
    assert.match(triggers, /  workflow_dispatch:\n    inputs:\n      tag:\n        description: [^\n]+\n        required: true\n        type: string/);
  });
}

test('사이트·가격표 입력은 수동 태그 또는 이벤트 SHA, 사이트 게시 소스는 검증한 SHA로 고정', () => {
  const publish = workflow('publish-site.yml');
  assert.match(publish, /uses: \.\/\.github\/workflows\/site\.yml\n    with:\n      ref: \$\{\{ inputs.tag \|\| github.sha \}\}/);
  assert.match(workflow('pricing-supplement.yml'), /ref: \$\{\{ inputs.tag \|\| github.sha \}\}\n          fetch-depth: 0/);
  assert.match(publish, /needs: verify/);
  assert.match(publish, /ref: \$\{\{ needs.verify.outputs.source_sha \}\}\n          fetch-depth: 0/);
  const site = workflow('site.yml');
  assert.match(site, /ref: \$\{\{ inputs.ref \|\| github.sha \}\}\n          persist-credentials: false/);
  assert.match(site, /    outputs:\n      source_sha:\n        description: [^\n]+\n        value: \$\{\{ jobs.verify.outputs.source_sha \}\}/);
  assert.match(site, /  verify:\n    outputs:\n      source_sha: \$\{\{ steps.source.outputs.source_sha \}\}/);
  assert.match(site, /      - name: 검증한 소스 커밋 기록\n        run: \|\n(?:          [^\n]*\n)+        id: source/);
  assert.match(step('publish-site.yml', '랜딩 페이지 조립'), /"\$\(git rev-parse HEAD\)"/);
  assert.doesNotMatch(step('publish-site.yml', '랜딩 페이지 조립'), /GITHUB_SHA/);
});

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'egasu-tag-publication-'));
  const remote = join(root, 'remote');
  const checkout = join(root, 'checkout');
  mkdirSync(join(remote, 'script'), { recursive: true });
  copyFileSync(new URL('../../script/version.sh', import.meta.url), join(remote, 'script/version.sh'));
  const env = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
  function git(cwd: string, ...args: string[]) {
    const result = spawnSync('git', args, { cwd, env, encoding: 'utf8', timeout: 5000 });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    return result.stdout.trim();
  }
  function commit() {
    git(remote, 'add', '--all');
    git(remote, '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
      'commit', '--quiet', '-m', 'test: publication source');
  }
  git(remote, 'init', '--quiet', '--initial-branch=main');
  commit();
  git(remote, 'tag', 'v1.2.3');
  git(remote, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
    'tag', '-a', 'v1.2.4-beta.1', '-m', 'beta');
  git(root, 'clone', '--quiet', remote, checkout);
  return {
    root, remote, checkout, git, commit,
    run(file: string, name: string, extraEnv: NodeJS.ProcessEnv = {}) {
      return spawnSync('bash', ['-e', '-o', 'pipefail', '-c', step(file, name)], {
        cwd: checkout, env: { ...env, GITHUB_WORKSPACE: checkout, ...extraEnv }, encoding: 'utf8', timeout: 5000,
      });
    },
    cleanup() { rmSync(root, { recursive: true, force: true }); },
  };
}

for (const file of ['publish-site.yml', 'pricing-supplement.yml']) {
  test(`${file}: main에 포함된 정식·annotated 베타 태그 허용`, () => {
    const f = fixture();
    try {
      for (const tag of ['v1.2.3', 'v1.2.4-beta.1']) {
        const result = f.run(file, '게시 태그 확인', { PUBLICATION_TAG: tag });
        assert.equal(result.status, 0, result.stderr);
      }
    } finally { f.cleanup(); }
  });

  for (const tag of ['main', '', 'v1.2.5', 'v0.6.28']) {
    test(`${file}: 브랜치·미지정·없는 태그·지원 밖 태그 ${JSON.stringify(tag)} 거부`, () => {
      const f = fixture();
      try {
        assert.notEqual(f.run(file, '게시 태그 확인', { PUBLICATION_TAG: tag }).status, 0);
      } finally { f.cleanup(); }
    });
  }

  test(`${file}: 태그와 다른 체크아웃 또는 main 밖 태그 거부`, () => {
    const f = fixture();
    try {
      f.git(f.remote, 'checkout', '--quiet', '-b', 'feature');
      writeFileSync(join(f.remote, 'unmerged.txt'), 'not on main');
      f.commit();
      f.git(f.remote, 'tag', 'v1.2.5');
      f.git(f.checkout, 'fetch', '--quiet', 'origin', 'refs/tags/v1.2.5:refs/tags/v1.2.5');
      f.git(f.checkout, 'checkout', '--quiet', '--detach', 'v1.2.5');
      assert.notEqual(f.run(file, '게시 태그 확인', { PUBLICATION_TAG: 'v1.2.3' }).status, 0);
      assert.notEqual(f.run(file, '게시 태그 확인', { PUBLICATION_TAG: 'v1.2.5' }).status, 0);
    } finally { f.cleanup(); }
  });

  test(`${file}: main의 다른 커밋으로 이동한 태그와 push 이벤트 SHA가 다르면 거부`, () => {
    const f = fixture();
    try {
      const eventSHA = f.git(f.checkout, 'rev-parse', 'HEAD');
      writeFileSync(join(f.remote, 'changed.txt'), 'new publication source');
      f.commit();
      const movedSHA = f.git(f.remote, 'rev-parse', 'HEAD');
      f.git(f.remote, 'tag', '--force', 'v1.2.3');
      f.git(f.checkout, 'fetch', '--quiet', 'origin', '+refs/tags/v1.2.3:refs/tags/v1.2.3');
      f.git(f.checkout, 'checkout', '--quiet', '--detach', eventSHA);

      const result = f.run(file, '게시 태그 확인', { PUBLICATION_TAG: 'v1.2.3', GITHUB_SHA: eventSHA });
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /Release tag does not point to HEAD/);
      assert.equal(f.git(f.checkout, 'rev-parse', 'HEAD'), eventSHA);
      assert.equal(f.git(f.checkout, 'rev-parse', 'origin/main'), movedSHA);
    } finally { f.cleanup(); }
  });
}

test('수동 사이트 검증 후 태그가 이동해도 게시 소스는 검증한 SHA를 유지하고 게시 거부', () => {
  const f = fixture();
  try {
    f.git(f.checkout, 'checkout', '--quiet', '--detach', 'v1.2.3');
    const verifiedSHA = f.git(f.checkout, 'rev-parse', 'HEAD');
    const output = join(f.root, 'source-output');
    const recorded = f.run('site.yml', '검증한 소스 커밋 기록', { GITHUB_OUTPUT: output });
    assert.equal(recorded.status, 0, recorded.stderr);
    assert.equal(readFileSync(output, 'utf8'), `source_sha=${verifiedSHA}\n`);
    const sourceSHA = readFileSync(output, 'utf8').trim().slice('source_sha='.length);

    writeFileSync(join(f.remote, 'changed.txt'), 'changed after verification');
    f.commit();
    const movedSHA = f.git(f.remote, 'rev-parse', 'HEAD');
    f.git(f.remote, 'tag', '--force', 'v1.2.3');
    f.git(f.checkout, 'fetch', '--quiet', 'origin', '+refs/tags/v1.2.3:refs/tags/v1.2.3');
    f.git(f.checkout, 'checkout', '--quiet', '--detach', sourceSHA);

    const result = f.run('publish-site.yml', '게시 태그 확인', { PUBLICATION_TAG: 'v1.2.3' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Release tag does not point to HEAD/);
    assert.equal(f.git(f.checkout, 'rev-parse', 'HEAD'), verifiedSHA);
    assert.equal(f.git(f.checkout, 'rev-parse', 'refs/tags/v1.2.3'), movedSHA);
    assert.equal(f.git(f.checkout, 'rev-parse', 'origin/main'), movedSHA);
  } finally { f.cleanup(); }
});

test('Pages는 원격 태그와 게시 소스 커밋이 같을 때만 배포 허용', () => {
  const f = fixture();
  try {
    const source = f.git(f.checkout, 'rev-parse', 'HEAD');
    for (const tag of ['v1.2.3', 'v1.2.4-beta.1']) {
      assert.equal(f.run('deploy-pages.yml', '게시 원본 태그 확인', { PUBLISH_TAG: tag, PUBLISH_SOURCE_SHA: source }).status, 0);
    }
    assert.notEqual(f.run('deploy-pages.yml', '게시 원본 태그 확인', { PUBLISH_TAG: 'v1.2.5', PUBLISH_SOURCE_SHA: source }).status, 0);
    assert.notEqual(f.run('deploy-pages.yml', '게시 원본 태그 확인', { PUBLISH_TAG: 'v1.2.3', PUBLISH_SOURCE_SHA: 'a'.repeat(40) }).status, 0);
  } finally { f.cleanup(); }
});

test('main·PR의 사이트 변경은 게시 없이 Site CI에서 검증', () => {
  function paths(event: 'push' | 'pull_request') {
    const lines = workflow('site.yml').split('\n');
    const start = lines.indexOf(`  ${event}:`);
    assert.notEqual(start, -1);
    const patterns: string[] = [];
    for (const line of lines.slice(start + 1)) {
      if (line && !line.startsWith('    ')) break;
      const match = line.match(/^      - '([^']+)'$/);
      if (match) patterns.push(match[1]);
    }
    return patterns;
  }
  for (const event of ['push', 'pull_request'] as const) {
    const filters = paths(event);
    for (const path of ['site/src/scripts/app.ts', 'script/site_assemble.sh',
      'Sources/Egasu/Resources/ProviderIcons/codex.svg', 'Sources/Egasu/Resources/Localization/ko.lproj/Settings.strings',
      'Sources/Egasu/Stores/WidgetDataStore.swift', '.github/workflows/publish-site.yml']) {
      assert.equal(filters.some(pattern => matchesGlob(path, pattern)), true, `${event}: ${path}`);
    }
    assert.equal(filters.some(pattern => matchesGlob('docs/settings.md', pattern)), false);
  }
  assert.doesNotMatch(workflow('site.yml'), /peaceiris\/actions-gh-pages|actions\/deploy-pages/);
});
