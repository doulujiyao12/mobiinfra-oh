import { JsonMap } from './DataManagerTypes';

// Only metadata needed to associate a collected page with its screenshot may
// cross back to the UI thread. Run summaries also contain large base64 images,
// model requests and diagnostics; none of those belong in the index working set.
export interface WorkflowRunEvidence {
  steps: Record<string, JsonMap>;
}

interface WorkflowSummaryEvidence {
  summary: string;
}

export function compactWorkflowRunEvidence(payload: JsonMap | null): WorkflowRunEvidence | null {
  if (!payload || !payload['steps'] || typeof payload['steps'] !== 'object' || Array.isArray(payload['steps'])) {
    return null;
  }
  let original = payload['steps'] as Record<string, JsonMap>;
  let steps: Record<string, JsonMap> = {};
  for (let key of Object.keys(original)) {
    let source = original[key];
    let step: JsonMap = {};
    // Keep every key in insertion order: legacy screenshot matching uses it
    // when timestamps are absent, including steps unrelated to collection.
    steps[key] = step;
    if (!source || typeof source !== 'object') { continue; }
    if (typeof source['started_at'] === 'number') { step['started_at'] = source['started_at']; }
    if (typeof source['finished_at'] === 'number') { step['finished_at'] = source['finished_at']; }
    let value = source['output'];
    if (!value || typeof value !== 'object') { continue; }
    let output = value as JsonMap;
    let screenshot = output['action'] === 'screenshot';
    let summary = output['tool_name'] === 'vlm_qa' && output['mode'] === 'summary';
    if (!screenshot && !summary) { continue; }
    let compact: JsonMap = {};
    for (let field of ['action', 'tool_name', 'mode', 'daily_log_path', 'image', 'image_path', 'response']) {
      if (typeof output[field] === 'string') { compact[field] = output[field]; }
    }
    let encoded = output['image_b64'];
    if (screenshot && typeof encoded === 'string' && encoded.length > 0) {
      // The resolver needs presence only; the real image stays in the source.
      compact['image_b64'] = 'present';
    }
    let structured = output['structured_output'];
    if (summary && structured && typeof structured === 'object') {
      let text = (structured as JsonMap)['summary'];
      if (typeof text === 'string') {
        let summaryOnly: WorkflowSummaryEvidence = { summary: text };
        compact['structured_output'] = summaryOnly;
      }
    }
    step['output'] = compact;
  }
  return { steps: steps };
}
