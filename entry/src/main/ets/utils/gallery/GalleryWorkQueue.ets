// A batch owns its workers until they have all settled. Failure stops new
// dispatch, while already running OCR/model/persistence work can finish safely.
export async function runGalleryWorkQueue(count: number, limit: number,
  worker: (index: number) => Promise<boolean>): Promise<void> {
  let nextIndex = 0;
  let stopped = false;
  let failure: Error | null = null;
  let workers: Promise<void>[] = [];
  for (let i = 0; i < Math.min(limit, count); i++) {
    workers.push((async (): Promise<void> => {
      while (!stopped && nextIndex < count) {
        let index = nextIndex++;
        try {
          if (!await worker(index)) { stopped = true; }
        } catch (e) {
          if (failure === null) { failure = e as Error; }
          stopped = true;
        }
      }
    })());
  }
  await Promise.all(workers);
  if (failure !== null) { throw failure; }
}
