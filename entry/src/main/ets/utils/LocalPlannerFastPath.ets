export type LocalPlannerMatchKind = 'app_name' | 'package_name';

export interface LocalPlannerFastPathMatch {
  appName: string;
  packageName: string;
  matchedText: string;
  matchedBy: LocalPlannerMatchKind;
}

interface PlannerAppEntry {
  appName: string;
  packageName: string;
  promptOrder: number;
}

interface PlannerMatchCandidate {
  entry: PlannerAppEntry;
  matchedText: string;
  matchedBy: LocalPlannerMatchKind;
  taskIndex: number;
}

const PACKAGE_AT_LINE_END_PATTERN: RegExp = /([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)\s*$/;
const CONTEXT_REQUIRED_APP_NAMES: string[] = ['信息', '设置'];
const EXPLICIT_APP_PREFIXES: string[] = ['打开', '启动', '进入', '前往', '切换到', '在', '用', '使用', '通过', '查看'];
const EXPLICIT_APP_SUFFIXES: string[] = ['app', '应用', '中', '里', '内', '上'];

/**
 * Resolves an explicitly mentioned App from the application list in the Planner prompt.
 * This helper only performs text matching; the caller decides which execution mode may use it.
 */
export class LocalPlannerFastPath {
  static match(task: string, plannerPrompt: string): LocalPlannerFastPathMatch | null {
    let normalizedTask = task.trim().toLowerCase();
    if (normalizedTask.length === 0 || plannerPrompt.trim().length === 0) {
      return null;
    }

    let entries = LocalPlannerFastPath.parsePlannerApps(plannerPrompt);
    let best: PlannerMatchCandidate | null = null;
    for (let entry of entries) {
      let normalizedPackageName = entry.packageName.toLowerCase();
      let packageIndex = normalizedTask.indexOf(normalizedPackageName);
      if (packageIndex >= 0) {
        let packageCandidate: PlannerMatchCandidate = {
          entry: entry,
          matchedText: entry.packageName,
          matchedBy: 'package_name',
          taskIndex: packageIndex
        };
        best = LocalPlannerFastPath.betterCandidate(best, packageCandidate);
      }

      let normalizedAppName = entry.appName.toLowerCase();
      let appIndex = normalizedTask.indexOf(normalizedAppName);
      if (appIndex >= 0 && LocalPlannerFastPath.isAppNameMatchAllowed(normalizedTask, normalizedAppName, appIndex)) {
        let appCandidate: PlannerMatchCandidate = {
          entry: entry,
          matchedText: entry.appName,
          matchedBy: 'app_name',
          taskIndex: appIndex
        };
        best = LocalPlannerFastPath.betterCandidate(best, appCandidate);
      }
    }

    if (best === null) {
      return null;
    }
    let result: LocalPlannerFastPathMatch = {
      appName: best.entry.appName,
      packageName: best.entry.packageName,
      matchedText: best.matchedText,
      matchedBy: best.matchedBy
    };
    return result;
  }

  private static parsePlannerApps(plannerPrompt: string): PlannerAppEntry[] {
    let entries: PlannerAppEntry[] = [];
    let lines = plannerPrompt.replace(/\r/g, '').split('\n');
    let insideAppList = false;
    for (let line of lines) {
      let trimmed = line.trim();
      if (trimmed.startsWith('##')) {
        let normalizedHeading = trimmed.toLowerCase();
        let isAppListHeading = trimmed.indexOf('可用应用列表') >= 0 ||
          normalizedHeading.indexOf('available app') >= 0;
        if (insideAppList && !isAppListHeading) {
          break;
        }
        insideAppList = isAppListHeading;
        continue;
      }
      if (!insideAppList) {
        continue;
      }
      if (!trimmed.startsWith('-')) {
        continue;
      }
      let packageMatch: RegExpExecArray | null = PACKAGE_AT_LINE_END_PATTERN.exec(trimmed);
      if (packageMatch === null || packageMatch.index <= 1) {
        continue;
      }
      let appName = trimmed.substring(1, packageMatch.index).trim();
      appName = LocalPlannerFastPath.removeTrailingSeparator(appName);
      let packageName = packageMatch[1].trim();
      if (appName.length === 0 || packageName.length === 0) {
        continue;
      }
      let entry: PlannerAppEntry = {
        appName: appName,
        packageName: packageName,
        promptOrder: entries.length
      };
      entries.push(entry);
    }
    return entries;
  }

  private static removeTrailingSeparator(value: string): string {
    let normalized = value.trim();
    while (normalized.endsWith(':') || normalized.endsWith('：')) {
      normalized = normalized.substring(0, normalized.length - 1).trim();
    }
    return normalized;
  }

  private static isAppNameMatchAllowed(task: string, appName: string, taskIndex: number): boolean {
    if (CONTEXT_REQUIRED_APP_NAMES.indexOf(appName) < 0) {
      return true;
    }
    let prefixStart = Math.max(0, taskIndex - 4);
    let prefix = task.substring(prefixStart, taskIndex);
    let suffix = task.substring(taskIndex + appName.length);
    for (let explicitPrefix of EXPLICIT_APP_PREFIXES) {
      if (prefix.endsWith(explicitPrefix)) {
        return true;
      }
    }
    for (let explicitSuffix of EXPLICIT_APP_SUFFIXES) {
      if (suffix.startsWith(explicitSuffix)) {
        return true;
      }
    }
    return false;
  }

  private static betterCandidate(current: PlannerMatchCandidate | null,
    candidate: PlannerMatchCandidate): PlannerMatchCandidate {
    if (current === null) {
      return candidate;
    }
    let currentKindPriority = LocalPlannerFastPath.matchKindPriority(current.matchedBy);
    let candidateKindPriority = LocalPlannerFastPath.matchKindPriority(candidate.matchedBy);
    if (candidateKindPriority !== currentKindPriority) {
      return candidateKindPriority > currentKindPriority ? candidate : current;
    }
    if (candidate.matchedText.length !== current.matchedText.length) {
      return candidate.matchedText.length > current.matchedText.length ? candidate : current;
    }
    if (candidate.taskIndex !== current.taskIndex) {
      return candidate.taskIndex < current.taskIndex ? candidate : current;
    }
    return candidate.entry.promptOrder < current.entry.promptOrder ? candidate : current;
  }

  private static matchKindPriority(kind: LocalPlannerMatchKind): number {
    return kind === 'package_name' ? 2 : 1;
  }
}
