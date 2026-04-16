import { AbilityConstant, ConfigurationConstant, UIAbility, Want, wantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private floatWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // Initialize floating window text for @StorageLink binding
    AppStorage.setOrCreate('floatText', 'AI Agent 运行中...');
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    this.destroyFloatWindow();
    try {
      // 当应用回到前台，停止后台长时任务，省电
      backgroundTaskManager.stopBackgroundRunning(this.context).then(() => {
        hilog.info(DOMAIN, 'testTag', 'stopBackgroundRunning succeeded');
      }).catch((err: Error) => {
        hilog.info(DOMAIN, 'testTag', 'stopBackgroundRunning failed Cause: ' + JSON.stringify(err));
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'stopBackgroundRunning error');
    }
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    this.createFloatWindow();
    try {
      // 配置 WantAgent，用于在通知栏显示后台任务并能点击回到应用
      let wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: "com.example.mnnllmchat",
            abilityName: "EntryAbility"
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };

      wantAgent.getWantAgent(wantAgentInfo).then((wantAgentObj) => {
        // 当应用退到后台时，立刻向系统申请数据传输类的长时运行权限
        backgroundTaskManager.startBackgroundRunning(this.context,
          backgroundTaskManager.BackgroundMode.DATA_TRANSFER, wantAgentObj).then(() => {
          hilog.info(DOMAIN, 'testTag', 'startBackgroundRunning succeeded');
        }).catch((err: Error) => {
          hilog.error(DOMAIN, 'testTag', 'startBackgroundRunning failed Cause: ' + JSON.stringify(err));
        });
      });
    } catch (error) {
      hilog.error(DOMAIN, 'testTag', 'startBackgroundRunning error Cause: ' + JSON.stringify(error));
    }
  }

  private createFloatWindow() {
    if (this.floatWindow) {
      this.floatWindow.showWindow();
      return;
    }
    let config: window.Configuration = {
      name: 'MnnLlmChatFloatWindow',
      windowType: window.WindowType.TYPE_FLOAT,
      ctx: this.context
    };

    window.createWindow(config).then((win: window.Window) => {
      this.floatWindow = win;
      win.resize(300, 100);
      win.moveWindowTo(100, 100);
      win.setUIContent('pages/FloatWindow', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load float window content. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        win.showWindow();
        hilog.info(DOMAIN, 'testTag', 'Float window created and shown');
      });
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'Failed to create float window. Cause: ' + JSON.stringify(err));
    });
  }

  private destroyFloatWindow() {
    if (this.floatWindow) {
      this.floatWindow.destroyWindow().then(() => {
        hilog.info(DOMAIN, 'testTag', 'Float window destroyed');
        this.floatWindow = null;
      }).catch((err: Error) => {
        hilog.error(DOMAIN, 'testTag', 'Failed to destroy float window. Cause: ' + JSON.stringify(err));
      });
    }
  }
}
