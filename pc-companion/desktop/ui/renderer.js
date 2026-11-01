const $ = id => document.getElementById(id);
let snapshot; let projects = []; let dirty = false; let working = false;
const titles = { setup: '让手机连接你的开发电脑', pairing: '与自己的手机安全配对', devices: '设备和任务，一眼掌握', terminal: '你熟悉的终端，同样可用', updates: '保持最新，继续协作' };
function notice(message, error = false) { $('notice').textContent = message; $('notice').hidden = !message; $('notice').classList.toggle('error', error); }
function errorText(error) { return error.message.replace(/^Error invoking remote method '[^']+': (?:Error: )?/, ''); }
async function act(action) {
  if (working) return; working = true;
  try { await action(); await refresh(); }
  catch (error) { notice(errorText(error), true); }
  finally { working = false; }
}
function view(name) {
  for (const section of document.querySelectorAll('.view')) section.hidden = section.id !== name;
  for (const button of document.querySelectorAll('.nav')) button.classList.toggle('active', button.dataset.view === name);
  $('pageTitle').textContent = titles[name];
}
for (const button of document.querySelectorAll('.nav')) button.addEventListener('click', () => view(button.dataset.view));
function row(title, subtitle, label, action) {
  const div = document.createElement('div'); div.className = 'item-row';
  const text = document.createElement('div'); const strong = document.createElement('strong'); strong.textContent = title;
  const small = document.createElement('small'); small.textContent = subtitle; text.append(strong, small); div.append(text);
  if (label) { const button = document.createElement('button'); button.textContent = label; button.addEventListener('click', () => act(action)); div.append(button); }
  return div;
}
function renderProjects() {
  $('projects').replaceChildren();
  if (!projects.length) { const p = document.createElement('p'); p.textContent = '还没有选择项目，点击右侧按钮添加。'; $('projects').append(p); }
  projects.forEach((project, index) => $('projects').append(row(project.name, project.path, '移除', async () => {
    projects.splice(index, 1); dirty = true; renderProjects();
  })));
}
function formConfig() {
  return { name: $('computerName').value, port: Number($('port').value), host: $('host').value,
    networkMode: $('networkMode').value, publicOrigin: $('publicOrigin').value,
    certFile: $('certFile').value, keyFile: $('keyFile').value, workspaces: projects };
}
async function refresh() {
  snapshot = await window.companion.call('status');
  document.querySelector('.version').textContent = 'v' + snapshot.version;
  const running = snapshot.state === 'running';
  $('sideState').textContent = running ? '手机连接服务已启动' : snapshot.state === 'error' ? '服务需要检查' : '手机连接服务未启动';
  $('sideDot').classList.toggle('running', running);
  const account = snapshot.account;
  $('accountBadge').textContent = account ? '已登录' : '尚未登录'; $('accountBadge').classList.toggle('good', !!account);
  $('accountDescription').textContent = account ? [account.email || account.type, account.planType].filter(Boolean).join(' · ') : '内置 Codex 运行组件，无需安装 Node.js 或其他命令行工具。';
  $('start').disabled = running; $('stop').disabled = !running; $('save').disabled = running; $('addProject').disabled = running;
  $('login').disabled = !!account; $('deviceLogin').disabled = !!account; $('logout').disabled = !account || running;
  if (snapshot.login?.success) $('loginCode').hidden = true;
  if (!dirty) {
    for (const [key, id] of [['name', 'computerName'], ['port', 'port'], ['host', 'host'], ['networkMode', 'networkMode'], ['publicOrigin', 'publicOrigin'], ['certFile', 'certFile'], ['keyFile', 'keyFile']]) $(id).value = snapshot.config[key] || '';
    projects = snapshot.config.workspaces.map(p => ({ ...p })); renderProjects();
  }
  $('publicSettings').hidden = $('networkMode').value !== 'public';
  const selected = $('origin').value; $('origin').replaceChildren();
  for (const origin of snapshot.origins) { const option = document.createElement('option'); option.value = origin; option.textContent = origin; $('origin').append(option); }
  if (snapshot.origins.includes(selected)) $('origin').value = selected;
  $('generatePairing').disabled = !running || !snapshot.origins.length;
  $('fingerprint').textContent = snapshot.fingerprint || '公网模式使用系统受信任证书；局域网启动后显示本机配对证书指纹。';
  $('launcherPath').textContent = snapshot.launcher; $('dataPath').textContent = snapshot.dataDirectory;
  $('deviceList').replaceChildren();
  for (const device of snapshot.devices) $('deviceList').append(row(device.name, new Date(device.createdAt).toLocaleString(), '撤销连接', async () => {
    await window.companion.call('revoke', { id: device.id }); notice('已撤销该设备的连接权限。');
  }));
  if (!snapshot.devices.length) $('deviceList').textContent = '暂无配对设备。';
  $('taskList').replaceChildren();
  const statuses = { completed: '已完成', running: '执行中', starting: '正在提交', waitingApproval: '等待手机确认', interrupted: '已中断', failed: '失败', idle: '等待任务', stopping: '正在停止', releasing: '保存并释放会话' };
  for (const task of snapshot.tasks.slice(0, 20)) $('taskList').append(row(task.title, `${statuses[task.status] || task.status} · ${task.model}`,
    ['running', 'starting', 'waitingApproval'].includes(task.status) ? '停止任务' : '', async () => { await window.companion.call('interrupt', { id: task.id }); }));
  if (!snapshot.tasks.length) $('taskList').textContent = '手机发送的任务会在这里显示。';
}
for (const id of ['computerName', 'port', 'host', 'networkMode', 'publicOrigin']) $(id).addEventListener('input', () => { dirty = true; $('publicSettings').hidden = $('networkMode').value !== 'public'; });
let projectPicker;
$('addProject').addEventListener('click', () => {
  projectPicker ||= window.createProjectPicker({ canSelect: () => !working && !!snapshot && snapshot.state !== 'running',
    isSelected: filename => projects.some(p => p.path === filename),
    onSelect: project => {
      if (projects.some(p => p.path === project.path)) throw new Error('这个项目已经添加。');
      if (projects.length >= 20) throw new Error('最多配置 20 个项目，请先移除不需要的项目。');
      projects.push({ name: project.name.slice(0, 80), path: project.path }); dirty = true; renderProjects();
      notice('项目已添加，请保存设置以完成授权。');
    } });
  projectPicker.open();
});
for (const [id, kind, target] of [['chooseCert', 'cert', 'certFile'], ['chooseKey', 'key', 'keyFile']]) $(id).addEventListener('click', () => act(async () => { const filename = await window.companion.choose(kind); if (filename) { $(target).value = filename; dirty = true; } }));
$('save').addEventListener('click', () => act(async () => { await window.companion.call('configure', formConfig()); dirty = false; notice('配置已保存。'); }));
$('start').addEventListener('click', () => act(async () => {
  if (dirty) { await window.companion.call('configure', formConfig()); dirty = false; }
  notice('正在启动内置 Codex 和安全连接…'); await window.companion.call('start'); notice('连接服务已启动，接下来在“手机配对”中连接自己的手机。'); view('pairing');
}));
$('stop').addEventListener('click', () => act(async () => { await window.companion.call('stop'); $('pairingResult').hidden = true; notice('手机连接服务已停止。'); }));
for (const [id, type] of [['login', 'chatgpt'], ['deviceLogin', 'chatgptDeviceCode']]) $(id).addEventListener('click', () => act(async () => {
  const result = await window.companion.call('login', { type });
  $('loginCode').hidden = false;
  $('loginCode').textContent = result.userCode ? `在已打开的官方页面输入验证码：${result.userCode}\n${result.verificationUrl}` : '已在系统浏览器打开官方登录页面，完成后会自动更新登录状态。';
}));
$('logout').addEventListener('click', () => act(async () => { await window.companion.call('logout'); notice('已退出 Codex 账号。'); }));
$('generatePairing').addEventListener('click', () => act(async () => {
  const result = await window.companion.call('pair', { origin: $('origin').value });
  $('pairingResult').hidden = false; $('pairingQr').src = result.qr;
  $('pairingExpiry').textContent = `有效至 ${new Date(result.expiresAt).toLocaleTimeString()} · 仅可使用一次`;
  notice('配对信息已生成。请导出文件给自己的手机，或复制配对内容。');
}));
$('exportPairing').addEventListener('click', () => act(async () => { if (await window.companion.exportPairing()) notice('配对文件已导出，请在 5 分钟内在手机 Codex 页面导入。'); }));
$('copyPairing').addEventListener('click', () => act(async () => { await window.companion.copyPairing(); notice('一次性配对信息已复制，请仅发送给自己的手机。'); }));
$('installTerminal').addEventListener('click', () => act(async () => notice(await window.companion.installTerminal())));
$('resetPairing').addEventListener('click', () => act(async () => { if (await window.companion.resetPairing()) { $('pairingResult').hidden = true; notice('配对已重置，请启动连接服务后重新配对手机。'); } }));
$('autoStart').addEventListener('change', () => act(async () => { await window.companion.autoStart($('autoStart').checked); notice('开机启动设置已更新。'); }));
$('shutdown').addEventListener('click', () => act(() => window.companion.shutdown()));
refresh().catch(error => notice('本机服务启动失败：' + errorText(error), true));
setInterval(() => { if (!working) refresh().catch(error => notice(errorText(error), true)); }, 3000);

let updateState;
function renderUpdate(state) {
  updateState = state;
  const downloading = state.phase === 'downloading'; const checking = state.phase === 'checking'; const installing = state.phase === 'installing';
  const ready = state.phase === 'ready'; const labels = { idle: '等待检查', checking: '正在检查', latest: '当前已是最新可用版本', available: '发现新版本', downloading: '正在下载', ready: '下载完成', installing: '正在准备安装', error: '检查未完成' };
  $('updateVersion').textContent = `当前版本 ${state.currentVersion}` + (state.hasUpdate ? ` · 新版本 ${state.latestVersion}` : '');
  $('updateBadge').textContent = labels[state.phase] || '应用更新';
  $('updateBadge').classList.toggle('good', ready || state.phase === 'latest');
  $('updateMessage').textContent = installing ? '正在安全退出连接服务，配对与项目配置会保留。' : downloading ? `正在下载 ${state.latestVersion}，可暂停后继续。` : ready ? '更新已下载并通过完整性校验。' : state.hasUpdate ? `发现 ClawMate Codex ${state.latestVersion}` : state.phase === 'latest' ? 'GitHub 上暂时没有更高版本的匹配发布。' : '自动检查连接器的 GitHub Release，不影响手机任务。';
  $('updateProgress').hidden = !downloading; $('updateProgress').value = state.progress;
  $('updateBytes').hidden = !downloading;
  $('updateBytes').textContent = `${state.progress}% · ${(state.downloadedBytes / 1048576).toFixed(1)} / ${(state.totalBytes / 1048576).toFixed(1)} MB`;
  $('updateError').hidden = !state.error; $('updateError').textContent = state.error || '';
  $('updateNotes').hidden = !state.notes; $('updateNotes').textContent = state.notes || '';
  $('checkUpdate').disabled = checking || downloading || installing;
  $('checkUpdate').textContent = checking ? '正在检查…' : '检查更新';
  $('downloadUpdate').hidden = !state.hasUpdate || ready || downloading || checking || installing;
  $('pauseUpdate').hidden = !downloading;
  $('installUpdate').hidden = !ready || !state.canInstall; $('openUpdate').hidden = !ready || state.canInstall;
  $('autoCheckUpdates').checked = state.autoCheck; $('previewUpdates').checked = state.channel === 'preview';
  $('autoCheckUpdates').disabled = $('previewUpdates').disabled = checking || downloading || installing;
  $('updateManual').hidden = !state.hasUpdate || state.canInstall;
  $('updateManual').textContent = state.platform === 'darwin' ? '当前 Mac 包未签名：下载后打开安装文件，退出旧连接器并将新应用移入“应用程序”。配对信息会保留。' : '此安装方式需要打开下载包后手动替换程序，保留原有应用数据目录即可。';
  $('updateBanner').hidden = !state.hasUpdate || state.ignoredVersion === state.latestVersion; $('updateDot').hidden = !state.hasUpdate;
  $('updateBannerText').textContent = ready ? `版本 ${state.latestVersion} 已就绪` : `ClawMate Codex ${state.latestVersion} 可更新`;
}
async function updateAction(method, body) {
  try { renderUpdate(await window.companion.updates(method, body)); }
  catch (error) { $('updateError').hidden = false; $('updateError').textContent = errorText(error); }
}
$('viewUpdate').addEventListener('click', () => view('updates'));
for (const [id, method] of [['checkUpdate', 'check'], ['downloadUpdate', 'download'], ['pauseUpdate', 'cancel'], ['installUpdate', 'install'], ['openUpdate', 'open'], ['releasePage', 'release'], ['laterUpdate', 'later']]) {
  $(id).addEventListener('click', () => updateAction(method));
}
for (const id of ['autoCheckUpdates', 'previewUpdates']) $(id).addEventListener('change', () => updateAction('configure', {
  autoCheck: $('autoCheckUpdates').checked, channel: $('previewUpdates').checked ? 'preview' : 'stable'
}));
window.companion.onUpdate(renderUpdate);
window.companion.updates('status').then(renderUpdate).catch(() => {});
setInterval(() => { if (!updateState) window.companion.updates('status').then(renderUpdate).catch(() => {}); }, 1000);
