const $ = id => document.getElementById(id);
let snapshot; let projects = []; let dirty = false; let working = false;
const titles = { setup: '让手机连接你的开发电脑', pairing: '与自己的手机安全配对', devices: '设备和任务，一眼掌握', terminal: '你熟悉的终端，同样可用' };
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
$('addProject').addEventListener('click', () => act(async () => {
  const filename = await window.companion.choose('project'); if (!filename) return;
  if (projects.some(p => p.path === filename)) throw new Error('这个项目已经添加。');
  projects.push({ name: filename.split(/[/\\]/).filter(Boolean).pop(), path: filename }); dirty = true; renderProjects();
}));
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
