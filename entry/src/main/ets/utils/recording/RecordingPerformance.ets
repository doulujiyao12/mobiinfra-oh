import native from 'libentry.so';

// Reserve one available CPU on larger allocations; never oversubscribe the
// app's current affinity mask. Logical CPU count alone is not a speed ranking.
export function recordingInferenceThreads(available: number): number {
  if (!Number.isFinite(available) || available < 1) { return 3; }
  let count = Math.floor(available);
  return Math.max(1, Math.min(4, count > 2 ? count - 1 : count));
}

export function recordingAvailableThreads(): number {
  return recordingInferenceThreads(native.recordingAvailableCpus());
}
