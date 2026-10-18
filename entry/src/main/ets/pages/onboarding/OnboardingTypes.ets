/**
 * 首次安装引导页的稳定数据契约。
 *
 * 该文件只保存版本、持久化 key、页面文案和纯函数，不依赖 ArkUI 组件。
 * 这样 Index 只需要判断是否展示，引导页组件只负责渲染，单元测试也能直接覆盖
 * “以后不再出现”的版本化行为。
 */
export const FIRST_LAUNCH_ONBOARDING_STORAGE_KEY: string = 'firstLaunchOnboardingVersion';
export const FIRST_LAUNCH_ONBOARDING_VERSION: string = '2026-07-core-preview-usage-guide';

export const FIRST_LAUNCH_ONBOARDING_SLIDE_DATA_HOME: string = 'data_home';
export const FIRST_LAUNCH_ONBOARDING_SLIDE_AVATAR: string = 'avatar';
export const FIRST_LAUNCH_ONBOARDING_SLIDE_AGENT: string = 'agent';
export const FIRST_LAUNCH_ONBOARDING_SLIDE_USAGE_GUIDE: string = 'usage_guide';

export enum FirstLaunchOnboardingSlideKind {
  Preview = 'preview',
  UsageGuide = 'usage_guide'
}

export interface FirstLaunchOnboardingSlide {
  id: string;
  kind: FirstLaunchOnboardingSlideKind;
  title: string;
  description: string;
  mediaResourceName?: string;
  accentColor: string;
  softBackgroundColor: string;
}

export interface FirstLaunchUsageGuideItem {
  id: string;
  title: string;
  entryLabel: string;
  configLabel: string;
  description: string;
  iconText: string;
  accentColor: string;
  softBackgroundColor: string;
}

/**
 * 首次引导最后一页使用的功能入口清单，只描述使用与配置位置。
 * 这里不读取配置、不触发跳转、不申请权限，避免首次启动流程产生额外副作用。
 */
export const FIRST_LAUNCH_USAGE_GUIDE_ITEMS: FirstLaunchUsageGuideItem[] = [
  {
    id: 'usage_data_home',
    title: 'ClawMate',
    entryLabel: '使用入口：汇总',
    configLabel: '配置入口：设置 > 数据采集',
    description: '同步聊天、图库和位置线索，在汇总页查看整理后的个人事件。',
    iconText: 'D',
    accentColor: '#4F68FF',
    softBackgroundColor: '#EAF1FF'
  },
  {
    id: 'usage_avatar',
    title: '数字分身',
    entryLabel: '使用入口：首页',
    configLabel: '配置入口：模型与智能体 > 云端模型 > 更多设置',
    description: '基于个人画像和头像生成数字分身，用于问答、任务执行和长期陪伴。',
    iconText: 'A',
    accentColor: '#8066FF',
    softBackgroundColor: '#F1EEFF'
  },
  {
    id: 'usage_agent',
    title: '自动执行',
    entryLabel: '使用入口：聊天 / 任务',
    configLabel: '配置入口：设置 > 模型与智能体、任务与自动化',
    description: '配置 Planner、Decider 和 HDC 后，让 Agent 按目标规划并执行任务。',
    iconText: 'T',
    accentColor: '#18A886',
    softBackgroundColor: '#E9F8F3'
  }
];

export const FIRST_LAUNCH_ONBOARDING_SLIDES: FirstLaunchOnboardingSlide[] = [
  {
    id: FIRST_LAUNCH_ONBOARDING_SLIDE_DATA_HOME,
    kind: FirstLaunchOnboardingSlideKind.Preview,
    title: 'ClawMate',
    description: '汇总聊天、图库、任务和位置线索，让分散在各个 App 里的信息回到你的个人数据中心。',
    mediaResourceName: 'onboarding_data_home',
    accentColor: '#4F68FF',
    softBackgroundColor: '#EAF1FF'
  },
  {
    id: FIRST_LAUNCH_ONBOARDING_SLIDE_AVATAR,
    kind: FirstLaunchOnboardingSlideKind.Preview,
    title: '数字分身',
    description: '结合个人资料、头像和历史上下文，生成更懂你的助手，用于问答、陪伴和任务协作。',
    mediaResourceName: 'onboarding_avatar',
    accentColor: '#8066FF',
    softBackgroundColor: '#F1EEFF'
  },
  {
    id: FIRST_LAUNCH_ONBOARDING_SLIDE_AGENT,
    kind: FirstLaunchOnboardingSlideKind.Preview,
    title: '自动执行',
    description: '让 Agent 根据你的目标规划步骤、调用工具并执行任务，更准确，更懂你。',
    mediaResourceName: 'onboarding_agent',
    accentColor: '#18A886',
    softBackgroundColor: '#E9F8F3'
  },
  {
    id: FIRST_LAUNCH_ONBOARDING_SLIDE_USAGE_GUIDE,
    kind: FirstLaunchOnboardingSlideKind.UsageGuide,
    title: '开始使用',
    description: '三步建立你的个人智能助手：汇总数据，生成数字分身，最后 Agent 执行任务。',
    accentColor: '#4F68FF',
    softBackgroundColor: '#EAF1FF'
  }
];

export function shouldShowFirstLaunchOnboarding(storedVersion: string): boolean {
  return storedVersion !== FIRST_LAUNCH_ONBOARDING_VERSION;
}

export function isFirstLaunchOnboardingLastPage(index: number): boolean {
  return clampFirstLaunchOnboardingIndex(index) === FIRST_LAUNCH_ONBOARDING_SLIDES.length - 1;
}

export function firstLaunchOnboardingButtonText(index: number): string {
  return isFirstLaunchOnboardingLastPage(index) ? '进入首页' : '下一页';
}

export function clampFirstLaunchOnboardingIndex(index: number): number {
  if (index < 0) {
    return 0;
  }
  let maxIndex = FIRST_LAUNCH_ONBOARDING_SLIDES.length - 1;
  if (index > maxIndex) {
    return maxIndex;
  }
  return Math.floor(index);
}
