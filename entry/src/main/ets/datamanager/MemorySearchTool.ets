import { JSON as ArkJSON } from '@kit.ArkTS';
import { ChatTool } from '../utils/ChatToolRegistry';
import { memoryEventText, MemorySearchArguments, MemorySearchResult, memorySearchToolParameters,
  parseMemorySearchArguments } from './MemorySemanticSearch';
interface SearchEvent { event_id: string; text: string; }
interface SearchResponse { ok: boolean; mode: string; events: SearchEvent[]; truncated: boolean; notice: string; }

export function createMemorySearchTool(search: (args: MemorySearchArguments) => Promise<MemorySearchResult>): ChatTool {
  return { name: 'search_memory', description: '用自然语言检索已同步的全部事件索引，包括任务采集、图库、聊天和日历等已入库来源。' +
    '支持同义表达扩展、领域/实体/时间过滤和语义相关性重排。需要按含义寻找资料时使用，精确关键词也可用 query_events。' +
    '返回事实和稳定event_id；范围有限，未找到不代表全部历史不存在。区分他人信息、计划和已完成事实。' +
    '人物资料优先采用用户手填确认的当前字段；明确查询本人或家人时用 subject_ids 限定主体，不能把父母、伴侣的信息当成本人的。',
    parameters: memorySearchToolParameters(), execute: async (text: string): Promise<string> => {
      const result = await search(parseMemorySearchArguments(text));
      const response: SearchResponse = { ok: true, mode: result.mode, events: [], truncated: result.truncated, notice: result.notice };
      for (let event of result.events) {
        const item: SearchEvent = { event_id: event.event_id, text: memoryEventText(event) };
        response.events.push(item);
        if (ArkJSON.stringify(response).length > 3500) { response.events.pop(); response.truncated = true; break; }
        if (response.events.length >= 6) { response.truncated = response.truncated || result.events.length > 6; break; }
      }
      return ArkJSON.stringify(response);
    } };
}
