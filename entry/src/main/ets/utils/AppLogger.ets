import { hilog } from '@kit.PerformanceAnalysisKit';
import { DebugSettings } from './DebugSettings';

const APP_LOG_DOMAIN: number = 0x0000;
const APP_LOG_TAG: string = 'MobiInfra';
const APP_LOG_PREFIX: string = 'MobiInfra';

export interface AppLogStructuredCause {
  code?: number | string;
  message?: string;
  name?: string;
}

export type AppLogCause = Error | AppLogStructuredCause | string;

function normalizeModuleName(moduleName: string): string {
  let normalizedModule = moduleName.trim();
  if (normalizedModule.length === 0) {
    normalizedModule = 'App';
  }
  return normalizedModule;
}

function formatMessage(moduleName: string, message: string): string {
  let normalizedModule = normalizeModuleName(moduleName);
  return '[' + APP_LOG_PREFIX + '][' + normalizedModule + '] ' + message;
}

function formatCause(cause: AppLogCause): string {
  if (typeof cause === 'string') {
    return cause;
  }
  if (cause instanceof Error) {
    let errorName = cause.name;
    let normalizedName = errorName.length > 0 ? errorName : 'Error';
    let errorMessage = cause.message;
    if (errorMessage.length > 0) {
      return normalizedName + ': ' + errorMessage;
    }
    return normalizedName;
  }
  let parts: string[] = [];
  let causeName = cause.name;
  if (causeName !== undefined && causeName.length > 0) {
    parts.push(causeName);
  }
  let causeCode = cause.code;
  if (causeCode !== undefined) {
    parts.push('code=' + String(causeCode));
  }
  let causeMessage = cause.message;
  if (causeMessage !== undefined && causeMessage.length > 0) {
    parts.push('message=' + causeMessage);
  }
  if (parts.length > 0) {
    return parts.join(', ');
  }
  return 'structured cause without detail';
}

function formatMessageWithCause(message: string, cause: AppLogCause): string {
  return message + ': ' + formatCause(cause);
}

// 统一封装 Hilog 输出，保证所有模块在系统日志中都有相同 tag 和模块前缀。
export class AppLogger {
  static debug(moduleName: string, message: string): void {
    if (!DebugSettings.isEnabled()) { return; }
    hilog.debug(APP_LOG_DOMAIN, APP_LOG_TAG, '%{public}s', formatMessage(moduleName, message));
  }

  static info(moduleName: string, message: string): void {
    if (!DebugSettings.isEnabled()) { return; }
    hilog.info(APP_LOG_DOMAIN, APP_LOG_TAG, '%{public}s', formatMessage(moduleName, message));
  }

  static warn(moduleName: string, message: string): void {
    if (!DebugSettings.isEnabled()) { return; }
    hilog.warn(APP_LOG_DOMAIN, APP_LOG_TAG, '%{public}s', formatMessage(moduleName, message));
  }

  static error(moduleName: string, message: string): void {
    if (!DebugSettings.isEnabled()) { return; }
    hilog.error(APP_LOG_DOMAIN, APP_LOG_TAG, '%{public}s', formatMessage(moduleName, message));
  }

  static warnCause(moduleName: string, message: string, cause: AppLogCause): void {
    AppLogger.warn(moduleName, formatMessageWithCause(message, cause));
  }

  static errorCause(moduleName: string, message: string, cause: AppLogCause): void {
    AppLogger.error(moduleName, formatMessageWithCause(message, cause));
  }

  static forModule(moduleName: string): AppModuleLogger {
    return new AppModuleLogger(moduleName);
  }
}

export class AppModuleLogger {
  private moduleName: string;

  constructor(moduleName: string) {
    this.moduleName = normalizeModuleName(moduleName);
  }

  debug(message: string): void {
    AppLogger.debug(this.moduleName, message);
  }

  info(message: string): void {
    AppLogger.info(this.moduleName, message);
  }

  warn(message: string): void {
    AppLogger.warn(this.moduleName, message);
  }

  error(message: string): void {
    AppLogger.error(this.moduleName, message);
  }

  warnCause(message: string, cause: AppLogCause): void {
    AppLogger.warnCause(this.moduleName, message, cause);
  }

  errorCause(message: string, cause: AppLogCause): void {
    AppLogger.errorCause(this.moduleName, message, cause);
  }
}

export function appLogDebug(moduleName: string, message: string): void {
  AppLogger.debug(moduleName, message);
}

export function appLogInfo(moduleName: string, message: string): void {
  AppLogger.info(moduleName, message);
}

export function appLogWarn(moduleName: string, message: string): void {
  AppLogger.warn(moduleName, message);
}

export function appLogError(moduleName: string, message: string): void {
  AppLogger.error(moduleName, message);
}

export function appLogWarnCause(moduleName: string, message: string, cause: AppLogCause): void {
  AppLogger.warnCause(moduleName, message, cause);
}

export function appLogErrorCause(moduleName: string, message: string, cause: AppLogCause): void {
  AppLogger.errorCause(moduleName, message, cause);
}

export function appLogMessageForTest(moduleName: string, message: string): string {
  return formatMessage(moduleName, message);
}

export function appLogCauseTextForTest(message: string, cause: AppLogCause): string {
  return formatMessageWithCause(message, cause);
}
