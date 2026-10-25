// Source-level checks and document sync; does not build ArkUI or run on a device.
// node scripts/check_codex_help.cjs <typescript-module-path> [--write-docs]
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..');
const sourceFile = 'entry/src/main/ets/pages/codex/CodexHelpContent.ets';
const source = fs.readFileSync(path.join(root, sourceFile), 'utf8');
const out = ts.transpileModule(source, { fileName: 'CodexHelpContent.ts', compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS
}, reportDiagnostics: true });
assert.equal(out.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
const moduleData = { exports: {} };
vm.runInNewContext(out.outputText, { exports: moduleData.exports, module: moduleData });
const data = moduleData.exports;
const downloads = data.codexDownloads();
const guides = ['windows', 'macos', 'linux'].map(value => data.codexConnectionGuide(value));
guides.push(data.codexTailscaleGuide());
assert.equal(new Set(downloads.map(d => d.filename)).size, 5);
for (const d of downloads) {
  const url = new URL(d.url);
  assert.equal(url.protocol, 'https:');
  assert.equal(url.hostname, 'github.com');
  assert.equal(url.pathname, `/doulujiyao12/mobiinfra-oh/releases/download/${data.CODEX_BRIDGE_TAG}/${d.filename}`);
  assert.equal(url.search + url.hash + url.username + url.password, '');
  assert.ok(d.filename.includes(data.CODEX_BRIDGE_VERSION));
}
const manifestPath = path.join(root, `pc-companion/dist/${data.CODEX_BRIDGE_VERSION}-verified-bundles.json`);
if (fs.existsSync(manifestPath)) {
  const manifest = JSON.parse(fs.readFileSync(manifestPath));
  assert.equal(manifest.version, data.CODEX_BRIDGE_VERSION);
  assert.equal(JSON.stringify(downloads.map(d => d.filename).sort()), JSON.stringify(manifest.artifacts.map(a => a.file).sort()));
}
assert.equal(data.codexHelpSection('download'), 'download');
assert.equal(data.codexHelpSection('tailscale'), 'tailscale');
assert.equal(data.codexHelpSection('invalid'), 'connect');
assert.equal(data.codexHelpSection(''), 'connect');
assert.ok(guides.find(g => g.id === 'macos').notice.includes('Apple Silicon'));
assert.ok(guides.find(g => g.id === 'tailscale').notice.includes('卓易通'));
const linux = guides.find(g => g.id === 'linux');
const commands = linux.steps.map(step => step.command).join('\n');
for (const command of ['setup --project', ' login', ' start', ' status', 'pair --origin https://100.', '--output phone.', 'cat phone.']) {
  assert.ok(commands.includes(command), command);
}
const cli = fs.readFileSync(path.join(root, 'pc-companion/host/cli.mjs'), 'utf8');
for (const flag of ['--project', '--name', '--host', '--port', '--origin', '--output']) {
  assert.ok(cli.includes(`'${flag}'`), 'documented CLI flag exists: ' + flag);
}
const routes = JSON.parse(fs.readFileSync(path.join(root, 'entry/src/main/resources/base/profile/main_pages.json'))).src;
assert.ok(routes.includes('pages/codex/CodexHelpPage'));
const page = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/codex/CodexHelpPage.ets'), 'utf8');
assert.ok(page.includes('router.back()'));
assert.ok(page.includes('context.openLink(url)'));
assert.ok(page.includes('pasteboard.MIMETYPE_TEXT_PLAIN, value'));
assert.ok(!page.includes('CodexClient'), 'help must not reconnect or change device credentials');

// Native help and published Markdown are generated from the same content.
const folder = path.join(root, 'docs/codex');
const files = new Map();
for (const guide of guides) {
  const steps = guide.steps.map((s, i) => `## ${i + 1}. ${s.title}\n\n${s.body}\n` +
    (s.command ? `\n\`\`\`bash\n${s.command}\n\`\`\`\n` : '')).join('\n');
  const links = guide.links.filter(link => !link.url.includes('/docs/codex/')).map(link => `- [${link.title}](${link.url})`).join('\n');
  const markdown = `# ${guide.title}\n\n[返回下载与指南](README.md) · ClawMate Codex ${data.CODEX_BRIDGE_VERSION}\n\n` +
    `${guide.intro}\n\n> ${guide.notice}\n\n${steps}` +
    (guide.notes.length ? '\n## 常见问题与注意事项\n\n' + guide.notes.map(note => `- ${note}`).join('\n') + '\n' : '') +
    `\n## 相关链接\n\n${links}\n\n` +
    `<!-- 内容源：${sourceFile}；通过 scripts/check_codex_help.cjs --write-docs 同步。 -->\n`;
  files.set(guide.id + '.md', markdown);
}
const rows = downloads.map(d => `| ${d.title} | ${d.detail} | [下载](${d.url}) |`).join('\n');
const version = data.CODEX_BRIDGE_VERSION;
files.set('README.md', `# ClawMate Codex 连接器\n\n在手机中继续自己电脑或服务器上的 Codex 工作。电脑运行连接器，手机扫码或粘贴一次性配对信息。\n\n` +
  `## 下载 ${data.CODEX_BRIDGE_VERSION}\n\n| 平台 | 适用设备 | 安装包 |\n| --- | --- | --- |\n${rows}\n\n` +
  `[Release 与 SHA256 校验清单](${data.CODEX_RELEASE_URL})\n\n${data.CODEX_DOWNLOAD_NOTICE}\n\n` +
  `Windows 是安装向导；macOS ZIP 内为应用，解压后移入「应用程序」；Linux 为解压使用的便携包，服务器优先选 CLI。当前没有 Intel Mac、Linux ARM64、DMG、DEB 或 RPM 安装包。\n\n` +
  `## 连接指南\n\n- [Windows](windows.md)\n- [macOS · Apple Silicon](macos.md)\n- [Linux · CLI](linux.md)\n- [Tailscale：异地手机与服务器组网](tailscale.md)\n\n` +
  `手机入口：**Codex → 我的连接 → 下载 PC 端的 Codex 连接器 / 连接指南 / Tailscale 组网教程**。内置指南无需加载网页；下载文件和打开外部资料需要网络。\n\n` +
  `## 校验与升级\n\n从同一 Release 下载 SHA256SUMS.txt，核对对应文件的哈希，再安装或解压。\n\n` +
  `- Windows PowerShell：\`Get-FileHash .\\ClawMate-Codex-${version}-win-x64.exe -Algorithm SHA256\`\n` +
  `- macOS：\`shasum -a 256 ClawMate-Codex-${version}-darwin-arm64-unsigned.zip\`\n` +
  `- Linux：\`sha256sum ClawMate-Codex-Terminal-${version}-linux-x64.tar.gz\`\n\n` +
  `升级前先结束任务并退出旧后台；不要覆盖正在运行的解压目录。配置、手机配对和任务数据位于用户配置目录，替换程序通常无需重新配对。\n\n` +
  `更完整的能力及维护说明见 [电脑端使用指南](../../pc-companion/USER-GUIDE.md)。\n\n` +
  `<!-- 平台内容源：${sourceFile}；通过 scripts/check_codex_help.cjs --write-docs 同步。 -->\n`);
if (process.argv.includes('--write-docs')) fs.mkdirSync(folder, { recursive: true });
for (const [filename, content] of files) {
  const target = path.join(folder, filename);
  if (process.argv.includes('--write-docs')) fs.writeFileSync(target, content);
  assert.equal(fs.readFileSync(target, 'utf8').replaceAll('\r\n', '\n'), content, filename + ' is out of sync');
}
console.log('Codex help checks passed: 5 release packages, 4 native guides, CLI flags, route, and Markdown sync.');
