import { http } from '@kit.NetworkKit';

// Lifecycle for requests made by the foreground app. Agreement presentation is
// owned by Huawei's app-entry flow. External memory sharing keeps its separate
// authorization in PersonalMemoryAccess and does not inherit access from here.
export class AppRequests {
  private static requests: http.HttpRequest[] = [];
  private static cancellers: Map<http.HttpRequest, () => void> = new Map();
  private static externalRequests: Map<number, () => void> = new Map();
  private static externalSequence: number = 0;

  static createHttp(): http.HttpRequest {
    const request = http.createHttp();
    AppRequests.requests.push(request);
    return request;
  }

  static destroyHttp(request: http.HttpRequest): void {
    AppRequests.cancellers.delete(request);
    if (AppRequests.requests.indexOf(request) < 0) { return; }
    AppRequests.requests = AppRequests.requests.filter((item: http.HttpRequest): boolean => item !== request);
    try { request.destroy(); } catch (e) { }
  }

  static onHttpCancel(request: http.HttpRequest, cancel: () => void): void {
    AppRequests.cancellers.set(request, cancel);
  }

  static registerExternalRequest(cancel: () => void): () => void {
    const id = ++AppRequests.externalSequence;
    AppRequests.externalRequests.set(id, cancel);
    return (): void => { AppRequests.externalRequests.delete(id); };
  }

  static cancelAll(): void {
    const external = Array.from(AppRequests.externalRequests.values());
    AppRequests.externalRequests.clear();
    external.forEach((cancel: () => void): void => { try { cancel(); } catch (e) { } });
    const pending = AppRequests.requests.slice();
    pending.forEach((request: http.HttpRequest): void => {
      try { AppRequests.cancellers.get(request)?.(); }
      catch (e) { }
      finally { AppRequests.destroyHttp(request); }
    });
  }
}
