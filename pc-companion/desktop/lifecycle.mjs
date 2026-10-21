// Kept independent of Electron so cancel, shutdown races and failures are tested.
export class DesktopLifecycle {
  closing = false;
  choosing = null;
  constructor(actions) { this.actions = actions; }
  requestClose(allowHide = true) {
    if (this.closing) return Promise.resolve(false);
    if (this.choosing) return this.choosing;
    this.choosing = this.choose(allowHide).finally(() => { this.choosing = null; });
    return this.choosing;
  }
  async choose(allowHide) {
    const canHide = allowHide && this.actions.hasTray();
    const buttons = canHide ? ['隐藏窗口', '关闭应用', '取消'] : ['关闭应用', '取消'];
    const { response } = await this.actions.confirm({ type: 'question', title: '关闭 ClawMate Codex',
      message: canHide ? '隐藏窗口，还是关闭应用？' : '关闭 ClawMate Codex？',
      detail: canHide ? '隐藏窗口后，手机连接和电脑任务继续运行。关闭应用会断开手机连接并中断独立执行的任务；官方桌面端持有的共享任务继续运行。' :
        '关闭应用会断开手机连接并中断独立执行的任务；官方桌面端持有的共享任务继续运行。',
      buttons, defaultId: 0, cancelId: buttons.length - 1, noLink: true });
    if (canHide && response === 0) { this.actions.hide(); return false; }
    if (response !== (canHide ? 1 : 0)) return false;
    this.closing = true;
    try { await this.actions.shutdown(); this.actions.quit(); return true; }
    catch (error) {
      this.closing = false; this.actions.show();
      await this.actions.report(error); return false;
    }
  }
}
