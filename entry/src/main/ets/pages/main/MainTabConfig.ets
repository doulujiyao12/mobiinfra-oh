export enum MainTabIndex {
  Home = 0,
  Summary = 1,
  Chat = 2,
  Task = 3,
  Mine = 4
}

export interface MainTabItem {
  index: MainTabIndex;
  icon: string;
  label: string;
}

// 使用 ASCII 资源名，避免 ArkTS $r 引用直接依赖中文文件名。
export const MAIN_TAB_ITEMS: MainTabItem[] = [
  { index: MainTabIndex.Home, icon: 'tab_home', label: '首页' },
  { index: MainTabIndex.Summary, icon: 'tab_summary', label: '汇总' },
  { index: MainTabIndex.Chat, icon: 'tab_chat', label: '聊天' },
  { index: MainTabIndex.Task, icon: 'tab_task', label: '任务' },
  { index: MainTabIndex.Mine, icon: 'tab_mine', label: '我的' }
];

export function centerTabIndex(): MainTabIndex {
  return MainTabIndex.Chat;
}

export function mainTabLabel(index: MainTabIndex): string {
  for (let i = 0; i < MAIN_TAB_ITEMS.length; i++) {
    if (MAIN_TAB_ITEMS[i].index === index) {
      return MAIN_TAB_ITEMS[i].label;
    }
  }
  return '';
}

export function mainTabIcon(index: MainTabIndex): string {
  for (let i = 0; i < MAIN_TAB_ITEMS.length; i++) {
    if (MAIN_TAB_ITEMS[i].index === index) {
      return MAIN_TAB_ITEMS[i].icon;
    }
  }
  return '';
}
