import { EntityMention, IndexedEvent } from './DataManagerTypes';
import { normalizeFreeText, normalizeLookupText, stableUnique } from './DataManagerUtils';

export interface CollectionChatIdentity { key: string; name: string; known: boolean; }

export function collectionChatName(value: string): string {
  let name = normalizeFreeText(value).replace(/^[「“"']+|[」”"']+$/g, '').trim()
    .replace(/[（(]\s*\d+\s*[）)]\s*$/, '').trim();
  if (!name || name.length > 40 || /姓名未显示|未指定对象|无法识别|未识别|顶部联系人/.test(name) ||
    /^(我|你|用户|本人|对方|他|她|某人|群内|群聊|私聊|群成员|群友|当前会话|当前群聊|当前聊天对象|未知.*|不明.*|私聊联系人.*|[左右]侧成员\d*.*)$/.test(name) ||
    /(的聊天中|的对话中|(?:聊天|讨论|沟通|对话)[中里时]|表示|提到|讨论了)/.test(name)) { return ''; }
  const platforms: string[] = ['微信', '微信聊天', '聊天', '聊天记录', '本地日志', '图库', '图片', '截图',
    'photos', 'gallery', 'photo', 'galleryanalysis', '支付宝', '淘宝', '京东', '饿了么', '美团', '美团外卖'];
  const key = normalizeLookupText(name);
  if (platforms.indexOf(key) >= 0 || /^wechat\d{8}t\d+$/i.test(key) ||
    /(页面|界面|截图|图片|订单|脚本|日志)$/.test(name)) { return ''; }
  return name;
}

function referencedContact(event: IndexedEvent): string {
  for (let ref of [event.source_state_file || ''].concat(event.source_refs || [])) {
    let base = ref.split('/').pop() || '';
    try { base = decodeURIComponent(base); } catch (e) { }
    base = base.replace(/#.*$/, '').replace(/\.state\.json$/, '').replace(/\.md$/, '');
    let parts = base.split('__');
    if (parts.length < 3) { continue; }
    let name = collectionChatName(parts.slice(2).join('__'));
    if (name) { return name; }
  }
  return '';
}

function explicitContact(event: IndexedEvent, headersOnly: boolean): string {
  const text = (event.normalized_fact || '') + '\n' + (event.summary || '');
  const patterns: RegExp[] = headersOnly ? [
    /(?:^|[\n；;。])\s*(?:会话名称|会话标题|联系人)\s*[:：]\s*([^\n，。；;｜|]{1,40})/,
    /(?:微信联系人|与联系人)[「“"]([^」”"\n]{1,40})[」”"]/,
    /(?:^|[\n；;。])\s*聊天对象\s*[:：]\s*([^\n，。；;｜|]{1,40})/
  ] : [
    /与(?:联系人|同事|朋友)?[「“"]?([^，。；;\n「」“”"]{1,40}?)(?:的聊天(?:中|里)?|的对话(?:中|里)?|进行沟通|进行讨论|沟通|讨论|聊天|对话)/
  ];
  for (let pattern of patterns) {
    let match = pattern.exec(text);
    if (match !== null) {
      let name = collectionChatName(match[1].replace(/的$/, ''));
      if (name) { return name; }
    }
  }
  return '';
}

export function collectionChatIdentity(event: IndexedEvent): CollectionChatIdentity {
  let galleryRefs = [event.source_state_file || ''].concat(event.source_refs || []).join(' ');
  if (galleryRefs.indexOf('com.huawei.photos__gallery-analysis__聊天') >= 0 ||
    ((event.sources || []).indexOf('图库') >= 0 && (event.sources || []).indexOf('聊天') >= 0)) {
    return { key: 'gallery-chat', name: '图库聊天', known: true };
  }
  let name = explicitContact(event, true) || referencedContact(event);
  if (!name) {
    for (let source of (event.sources || []).slice(1)) {
      name = collectionChatName(source);
      if (name && (event.entity_mentions || []).some((mention: EntityMention): boolean =>
        normalizeLookupText(mention.name) === normalizeLookupText(name) &&
        mention.type !== 'person' && mention.type !== 'group')) { name = ''; }
      if (name) { break; }
    }
  }
  if (!name) { name = explicitContact(event, false); }
  const refs = [event.source_state_file || ''].concat(event.source_refs || []).join(' ');
  let app = /com\.tencent\.(wechat|mm)|微信/i.test(refs + ' ' + (event.sources || []).join(' ')) ? 'wechat' :
    normalizeLookupText((event.sources || [])[0] || 'chat');
  if (name) { return { key: app + ':name:' + normalizeLookupText(name), name: name, known: true }; }
  // One collection batch can contain multiple conversations. Without a named
  // conversation, a shared placeholder or batch ID cannot establish identity.
  let batches = event.chat_context ? stableUnique(event.chat_context.batch_ids || []).sort() : [];
  let evidence = (event.source_refs || [])[0] ||
    (event.source_state_file ? event.source_state_file + '#' + event.record_id : event.event_id);
  let scope = batches.join('|') + ':' + evidence;
  return { key: app + ':anonymous:' + scope, name: app === 'wechat' ? '微信会话' : '聊天会话', known: false };
}
