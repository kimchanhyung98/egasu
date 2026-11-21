import assert from 'node:assert/strict';
import test from 'node:test';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

function workflowStep(name: string, file = 'publish-site.yml') {
  const workflow = readFileSync(new URL(`../../.github/workflows/${file}`, import.meta.url), 'utf8');
  const lines = workflow.split('\n');
  const start = lines.indexOf(`      - name: ${name}`);
  assert.notEqual(start, -1, `Missing workflow step: ${name}`);
  assert.equal(lines[start + 1], '        run: |');
  const body: string[] = [];
  for (const line of lines.slice(start + 2)) {
    if (line && !line.startsWith('          ')) break;
    body.push(line.slice(10));
  }
  return body.join('\n');
}

function publicationFixture() {
  const temp = mkdtempSync(join(tmpdir(), 'egasu-publication-test-'));
  const published = join(temp, 'published');
  const checkout = join(temp, 'checkout');
  mkdirSync(published);
  mkdirSync(join(checkout, 'script'), { recursive: true });
  copyFileSync(new URL('../../script/site_feed_snapshot.sh', import.meta.url), join(checkout, 'script/site_feed_snapshot.sh'));
  const env = { ...process.env, RUNNER_TEMP: temp, PUBLICATION_TAG: 'v1.2.3', GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
  function git(cwd: string, ...args: string[]) {
    const result = spawnSync('git', args, { cwd, env, encoding: 'utf8', timeout: 5000 });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    return result.stdout.trim();
  }
  function commit() {
    git(published, 'add', '--all');
    git(published, '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
      'commit', '--quiet', '-m', 'test: update publication fixture');
  }
  git(published, 'init', '--quiet', '--initial-branch=gh-pages');
  git(checkout, 'init', '--quiet', '--initial-branch=main');
  git(checkout, 'remote', 'add', 'origin', published);
  writeFileSync(join(published, 'appcast.xml'), '<rss><channel/></rss>\n');
  writeFileSync(join(published, 'pricing_supplement.json'), '{"pricing":{}}\n');
  writeFileSync(join(published, 'CNAME'), 'egasu.chanhyung.kim\n');
  commit();
  git(published, 'branch', 'main');
  git(published, 'tag', 'v1.2.3');
  git(checkout, 'fetch', '--quiet', 'origin', 'main');
  git(checkout, 'checkout', '--quiet', '-B', 'main', 'FETCH_HEAD');
  return {
    temp, published, checkout, commit, git,
    run(name: string, file = 'publish-site.yml', extraEnv: NodeJS.ProcessEnv = {}) {
      return spawnSync('bash', ['-e', '-o', 'pipefail', '-c', workflowStep(name, file)], {
        cwd: checkout, env: { ...env, ...extraEnv }, encoding: 'utf8', timeout: 5000,
      });
    },
    cleanup() { rmSync(temp, { recursive: true, force: true }); },
  };
}

const snapshot = '게시된 피드 기준값 기록';
const verify = '게시 전후 피드 불변 확인';

test('Site CI는 잠금 파일의 Playwright 버전으로 컨테이너 선택', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/site.yml', import.meta.url), 'utf8');
  const lock = JSON.parse(readFileSync(new URL('../package-lock.json', import.meta.url), 'utf8'));
  const temp = mkdtempSync(join(tmpdir(), 'egasu-playwright-version-'));
  const output = join(temp, 'output');
  try {
    const result = spawnSync('bash', ['-e', '-c', workflowStep('Playwright 버전 확인', 'site.yml')], {
      cwd: new URL('../../', import.meta.url), env: { ...process.env, GITHUB_OUTPUT: output }, encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(output, 'utf8').trim(), `version=${lock.packages['node_modules/@playwright/test'].version}`);
    const [prepare, verify] = workflow.split('\n  verify:\n');
    assert.ok(prepare.includes('ref: ${{ inputs.ref || github.sha }}'));
    assert.ok(prepare.includes('source_sha: ${{ steps.checkout.outputs.commit }}'));
    assert.ok(verify.includes('ref: ${{ needs.playwright.outputs.source_sha }}'));
    assert.ok(workflow.includes('image: mcr.microsoft.com/playwright:v${{ needs.playwright.outputs.version }}-noble'));
  } finally { rmSync(temp, { recursive: true, force: true }); }
});

test('피드 두 개와 도메인을 보존하는 사이트 갱신 허용', () => {
  const fixture = publicationFixture();
  try {
    const before = fixture.run(snapshot);
    assert.equal(before.status, 0, before.stderr);
    writeFileSync(join(fixture.published, 'index.html'), '<title>Landing page</title>');
    fixture.commit();
    const after = fixture.run(verify);
    assert.equal(after.status, 0, after.stderr);
    assert.equal(readFileSync(join(fixture.temp, 'pages-publication/revision.txt'), 'utf8').trim(),
      fixture.git(fixture.published, 'rev-parse', 'HEAD'));
  } finally { fixture.cleanup(); }
});

test('기존 도메인에서 egasu 도메인으로 첫 사이트 게시 허용', () => {
  const fixture = publicationFixture();
  try {
    writeFileSync(join(fixture.published, 'CNAME'), 'openusage.chanhyung.kim\n');
    fixture.commit();
    const before = fixture.run(snapshot);
    assert.equal(before.status, 0, before.stderr);
    writeFileSync(join(fixture.published, 'CNAME'), 'egasu.chanhyung.kim\n');
    fixture.commit();
    const after = fixture.run(verify);
    assert.equal(after.status, 0, after.stderr);
    assert.equal(readFileSync(join(fixture.temp, 'pages-publication/revision.txt'), 'utf8').trim(),
      fixture.git(fixture.published, 'rev-parse', 'HEAD'));
  } finally { fixture.cleanup(); }
});

test('첫 사이트 게시 후 기존 도메인이 남으면 거부', () => {
  const fixture = publicationFixture();
  try {
    writeFileSync(join(fixture.published, 'CNAME'), 'openusage.chanhyung.kim\n');
    fixture.commit();
    assert.equal(fixture.run(snapshot).status, 0);
    writeFileSync(join(fixture.published, 'index.html'), '<title>Landing page</title>');
    fixture.commit();
    const after = fixture.run(verify);
    assert.notEqual(after.status, 0);
    assert.match(after.stderr, /CNAME does not match/);
    assert.equal(existsSync(join(fixture.temp, 'pages-publication/revision.txt')), false);
  } finally { fixture.cleanup(); }
});

for (const file of ['appcast.xml', 'pricing_supplement.json', 'CNAME']) {
  test(`${file} 누락 시 게시 전 실패`, () => {
    const fixture = publicationFixture();
    try {
      rmSync(join(fixture.published, file));
      fixture.commit();
      const result = fixture.run(snapshot);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /missing or is not a regular file/);
    } finally { fixture.cleanup(); }
  });

  test(`게시된 ${file} 변경 시 실패`, () => {
    const fixture = publicationFixture();
    try {
      assert.equal(fixture.run(snapshot).status, 0);
      writeFileSync(join(fixture.published, file), file === 'CNAME' ? 'example.invalid\n' : 'changed\n');
      fixture.commit();
      const result = fixture.run(verify);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr + result.stdout, /Published feeds changed|CNAME does not match/);
      assert.equal(existsSync(join(fixture.temp, 'pages-publication/revision.txt')), false);
    } finally { fixture.cleanup(); }
  });
}

test('도메인 불일치 시 게시 전 거부', () => {
  const fixture = publicationFixture();
  try {
    writeFileSync(join(fixture.published, 'CNAME'), 'example.invalid\n');
    fixture.commit();
    const result = fixture.run(snapshot);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /CNAME does not match/);
  } finally { fixture.cleanup(); }
});

test('게시 액션이 제거하는 .github 경로가 있으면 게시 거부', () => {
  const fixture = publicationFixture();
  try {
    mkdirSync(join(fixture.published, '.github'));
    writeFileSync(join(fixture.published, '.github/keep.txt'), 'existing file');
    fixture.commit();
    const result = fixture.run(snapshot);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /must not contain .github/);
  } finally { fixture.cleanup(); }
});

for (const file of ['appcast.xml', 'pricing_supplement.json', 'CNAME']) {
  test(`${file}이 심볼릭 링크면 게시 전 거부`, () => {
    const fixture = publicationFixture();
    try {
      rmSync(join(fixture.published, file));
      symlinkSync('payload.txt', join(fixture.published, file));
      writeFileSync(join(fixture.published, 'payload.txt'), 'invalid feed');
      fixture.commit();
      const result = fixture.run(snapshot);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /not a regular file/);
    } finally { fixture.cleanup(); }
  });
}

for (const file of ['release.yml', 'pricing-supplement.yml']) {
  test(`${file} 게시 결과에 실제 원격 커밋 기록`, () => {
    const fixture = publicationFixture();
    try {
      const result = fixture.run('게시된 Pages 커밋 기록', file);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(readFileSync(join(fixture.temp, 'pages-publication/revision.txt'), 'utf8').trim(),
        fixture.git(fixture.published, 'rev-parse', 'HEAD'));
      assert.equal(readFileSync(join(fixture.temp, 'pages-publication/tag.txt'), 'utf8').trim(), 'v1.2.3');
      assert.equal(readFileSync(join(fixture.temp, 'pages-publication/source.txt'), 'utf8').trim(),
        fixture.git(fixture.checkout, 'rev-parse', 'HEAD'));
    } finally { fixture.cleanup(); }
  });
}

function guardedDeploymentFixture() {
  const fixture = publicationFixture();
  const output = join(fixture.temp, 'github-output');
  const checkpoint = 'refs/heads/pages-deployment';
  return {
    ...fixture, output, checkpoint,
    deploy(ref: string) {
      fixture.git(fixture.checkout, 'fetch', '--quiet', 'origin', 'gh-pages');
      fixture.git(fixture.checkout, 'checkout', '--quiet', '--detach', ref);
      writeFileSync(output, '');
      return fixture.run('과거 Pages 배포 차단', 'deploy-pages.yml', { GITHUB_OUTPUT: output });
    },
  };
}

test('Pages 최초 배포와 새 커밋 전진 후 과거 실행은 배포 생략', () => {
  const fixture = guardedDeploymentFixture();
  try {
    const first = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    let result = fixture.deploy(first);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(fixture.output, 'utf8').trim(), 'deploy=true');
    assert.equal(fixture.git(fixture.published, 'rev-parse', fixture.checkpoint), first);
    writeFileSync(join(fixture.published, 'appcast.xml'), 'new release\n');
    fixture.commit();
    const second = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    result = fixture.deploy(second);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fixture.git(fixture.published, 'rev-parse', fixture.checkpoint), second);
    result = fixture.deploy(first);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(fixture.output, 'utf8').trim(), 'deploy=false');
    assert.equal(fixture.git(fixture.published, 'rev-parse', fixture.checkpoint), second);
  } finally { fixture.cleanup(); }
});

test('Pages 기준 전진 후 게시 head가 바뀌어도 동일 SHA 재시도 허용', () => {
  const fixture = guardedDeploymentFixture();
  try {
    const verified = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    assert.equal(fixture.deploy(verified).status, 0);
    writeFileSync(join(fixture.published, 'appcast.xml'), 'unverified feed\n');
    fixture.commit();
    const result = fixture.deploy(verified);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(fixture.output, 'utf8').trim(), 'deploy=true');
    assert.equal(fixture.git(fixture.checkout, 'rev-parse', 'HEAD'), verified);
    assert.equal(fixture.git(fixture.published, 'rev-parse', fixture.checkpoint), verified);
  } finally { fixture.cleanup(); }
});

test('과거 Pages 실행으로 최초 보호 기준 생성 금지', () => {
  const fixture = guardedDeploymentFixture();
  try {
    const old = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    writeFileSync(join(fixture.published, 'index.html'), 'newer publication\n');
    fixture.commit();
    const result = fixture.deploy(old);
    assert.notEqual(result.status, 0);
    assert.match(result.stdout, /latest successful publication/);
    assert.equal(readFileSync(fixture.output, 'utf8'), '');
    assert.equal(fixture.git(fixture.published, 'for-each-ref', '--format=%(refname)', fixture.checkpoint), '');
  } finally { fixture.cleanup(); }
});

test('갈라진 Pages 게시 이력은 강제 전진 없이 실패', () => {
  const fixture = guardedDeploymentFixture();
  try {
    const first = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    writeFileSync(join(fixture.published, 'index.html'), 'deployed branch\n');
    fixture.commit();
    const deployed = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    assert.equal(fixture.deploy(deployed).status, 0);
    fixture.git(fixture.published, 'checkout', '--quiet', '--detach', first);
    writeFileSync(join(fixture.published, 'index.html'), 'diverged branch\n');
    fixture.commit();
    const diverged = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    fixture.git(fixture.published, 'update-ref', 'refs/heads/gh-pages', diverged);
    const result = fixture.deploy(diverged);
    assert.notEqual(result.status, 0);
    assert.match(result.stdout, /not a descendant/);
    assert.equal(readFileSync(fixture.output, 'utf8'), '');
    assert.equal(fixture.git(fixture.published, 'rev-parse', fixture.checkpoint), deployed);
  } finally { fixture.cleanup(); }
});

for (const failure of ['read', 'write']) {
  test(`Pages 보호 기준 ${failure} 실패 시 배포 금지`, () => {
    const fixture = guardedDeploymentFixture();
    try {
      const ref = fixture.git(fixture.published, 'rev-parse', 'HEAD');
      fixture.git(fixture.checkout, 'fetch', '--quiet', 'origin', 'gh-pages');
      fixture.git(fixture.checkout, 'checkout', '--quiet', '--detach', ref);
      if (failure === 'read') {
        fixture.git(fixture.checkout, 'remote', 'set-url', 'origin', join(fixture.temp, 'missing'));
      } else {
        writeFileSync(join(fixture.published, '.git/hooks/pre-receive'), '#!/bin/sh\nexit 1\n', { mode: 0o755 });
      }
      writeFileSync(fixture.output, '');
      const result = fixture.run('과거 Pages 배포 차단', 'deploy-pages.yml', { GITHUB_OUTPUT: fixture.output });
      assert.notEqual(result.status, 0);
      assert.equal(readFileSync(fixture.output, 'utf8'), '');
    } finally { fixture.cleanup(); }
  });
}

test('Pages 보호 통과 조건이 산출물 업로드와 실제 배포 모두에 적용', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/deploy-pages.yml', import.meta.url), 'utf8');
  for (const name of ['사이트 배포 산출물 업로드', 'GitHub Pages 배포']) {
    assert.ok(workflow.includes(`      - name: ${name}\n        if: steps.revision.outputs.deploy == 'true'`));
  }
  assert.match(workflow, /ref: \$\{\{ env.PAGES_REF \}\}\n          fetch-depth: 0/);
  assert.match(workflow, /group: pages-deploy\n  queue: max\n  cancel-in-progress: false/);
});

function deploymentFixture() {
  const fixture = publicationFixture();
  const bin = join(fixture.temp, 'bin');
  const artifact = join(fixture.temp, 'downloaded-revision.txt');
  const tagArtifact = join(fixture.temp, 'downloaded-tag.txt');
  const sourceArtifact = join(fixture.temp, 'downloaded-source.txt');
  const runMetadata = join(fixture.temp, 'publication-run-fixture.json');
  const githubEnv = join(fixture.temp, 'github-env');
  const ghArgs = join(fixture.temp, 'gh-args');
  mkdirSync(bin);
  writeFileSync(artifact, fixture.git(fixture.published, 'rev-parse', 'HEAD') + '\n');
  writeFileSync(tagArtifact, 'v1.2.3\n');
  writeFileSync(sourceArtifact, fixture.git(fixture.checkout, 'rev-parse', 'HEAD') + '\n');
  writeFileSync(runMetadata, JSON.stringify({ name: 'Publish landing page', event: 'workflow_dispatch', conclusion: 'success', run_attempt: 2 }));
  writeFileSync(githubEnv, '');
  // 원격 다운로드만 대체. 커밋 선택·체크아웃은 실제 워크플로우와 Git으로 검증.
  writeFileSync(join(bin, 'gh'), `#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = api ]; then cat "$GH_RUN_METADATA"; exit 0; fi
printf '%s\\n' "$@" > "$GH_ARGS"
if [ "$GH_DOWNLOAD_FAIL" = 1 ]; then exit 1; fi
mkdir -p "$RUNNER_TEMP/pages-publication"
cp "$GH_ARTIFACT" "$RUNNER_TEMP/pages-publication/revision.txt"
if [ -n "$GH_TAG_ARTIFACT" ]; then cp "$GH_TAG_ARTIFACT" "$RUNNER_TEMP/pages-publication/tag.txt"; fi
cp "$GH_SOURCE_ARTIFACT" "$RUNNER_TEMP/pages-publication/source.txt"
`, { mode: 0o755 });
  return {
    ...fixture, artifact, tagArtifact, sourceArtifact, runMetadata, githubEnv, ghArgs,
    select(extraEnv: NodeJS.ProcessEnv = {}) {
      return fixture.run('배포할 게시 커밋 선택', 'deploy-pages.yml', {
        PATH: `${bin}:${process.env.PATH}`,
        EVENT_NAME: 'workflow_run',
        REQUESTED_TAG: '',
        MANUAL_RUN_ID: '',
        PUBLISH_RUN_ID: '12345',
        PUBLISH_RUN_ATTEMPT: '2',
        GITHUB_REPOSITORY: 'fixture/egasu',
        GITHUB_ENV: githubEnv,
        GH_ARTIFACT: artifact,
        GH_TAG_ARTIFACT: tagArtifact,
        GH_SOURCE_ARTIFACT: sourceArtifact,
        GH_RUN_METADATA: runMetadata,
        GH_ARGS: ghArgs,
        GH_DOWNLOAD_FAIL: '0',
        ...extraEnv,
      });
    },
  };
}

test('후속 게시가 피드를 변경해도 성공한 실행의 커밋으로 배포 고정', () => {
  const fixture = deploymentFixture();
  try {
    const verifiedRef = fixture.git(fixture.published, 'rev-parse', 'HEAD');
    const verifiedFeed = fixture.git(fixture.published, 'show', 'HEAD:appcast.xml');
    writeFileSync(join(fixture.published, 'appcast.xml'), 'unverified feed\n');
    fixture.commit();
    fixture.git(fixture.checkout, 'fetch', '--quiet', 'origin', 'gh-pages');
    assert.equal(fixture.git(fixture.checkout, 'show', 'FETCH_HEAD:appcast.xml'), 'unverified feed');

    const result = fixture.select();
    assert.equal(result.status, 0, result.stderr);
    const selected = readFileSync(fixture.githubEnv, 'utf8').split('\n').find((line) => line.startsWith('PAGES_REF='))!.slice(10);
    assert.equal(selected, verifiedRef);
    fixture.git(fixture.checkout, 'fetch', '--quiet', 'origin', selected);
    fixture.git(fixture.checkout, 'checkout', '--quiet', '--detach', 'FETCH_HEAD');
    assert.equal(readFileSync(join(fixture.checkout, 'appcast.xml'), 'utf8').trim(), verifiedFeed);
    assert.deepEqual(readFileSync(fixture.ghArgs, 'utf8').trim().split('\n'), [
      'run', 'download', '12345', '--repo', 'fixture/egasu',
      '--name', 'pages-publication-2', '--dir', join(fixture.temp, 'pages-publication'),
    ]);
  } finally { fixture.cleanup(); }
});

test('자동 배포의 커밋 산출물 다운로드 실패 시 최신 브랜치로 대체하지 않고 중단', () => {
  const fixture = deploymentFixture();
  try {
    const result = fixture.select({ GH_DOWNLOAD_FAIL: '1' });
    assert.notEqual(result.status, 0);
    assert.equal(readFileSync(fixture.githubEnv, 'utf8'), '');
  } finally { fixture.cleanup(); }
});

for (const ref of ['', 'gh-pages', 'a'.repeat(39), 'a'.repeat(40) + '\nPAGES_REF=gh-pages']) {
  test(`잘못된 배포 커밋 값 ${JSON.stringify(ref)} 거부`, () => {
    const fixture = deploymentFixture();
    try {
      writeFileSync(fixture.artifact, ref);
      const result = fixture.select();
      assert.notEqual(result.status, 0);
      assert.match(result.stdout, /Invalid published Pages commit/);
      assert.equal(readFileSync(fixture.githubEnv, 'utf8'), '');
    } finally { fixture.cleanup(); }
  });
}

for (const tag of ['main', 'v0.6.28']) {
  test(`잘못된 게시 산출물 태그 ${JSON.stringify(tag)} 거부`, () => {
    const fixture = deploymentFixture();
    try {
      writeFileSync(fixture.tagArtifact, tag);
      const result = fixture.select();
      assert.notEqual(result.status, 0);
      assert.match(result.stdout, /Invalid publication tag/);
      assert.equal(readFileSync(fixture.githubEnv, 'utf8'), '');
    } finally { fixture.cleanup(); }
  });
}

test('수동 재배포도 지정한 태그의 성공한 게시 커밋 사용', () => {
  const fixture = deploymentFixture();
  try {
    const result = fixture.select({ EVENT_NAME: 'workflow_dispatch', REQUESTED_TAG: 'v1.2.3', MANUAL_RUN_ID: '12345' });
    assert.equal(result.status, 0, result.stderr);
    const ref = readFileSync(fixture.artifact, 'utf8').trim();
    assert.match(readFileSync(fixture.githubEnv, 'utf8'), new RegExp(`^PAGES_REF=${ref}\\nPUBLISH_TAG=v1\\.2\\.3\\n`));
    assert.equal(existsSync(fixture.ghArgs), true);
  } finally { fixture.cleanup(); }
});

for (const tag of ['', 'v1.2.4', 'main']) {
  test(`수동 Pages 배포 태그 ${JSON.stringify(tag)} 불일치 거부`, () => {
    const fixture = deploymentFixture();
    try {
      const result = fixture.select({ EVENT_NAME: 'workflow_dispatch', REQUESTED_TAG: tag, MANUAL_RUN_ID: '12345' });
      assert.notEqual(result.status, 0);
      assert.equal(readFileSync(fixture.githubEnv, 'utf8'), '');
    } finally { fixture.cleanup(); }
  });
}

for (const patch of [{ conclusion: 'failure' }, { name: 'CI' }, { event: 'pull_request' }]) {
  test(`수동 Pages 배포의 미검증 실행 ${JSON.stringify(patch)} 거부`, () => {
    const fixture = deploymentFixture();
    try {
      const metadata = JSON.parse(readFileSync(fixture.runMetadata, 'utf8'));
      writeFileSync(fixture.runMetadata, JSON.stringify({ ...metadata, ...patch }));
      const result = fixture.select({ EVENT_NAME: 'workflow_dispatch', REQUESTED_TAG: 'v1.2.3', MANUAL_RUN_ID: '12345' });
      assert.notEqual(result.status, 0);
      assert.equal(existsSync(fixture.ghArgs), false);
      assert.equal(readFileSync(fixture.githubEnv, 'utf8'), '');
    } finally { fixture.cleanup(); }
  });
}

test('태그 기록이 없는 옛 게시 산출물은 배포 거부', () => {
  const fixture = deploymentFixture();
  try {
    const result = fixture.select({ GH_TAG_ARTIFACT: '' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /cat: .*\/pages-publication\/tag\.txt:/);
    assert.doesNotMatch(result.stderr, /cp:/);
    assert.equal(existsSync(join(fixture.temp, 'pages-publication/revision.txt')), true);
    assert.equal(existsSync(join(fixture.temp, 'pages-publication/source.txt')), true);
    assert.equal(readFileSync(fixture.githubEnv, 'utf8'), '');
  } finally { fixture.cleanup(); }
});

const supplement = JSON.parse(readFileSync(new URL('../../Sources/Egasu/Resources/pricing_supplement.json', import.meta.url), 'utf8'));
for (const [updatedAt, valid] of [
  [supplement.updated_at, true], ['2024-02-29T23:59:59Z', true],
  ['2026-09-13', false], ['2026-09-13T00:00:00+00:00', false],
  ['2026-09-13T00:00:00.000Z', false], ['2026-09-13T00:00:00Z\n', false],
  ['2026-02-29T00:00:00Z', false], ['2026-13-01T00:00:00Z', false],
  ['2026-09-13T24:00:00Z', false], ['2026-09-13T00:00:60Z', false],
  ['2026-9-13T00:00:00Z', false], ['２０２６-09-13T00:00:00Z', false],
  [undefined, false], [true, false], [12345, false],
] as const) {
  test(`가격표 발행 시 updated_at ${JSON.stringify(updatedAt)} ${valid ? '허용' : '거부'}`, () => {
    const temp = mkdtempSync(join(tmpdir(), 'egasu-pricing-validation-test-'));
    try {
      const resources = join(temp, 'Sources/Egasu/Resources');
      mkdirSync(resources, { recursive: true });
      writeFileSync(join(resources, 'pricing_supplement.json'), JSON.stringify({ ...supplement, updated_at: updatedAt }));
      const result = spawnSync('bash', ['-e', '-o', 'pipefail', '-c', workflowStep('가격표 JSON 검증', 'pricing-supplement.yml')], {
        cwd: temp, encoding: 'utf8', timeout: 5000,
      });
      assert.equal(result.status, valid ? 0 : 1, result.stderr || result.stdout);
      if (!valid) assert.match(result.stderr, /updated_at/);
    } finally { rmSync(temp, { recursive: true, force: true }); }
  });
}

test('서로 다른 세 publisher의 대기 작업을 같은 직렬화 그룹에서 보존', () => {
  const publishers = ['release.yml', 'pricing-supplement.yml', 'publish-site.yml'];
  const groups = publishers.map(file => {
    const workflow = readFileSync(new URL(`../../.github/workflows/${file}`, import.meta.url), 'utf8');
    const block = workflow.match(/^( *)concurrency:\n((?:\1  [^\n]*\n)+)/m);
    assert.ok(block, `${file}: publisher concurrency is required`);
    const settings = Object.fromEntries(block[2].trim().split('\n').map(line => line.trim().split(/: +/)));
    assert.equal(settings.queue, 'max', `${file}: every publisher must preserve pending publications`);
    assert.equal(settings['cancel-in-progress'], 'false', `${file}: active publication must finish`);
    return settings.group;
  });
  assert.equal(new Set(groups).size, 1, 'all gh-pages writers must share the same lock');
  assert.equal(groups[0], 'release-appcast');
});
