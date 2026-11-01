export type CloudApiProvider = 'compatible' | 'openai' | 'openrouter' | 'deepseek';

export function cloudApiProvider(baseUrl: string): CloudApiProvider {
  let match = /^https?:\/\/([^/?#]+)/i.exec(baseUrl.trim());
  let host = match === null ? '' : match[1].toLowerCase().split(':')[0];
  if (host === 'api.openai.com') { return 'openai'; }
  if (host === 'openrouter.ai' || host.endsWith('.openrouter.ai')) { return 'openrouter'; }
  if (host === 'api.deepseek.com') { return 'deepseek'; }
  return 'compatible';
}

// Accept service roots, versioned base URLs and complete chat-completion endpoints.
export function normalizeCloudChatUrl(baseUrl: string): string {
  let withoutFragment = baseUrl.trim().split('#')[0];
  let queryIndex = withoutFragment.indexOf('?');
  let query = queryIndex < 0 ? '' : withoutFragment.substring(queryIndex);
  let url = (queryIndex < 0 ? withoutFragment : withoutFragment.substring(0, queryIndex)).replace(/\/+$/, '');
  if (url.endsWith('/chat/completions')) { return url + query; }
  if (url.endsWith('/v1')) { return url + '/chat/completions' + query; }
  let origin = /^https?:\/\/[^/]+$/i.test(url);
  if (cloudApiProvider(url) === 'openrouter' && origin) { return url + '/api/v1/chat/completions' + query; }
  if (cloudApiProvider(url) === 'deepseek' && origin) { return url + '/chat/completions' + query; }
  return url + '/v1/chat/completions' + query;
}
