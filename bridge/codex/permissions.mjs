import { BridgeError } from './errors.mjs';

export function executionSettings(input, fallback = {}) {
  const mode = input.mode !== undefined ? input.mode : fallback.mode ?? 'workspace-write';
  const approvalMode = input.approvalMode !== undefined ? input.approvalMode : fallback.approvalMode ?? 'ask';
  if (!['read-only', 'workspace-write', 'danger-full-access'].includes(mode)) throw new BridgeError(400, 'Invalid sandbox mode');
  if (!['ask', 'auto', 'full'].includes(approvalMode)) throw new BridgeError(400, 'Invalid approval mode');
  // Full access must be an explicit, consistent choice. Never infer it from a
  // raw approvalPolicy, reviewer, permission profile or arbitrary client config.
  if ((mode === 'danger-full-access') !== (approvalMode === 'full')) throw new BridgeError(400, 'Full access requires an explicit matching sandbox and approval selection');
  return { mode, approvalMode };
}

export function runtimePermissions(settings, cwd) {
  return {
    sandbox: settings.mode,
    approvalPolicy: settings.approvalMode === 'full' ? 'never' : 'on-request',
    approvalsReviewer: settings.approvalMode === 'auto' ? 'auto_review' : 'user',
    sandboxPolicy: settings.mode === 'danger-full-access' ? { type: 'dangerFullAccess' } :
      settings.mode === 'read-only' ? { type: 'readOnly' } :
        { type: 'workspaceWrite', writableRoots: [cwd], networkAccess: false, excludeTmpdirEnvVar: true, excludeSlashTmp: true }
  };
}

export function matchesResumePermissions(result, permissions) {
  // 0.160.1 may return the stored sandbox on resume even when a new legacy
  // sandbox was requested. turn/start is the authoritative per-turn override.
  // Accept only known policies here; the selected scope is always sent again
  // in sandboxPolicy, along with the reviewer, before any user input executes.
  return result.approvalPolicy === permissions.approvalPolicy && result.approvalsReviewer === permissions.approvalsReviewer &&
    ['readOnly', 'workspaceWrite', 'dangerFullAccess'].includes(result.sandbox?.type);
}
