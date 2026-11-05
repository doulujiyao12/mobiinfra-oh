// Classify HTTP 400 without copying the response body: services may echo
// prompts, request contents or credentials in their error messages.
export function cloudBadRequestCategory(responseText: string): string {
  const text = responseText.toLowerCase();
  if (/system message.{0,100}(beginning|first|start)|system.{0,40}(must|only).{0,60}(beginning|first)/.test(text)) {
    return 'system_message_position';
  }
  if (/context.{0,25}(length|window|limit)|maximum.{0,30}tokens|prompt.{0,30}too long/.test(text)) { return 'context_limit'; }
  if (/tool_call_id|tool_calls|tool_choice|tool.{0,30}(response|definition|parser)/.test(text)) { return 'tool_protocol'; }
  if (/unsupported.{0,25}(parameter|argument)|unknown.{0,25}(parameter|argument)|extra inputs are not permitted/.test(text)) {
    return 'unsupported_parameter';
  }
  if (/model.{0,80}(not found|does not exist|not available)/.test(text)) { return 'model_unavailable'; }
  return 'unclassified';
}

export function cloudBadRequestUserHint(errorMessage: string): string {
  if (errorMessage.includes('[system_message_position]')) { return 'system 消息位置不兼容'; }
  if (errorMessage.includes('[context_limit]')) { return '请求超过模型上下文限制'; }
  if (errorMessage.includes('[tool_protocol]')) { return '工具调用消息格式不兼容'; }
  if (errorMessage.includes('[unsupported_parameter]')) { return '模型服务不支持请求中的参数'; }
  if (errorMessage.includes('[model_unavailable]')) { return '请求的模型不可用'; }
  return '';
}
