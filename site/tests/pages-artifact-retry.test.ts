import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';

function deploymentJobs() {
  const workflow = readFileSync(new URL('../../.github/workflows/deploy-pages.yml', import.meta.url), 'utf8');
  const [beforeDeploy, deploy] = workflow.split('\n  deploy:\n');
  const prepare = beforeDeploy.split('\n  prepare:\n')[1];
  assert.ok(prepare, 'Pages upload must run in a separate preparation job');
  assert.ok(deploy, 'Pages deployment job must consume the preparation output');
  return { prepare, deploy };
}

test('실패한 Pages 배포만 재시도하면 이전 업로드의 시도별 이름 재사용', () => {
  const { prepare, deploy } = deploymentJobs();
  assert.match(prepare, /uses: actions\/upload-pages-artifact@v5/);
  assert.doesNotMatch(prepare, /uses: actions\/deploy-pages@/);
  assert.match(deploy, /needs: prepare/);
  assert.doesNotMatch(deploy, /uses: actions\/upload-pages-artifact@/);
  assert.match(prepare, /PAGES_ARTIFACT_NAME: github-pages-\$\{\{ github.run_attempt \}\}/);
  assert.match(prepare, /artifact_name: \$\{\{ env.PAGES_ARTIFACT_NAME \}\}/);
  assert.match(prepare, /uses: actions\/upload-pages-artifact@v5\n        with:\n          name: \$\{\{ env.PAGES_ARTIFACT_NAME \}\}/);
  assert.match(deploy, /artifact_name: \$\{\{ needs.prepare.outputs.artifact_name \}\}/);
  assert.doesNotMatch(deploy, /github.run_attempt/);
});

test('Pages 배포 재시도도 선택한 게시 커밋의 태그와 보호 기준 재검증', () => {
  const { prepare, deploy } = deploymentJobs();
  for (const [output, variable] of [
    ['pages_ref', 'PAGES_REF'],
    ['publish_tag', 'PUBLISH_TAG'],
    ['publish_source_sha', 'PUBLISH_SOURCE_SHA'],
  ]) {
    assert.ok(prepare.includes(`${output}: \${{ env.${variable} }}`));
    assert.ok(deploy.includes(`${variable}: \${{ needs.prepare.outputs.${output} }}`));
  }
  assert.match(prepare, /ref: \$\{\{ env.PAGES_REF \}\}\n          fetch-depth: 0/);
  assert.match(deploy, /ref: \$\{\{ env.PAGES_REF \}\}\n          fetch-depth: 0/);
  const tagCheck = deploy.indexOf('- name: 게시 원본 태그 확인');
  const checkpoint = deploy.indexOf('- name: 과거 Pages 배포 차단');
  const publication = deploy.indexOf('- name: GitHub Pages 배포');
  assert.ok(tagCheck >= 0 && checkpoint > tagCheck && publication > checkpoint);
  assert.ok(deploy.includes("      - name: GitHub Pages 배포\n        if: steps.revision.outputs.deploy == 'true'"));
});
