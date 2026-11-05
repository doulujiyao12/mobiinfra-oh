import fs from '@ohos.file.fs';
import { JSON as ArkJSON } from '@kit.ArkTS';
import { JsonMap } from './DataManagerTypes';
import { compactWorkflowRunEvidence, WorkflowRunEvidence } from './WorkflowRunEvidence';

@Concurrent
export function readWorkflowRunEvidence(path: string): WorkflowRunEvidence | null {
  // Read AND parse on the worker. Passing the raw JSON from the UI thread would
  // still block on file decoding and copy all embedded screenshots twice.
  let payload = ArkJSON.parse(fs.readTextSync(path)) as JsonMap;
  return compactWorkflowRunEvidence(payload);
}
