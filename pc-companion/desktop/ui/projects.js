// A narrow local picker: discovery does not change the connector allowlist.
window.createProjectPicker = function ({ onSelect, isSelected, canSelect }) {
  const node = id => document.getElementById(id);
  const dialog = node('projectPicker'); let projects = []; let request = 0; let busy = false;
  const status = (text, error = false) => {
    node('projectPickerStatus').textContent = text;
    node('projectPickerStatus').classList.toggle('error', error);
  };
  const message = error => error.message.replace(/^Error invoking remote method '[^']+': (?:Error: )?/, '');
  function render() {
    const query = node('projectSearch').value.trim().toLowerCase();
    node('existingProjects').replaceChildren();
    const filtered = projects.filter(project => (project.name + '\n' + project.path).toLowerCase().includes(query));
    for (const project of filtered) {
      const button = document.createElement('button'); button.type = 'button'; button.className = 'project-option';
      const text = document.createElement('span'); text.className = 'project-text';
      const name = document.createElement('strong'); name.textContent = project.name;
      const detail = document.createElement('small'); detail.textContent = project.path;
      const source = document.createElement('small'); source.textContent = project.source;
      text.append(name, detail, source);
      const check = document.createElement('span'); check.className = 'project-check';
      check.textContent = isSelected(project.path) ? '已添加 ✓' : '选择';
      button.disabled = busy || isSelected(project.path); button.append(text, check);
      button.addEventListener('click', () => {
        try { if (!canSelect()) throw new Error('请先停止连接服务，再修改项目。'); onSelect(project); dialog.close(); }
        catch (error) { status(message(error), true); }
      });
      node('existingProjects').append(button);
    }
    if (query && !filtered.length && !busy) status('没有匹配的项目，可换个关键词或浏览文件夹。');
    else if (query && filtered.length) status(`找到 ${filtered.length} 个项目`);
  }
  async function load() {
    const current = ++request; busy = true; projects = []; render();
    node('refreshProjects').disabled = true; status('正在读取本机 Codex 项目…');
    try {
      const result = await window.companion.existingProjects();
      if (current !== request || !dialog.open) return;
      projects = result.projects; busy = false; render();
      status(result.warnings.length ? result.warnings.join(' ') : projects.length ?
        `可选择 ${projects.length} 个项目${result.truncated ? '（最近 200 个）' : ''}` : '尚未发现可用项目，点击下方浏览文件夹。');
    } catch (error) { if (current === request && dialog.open) status(message(error), true); }
    finally { if (current === request) { busy = false; node('refreshProjects').disabled = false; } }
  }
  node('closeProjects').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => { request++; busy = false; node('refreshProjects').disabled = false; });
  node('projectSearch').addEventListener('input', () => { status(`可选择 ${projects.length} 个项目`); render(); });
  node('refreshProjects').addEventListener('click', load);
  node('browseProject').addEventListener('click', async () => {
    if (!canSelect()) { status('请先停止连接服务，再修改项目。', true); return; }
    node('browseProject').disabled = true;
    try {
      const filename = await window.companion.choose('project');
      if (filename && dialog.open) {
        if (!canSelect()) throw new Error('请先停止连接服务，再修改项目。');
        onSelect({ path: filename, name: filename.split(/[/\\]/).filter(Boolean).pop() }); dialog.close();
      }
    } catch (error) { status(message(error), true); }
    finally { node('browseProject').disabled = false; }
  });
  return { open() { if (!canSelect() || dialog.open) return; node('projectSearch').value = ''; dialog.showModal(); void load(); } };
};
