import { HdcWorkflowBridge } from './HdcWorkflowBridge';
import { WorkflowCancellation } from './WorkflowCancellation';
import { HdcBridgeResponse, WorkflowJsonMap } from './WorkflowTypes';
import { getAppBundleName } from './AppIdentity';

// Opt-in guard for task-page PC workflows. Keep the existing PC transport intact.
// Check at the final request boundary, including screenshot overlay awaits.
export class CancellableWorkflowHdcBridge extends HdcWorkflowBridge {
  private cancellation: WorkflowCancellation;

  constructor(baseUrl: string, logHandler: (message: string) => void, cancellation: WorkflowCancellation) {
    super(baseUrl, logHandler);
    this.cancellation = cancellation;
  }

  async request(action: string, payload?: WorkflowJsonMap): Promise<HdcBridgeResponse> {
    let returningToHost = action === 'app_start' && payload !== undefined &&
      payload['package_name'] === getAppBundleName() && payload['reset_first'] === false;
    if (!returningToHost) { this.cancellation.throwIfCancelled(); }
    // An already-issued device action must settle before another run can start.
    let response = await super.request(action, payload);
    if (!returningToHost) { this.cancellation.throwIfCancelled(); }
    return response;
  }
}
