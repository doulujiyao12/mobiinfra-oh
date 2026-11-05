import { ChatPersonRef } from './DataManagerTypes';

export interface ChatPromptMessage {
  speaker: ChatPersonRef;
  recipient: string;
  text: string;
}

// Project explicit capture labels into roles; never infer the subject of a
// statement from its speaker or recipient. Original text stays alongside it.
export function chatPromptMessages(text: string): ChatPromptMessage[] {
  let messages: ChatPromptMessage[] = [];
  for (let line of text.split('\n')) {
    let match = /位置[：:]\s*(左侧|右侧)\s*[｜|]\s*发送人[：:]\s*(.*?)\s*[｜|]\s*聊天对象[：:]\s*(.*?)\s*[｜|].*?原文[：:]\s*(.*)$/.exec(line);
    if (!match || !match[4].trim()) { continue; }
    let content = match[4].trim();
    let wrapper = line.trim()[0];
    if (wrapper === "'" || wrapper === '"') {
      let suffix = content.endsWith(',') ? content.slice(0, -1) : content;
      if (suffix.endsWith(wrapper)) { content = suffix.slice(0, -1); }
    }
    let name = match[2].replace(/（姓名未显示）/g, '').trim();
    messages.push({ speaker: { kind: match[1] === '右侧' ? 'self' : 'other',
      name: match[1] === '右侧' ? '' : name }, recipient: match[3].trim(), text: content });
  }
  return messages;
}
