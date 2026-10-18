const path = require('node:path');
const fs = require('node:fs');
const target = process.env.CLAWMATE_BUILD_TARGET || `${process.platform}-${process.arch}`;
const root = __dirname;
const electronVersion = require('./package.json').devDependencies.electron;
// Extend the pinned builder's hooks, retaining its sandbox and AppArmor setup.
const hookDirectory = path.join(root, 'build', 'stage');
fs.mkdirSync(hookDirectory, { recursive: true });
for (const hook of ['after-install', 'after-remove']) {
  const upstream = path.join(path.dirname(require.resolve('app-builder-lib/package.json')), 'templates', 'linux', hook + '.tpl');
  fs.writeFileSync(path.join(hookDirectory, hook + '.sh'), fs.readFileSync(upstream, 'utf8') + '\n' +
    fs.readFileSync(path.join(root, 'build', hook + '.sh'), 'utf8'));
}
module.exports = {
  appId: 'com.clawmate.codex.companion', productName: 'ClawMate Codex', executableName: 'clawmate-codex-desktop',
  directories: { app: path.join(root, 'out', target, 'app'), output: path.join(root, 'dist', target) },
  files: ['**/*'], asar: true,
  electronVersion, npmRebuild: false,
  toolsets: { wine: '1.0.1' },
  ...(target === `${process.platform}-${process.arch}` ? { electronDist: path.join(root, 'node_modules', 'electron', 'dist') } : {}),
  extraResources: [{ from: path.join(root, 'out', target, 'resources'), to: '.' }],
  artifactName: 'ClawMate-Codex-${version}-${os}-${arch}.${ext}',
  publish: null,
  linux: { target: ['deb', 'tar.gz'], category: 'Development', maintainer: 'ClawMate',
    icon: path.resolve(root, '../AppScope/resources/base/media/Icon.png'),
    desktop: { entry: { Name: 'ClawMate Codex', Comment: 'Connect your HarmonyOS phone to Codex' } } },
  deb: { afterInstall: path.join(hookDirectory, 'after-install.sh'), afterRemove: path.join(hookDirectory, 'after-remove.sh') },
  win: { target: ['nsis'], signAndEditExecutable: process.env.CLAWMATE_UNSIGNED_TEST !== '1' },
  nsis: { oneClick: false, perMachine: false, allowToChangeInstallationDirectory: true,
    installerLanguages: ['en_US', 'zh_CN'],
    ...(process.platform !== 'win32' && process.env.CLAWMATE_UNSIGNED_TEST === '1' ?
      { script: path.join(root, 'build', 'development-installer.nsi') } : {}),
    createDesktopShortcut: true, createStartMenuShortcut: true, shortcutName: 'ClawMate Codex' },
  mac: { target: ['dmg', 'zip'], category: 'public.app-category.developer-tools',
    hardenedRuntime: true, notarize: process.env.CLAWMATE_NOTARIZE === '1',
    entitlements: path.join(root, 'build', 'entitlements.mac.plist'),
    entitlementsInherit: path.join(root, 'build', 'entitlements.mac.plist') }
};
