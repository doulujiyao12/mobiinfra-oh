import fs from '@ohos.file.fs';
import { DataManagerStorage } from '../datamanager/DataManagerStorage';
import { MemoryChangeJournal } from '../datamanager/MemoryChangeJournal';
import { parseJsonCompat, stringifyJsonCompat } from './JsonCompat';
import { decodeUtf8Compat, encodeUtf8Compat } from './TextEncodingCompat';
import {
  CHAT_MESSAGE_KIND_CHAT,
  ChatAssistantThinkingParts,
  ChatMessage,
  ChatSessionIndex,
  ChatSessionRecord,
  ChatSessionSummary,
  buildChatSessionSummary,
  chatMessageImagePath,
  chatMessageImagePaths,
  chatMessageThinkingCollapsed,
  chatMessageThinkingContent,
  chatMessageVoiceMetadataForStorage,
  createEmptyChatSession,
  normalizeChatMode,
  splitAssistantThinkingContent
} from '../pages/chat/ChatSessionTypes';

const CHAT_SESSION_DIR: string = 'chat-sessions';
const CHAT_SESSION_RECORD_DIR: string = 'sessions';
const CHAT_SESSION_ASSET_DIR: string = 'assets';
const CHAT_SESSION_INDEX_FILE: string = 'session-index.json';
const CHAT_SESSION_CUSTOM_TITLE_MAX_LENGTH: number = 40;
type ListFileEntry = string | Record<string, Object | string | number | boolean | null>;

export class ChatSessionStorage {
  static rootDir(filesDir: string): string {
    return filesDir + '/' + CHAT_SESSION_DIR;
  }

  static sessionsDir(filesDir: string): string {
    return ChatSessionStorage.rootDir(filesDir) + '/' + CHAT_SESSION_RECORD_DIR;
  }

  static assetsDir(filesDir: string): string {
    return ChatSessionStorage.rootDir(filesDir) + '/' + CHAT_SESSION_ASSET_DIR;
  }

  static sessionAssetsDir(filesDir: string, sessionId: string): string {
    return ChatSessionStorage.assetsDir(filesDir) + '/' + sessionId;
  }

  static indexPath(filesDir: string): string {
    return ChatSessionStorage.rootDir(filesDir) + '/' + CHAT_SESSION_INDEX_FILE;
  }

  static sessionFileName(sessionId: string): string {
    return sessionId + '.json';
  }

  static sessionPath(filesDir: string, sessionId: string): string {
    return ChatSessionStorage.sessionsDir(filesDir) + '/' + ChatSessionStorage.sessionFileName(sessionId);
  }

  // 只做会话记录存在性判断，不解析 JSON，供异步缓存保存前快速确认会话未被删除。
  static sessionExists(filesDir: string, sessionId: string): boolean {
    return ChatSessionStorage.pathExists(ChatSessionStorage.sessionPath(filesDir, sessionId));
  }

  static sessionAssetPath(filesDir: string, sessionId: string, fileName: string): string {
    return ChatSessionStorage.sessionAssetsDir(filesDir, sessionId) + '/' + ChatSessionStorage.safeAssetFileName(fileName);
  }

  static pathExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  static ensureDirectory(path: string): void {
    try {
      if (!ChatSessionStorage.pathExists(path)) {
        fs.mkdirSync(path);
      }
    } catch (e) {
      try {
        fs.mkdirSync(path);
      } catch (err) {
      }
    }
  }

  static ensureWorkspace(filesDir: string): void {
    ChatSessionStorage.ensureDirectory(ChatSessionStorage.rootDir(filesDir));
    ChatSessionStorage.ensureDirectory(ChatSessionStorage.sessionsDir(filesDir));
    ChatSessionStorage.ensureDirectory(ChatSessionStorage.assetsDir(filesDir));
  }

  static ensureSessionAssetsDir(filesDir: string, sessionId: string): void {
    ChatSessionStorage.ensureWorkspace(filesDir);
    ChatSessionStorage.ensureDirectory(ChatSessionStorage.sessionAssetsDir(filesDir, sessionId));
  }

  // 独立清理指定会话的资源目录，避免异步 TTS 保存竞态留下孤立缓存。
  static deleteSessionAssetsDir(filesDir: string, sessionId: string): void {
    ChatSessionStorage.deletePathRecursive(ChatSessionStorage.sessionAssetsDir(filesDir, sessionId));
  }

  static readText(path: string): string {
    let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      let stat = fs.statSync(path);
      let buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      return decodeUtf8Compat(new Uint8Array(buf));
    } finally {
      fs.closeSync(file);
    }
  }

  static writeText(path: string, content: string): void {
    let encoded = encodeUtf8Compat(content);
    let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, encoded.buffer);
    } finally {
      fs.closeSync(file);
    }
  }

  static createSessionId(now: number): string {
    return 'chat-' + String(now);
  }

  static createUniqueSessionId(filesDir: string, now: number): string {
    let baseId = ChatSessionStorage.createSessionId(now);
    let sessionId = baseId;
    let suffix = 1;
    while (ChatSessionStorage.pathExists(ChatSessionStorage.sessionPath(filesDir, sessionId))) {
      sessionId = baseId + '-' + String(suffix);
      suffix += 1;
    }
    return sessionId;
  }

  static loadIndex(filesDir: string): ChatSessionSummary[] {
    ChatSessionStorage.ensureWorkspace(filesDir);
    try {
      if (!ChatSessionStorage.pathExists(ChatSessionStorage.indexPath(filesDir))) {
        return [];
      }
      let parsed = parseJsonCompat<ChatSessionIndex>(ChatSessionStorage.readText(ChatSessionStorage.indexPath(filesDir)));
      return ChatSessionStorage.sortSessions(ChatSessionStorage.normalizeSummaries(parsed.sessions === undefined ? [] :
        parsed.sessions));
    } catch (e) {
      try {
        let brokenPath = ChatSessionStorage.indexPath(filesDir) + '.broken.' + String(new Date().getTime());
        ChatSessionStorage.writeText(brokenPath, ChatSessionStorage.readText(ChatSessionStorage.indexPath(filesDir)));
      } catch (err) {
      }
      return [];
    }
  }

  static saveIndex(filesDir: string, sessions: ChatSessionSummary[]): void {
    ChatSessionStorage.ensureWorkspace(filesDir);
    let index: ChatSessionIndex = {
      sessions: ChatSessionStorage.sortSessions(ChatSessionStorage.normalizeSummaries(sessions))
    };
    ChatSessionStorage.writeText(ChatSessionStorage.indexPath(filesDir), stringifyJsonCompat(index as Object, 2));
  }

  static sortSessions(sessions: ChatSessionSummary[]): ChatSessionSummary[] {
    let sorted = ChatSessionStorage.normalizeSummaries(sessions);
    sorted.sort((left: ChatSessionSummary, right: ChatSessionSummary) => {
      let leftPinned = left.pinned === true;
      let rightPinned = right.pinned === true;
      if (leftPinned !== rightPinned) {
        return leftPinned ? -1 : 1;
      }
      if (leftPinned && rightPinned) {
        let leftPinnedAt = ChatSessionStorage.normalizedOptionalNumber(left.pinnedAt);
        let rightPinnedAt = ChatSessionStorage.normalizedOptionalNumber(right.pinnedAt);
        if (leftPinnedAt !== rightPinnedAt) {
          return rightPinnedAt - leftPinnedAt;
        }
      }
      if (left.updatedAt !== right.updatedAt) {
        return right.updatedAt - left.updatedAt;
      }
      if (left.title === right.title) {
        return 0;
      }
      return left.title > right.title ? 1 : -1;
    });
    return sorted;
  }

  static createSession(filesDir: string, mode: string, now: number = new Date().getTime()): ChatSessionRecord {
    ChatSessionStorage.ensureWorkspace(filesDir);
    let session = createEmptyChatSession(ChatSessionStorage.createUniqueSessionId(filesDir, now), normalizeChatMode(mode), now);
    ChatSessionStorage.saveSession(filesDir, session);
    return session;
  }

  static loadSession(filesDir: string, sessionId: string): ChatSessionRecord | null {
    ChatSessionStorage.ensureWorkspace(filesDir);
    try {
      let session = parseJsonCompat<ChatSessionRecord>(ChatSessionStorage.readText(ChatSessionStorage.sessionPath(filesDir, sessionId)));
      session.mode = normalizeChatMode(session.mode);
      session.messages = session.messages === undefined ? [] : ChatSessionStorage.normalizeMessages(session.messages);
      session.contextSummary = ChatSessionStorage.normalizedOptionalString(session.contextSummary);
      session.contextSummaryUpdatedAt = ChatSessionStorage.normalizedOptionalNumber(session.contextSummaryUpdatedAt);
      session.contextSummaryUntilMessageId = ChatSessionStorage.normalizedOptionalString(session.contextSummaryUntilMessageId);
      session.contextSummaryMessageCount = ChatSessionStorage.normalizedOptionalNumber(session.contextSummaryMessageCount);
      session.customTitle = ChatSessionStorage.normalizedCustomTitle(session.customTitle);
      session.pinned = ChatSessionStorage.normalizedOptionalBoolean(session.pinned);
      session.pinnedAt = session.pinned ? ChatSessionStorage.normalizedOptionalNumber(session.pinnedAt) : 0;
      return session;
    } catch (e) {
      ChatSessionStorage.removeFromIndex(filesDir, sessionId);
      return null;
    }
  }

  static saveSession(filesDir: string, session: ChatSessionRecord): void {
    new MemoryChangeJournal(filesDir, new DataManagerStorage()).mark('chat', session.id);
    ChatSessionStorage.ensureWorkspace(filesDir);
    let normalized: ChatSessionRecord = {
      id: session.id,
      title: session.title,
      mode: normalizeChatMode(session.mode),
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      messages: ChatSessionStorage.normalizeMessages(session.messages),
      contextSummary: ChatSessionStorage.normalizedOptionalString(session.contextSummary),
      contextSummaryUpdatedAt: ChatSessionStorage.normalizedOptionalNumber(session.contextSummaryUpdatedAt),
      contextSummaryUntilMessageId: ChatSessionStorage.normalizedOptionalString(session.contextSummaryUntilMessageId),
      contextSummaryMessageCount: ChatSessionStorage.normalizedOptionalNumber(session.contextSummaryMessageCount),
      customTitle: ChatSessionStorage.normalizedCustomTitle(session.customTitle),
      pinned: ChatSessionStorage.normalizedOptionalBoolean(session.pinned),
      pinnedAt: ChatSessionStorage.normalizedOptionalBoolean(session.pinned) ?
        ChatSessionStorage.normalizedOptionalNumber(session.pinnedAt) : 0
    };
    ChatSessionStorage.writeText(ChatSessionStorage.sessionPath(filesDir, normalized.id),
      stringifyJsonCompat(normalized as Object, 2));
    ChatSessionStorage.upsertSummary(filesDir,
      buildChatSessionSummary(normalized, ChatSessionStorage.sessionFileName(normalized.id)));
  }

  static appendMessage(filesDir: string, sessionId: string, message: ChatMessage): ChatSessionRecord | null {
    let session = ChatSessionStorage.loadSession(filesDir, sessionId);
    if (session === null) {
      return null;
    }
    session.messages = session.messages.concat([message]);
    session.updatedAt = message.createdAt;
    ChatSessionStorage.saveSession(filesDir, session);
    return session;
  }

  static renameSession(filesDir: string, sessionId: string, title: string): ChatSessionRecord | null {
    let session = ChatSessionStorage.loadSession(filesDir, sessionId);
    if (session === null) {
      return null;
    }
    // 重命名只更新展示元数据，不触碰消息列表和更新时间，避免改变普通历史排序语义。
    session.customTitle = ChatSessionStorage.normalizedCustomTitle(title);
    ChatSessionStorage.saveSession(filesDir, session);
    return session;
  }

  static setSessionPinned(filesDir: string, sessionId: string, pinned: boolean,
    now: number): ChatSessionRecord | null {
    let session = ChatSessionStorage.loadSession(filesDir, sessionId);
    if (session === null) {
      return null;
    }
    // 置顶排序由 pinnedAt 驱动；取消置顶后清零，重新回到普通 updatedAt 排序。
    session.pinned = pinned;
    session.pinnedAt = pinned ? now : 0;
    ChatSessionStorage.saveSession(filesDir, session);
    return session;
  }

  static adoptImageForSession(filesDir: string, sessionId: string, imagePath: string): string {
    if (filesDir.length === 0 || sessionId.length === 0 || imagePath.length === 0) {
      return imagePath;
    }
    let sourcePath = ChatSessionStorage.stripFileUri(imagePath);
    if (sourcePath.length === 0) {
      return imagePath;
    }
    ChatSessionStorage.ensureSessionAssetsDir(filesDir, sessionId);
    let assetDir = ChatSessionStorage.sessionAssetsDir(filesDir, sessionId);
    if (sourcePath.indexOf(assetDir + '/') === 0) {
      return 'file://' + sourcePath;
    }
    if (!ChatSessionStorage.pathExists(sourcePath)) {
      return imagePath;
    }
    let targetPath = ChatSessionStorage.uniqueAssetPath(filesDir, sessionId,
      ChatSessionStorage.fileNameFromPath(sourcePath));
    try {
      ChatSessionStorage.copyFile(sourcePath, targetPath);
      return 'file://' + targetPath;
    } catch (e) {
      return imagePath;
    }
  }

  static upsertSummary(filesDir: string, summary: ChatSessionSummary): void {
    let sessions = ChatSessionStorage.loadIndex(filesDir).filter((item: ChatSessionSummary) => item.id !== summary.id);
    sessions.push(summary);
    ChatSessionStorage.saveIndex(filesDir, sessions);
  }

  static removeFromIndex(filesDir: string, sessionId: string): void {
    let sessions = ChatSessionStorage.loadIndex(filesDir).filter((item: ChatSessionSummary) => item.id !== sessionId);
    ChatSessionStorage.saveIndex(filesDir, sessions);
  }

  static deleteSession(filesDir: string, sessionId: string): boolean {
    new MemoryChangeJournal(filesDir, new DataManagerStorage()).mark('chat', sessionId);
    ChatSessionStorage.ensureWorkspace(filesDir);
    let path = ChatSessionStorage.sessionPath(filesDir, sessionId);
    if (ChatSessionStorage.pathExists(path)) {
      try {
        fs.unlinkSync(path);
      } catch (e) {
        return false;
      }
    }
    ChatSessionStorage.deleteSessionAssetsDir(filesDir, sessionId);
    ChatSessionStorage.removeFromIndex(filesDir, sessionId);
    return true;
  }

  static nextSessionAfterDelete(filesDir: string, deletedId: string): ChatSessionSummary | null {
    let sessions = ChatSessionStorage.loadIndex(filesDir).filter((item: ChatSessionSummary) => item.id !== deletedId);
    return sessions.length > 0 ? sessions[0] : null;
  }

  private static normalizeMessages(messages: ChatMessage[]): ChatMessage[] {
    let normalized: ChatMessage[] = [];
    for (let i = 0; i < messages.length; i++) {
      let message = messages[i];
      let thinkingContent = chatMessageThinkingContent(message);
      let visibleContent = message.content;
      if (thinkingContent.length === 0 && message.role === 'assistant' && message.kind === CHAT_MESSAGE_KIND_CHAT) {
        let parts: ChatAssistantThinkingParts = splitAssistantThinkingContent(message.content);
        visibleContent = parts.content;
        thinkingContent = parts.thinkingContent;
      }
      let normalizedMessage: ChatMessage = {
        id: message.id,
        role: message.role,
        kind: message.kind,
        content: visibleContent,
        thinkingContent: thinkingContent,
        thinkingCollapsed: chatMessageThinkingCollapsed(message),
        trace: message.trace === undefined ? [] : message.trace.slice(),
        collapsed: message.collapsed,
        createdAt: message.createdAt,
        imagePath: chatMessageImagePath(message),
        imagePaths: chatMessageImagePaths(message)
      };
      if (typeof message.codexRunId === 'string' && /^[a-zA-Z0-9-]{32,36}$/.test(message.codexRunId)) {
        normalizedMessage.codexRunId = message.codexRunId;
      }
      let voiceMetadata = chatMessageVoiceMetadataForStorage(message);
      if (voiceMetadata !== undefined) {
        normalizedMessage.voice = voiceMetadata;
      }
      normalized.push(normalizedMessage);
    }
    return normalized;
  }

  private static normalizedOptionalString(value?: string): string {
    return value === undefined ? '' : value;
  }

  private static normalizedOptionalNumber(value?: number): number {
    return value === undefined ? 0 : value;
  }

  private static normalizedOptionalBoolean(value?: boolean): boolean {
    return value === true;
  }

  private static normalizedCustomTitle(value?: string): string {
    let title = ChatSessionStorage.normalizedOptionalString(value).trim();
    return title.length > CHAT_SESSION_CUSTOM_TITLE_MAX_LENGTH ? title.substring(0,
      CHAT_SESSION_CUSTOM_TITLE_MAX_LENGTH) : title;
  }

  private static normalizeSummary(summary: ChatSessionSummary): ChatSessionSummary {
    let pinned = ChatSessionStorage.normalizedOptionalBoolean(summary.pinned);
    let customTitle = ChatSessionStorage.normalizedCustomTitle(summary.customTitle);
    return {
      id: summary.id,
      title: customTitle.length > 0 ? customTitle : summary.title,
      mode: normalizeChatMode(summary.mode),
      fileName: summary.fileName,
      createdAt: summary.createdAt,
      updatedAt: summary.updatedAt,
      messageCount: summary.messageCount,
      lastMessagePreview: summary.lastMessagePreview,
      customTitle: customTitle,
      pinned: pinned,
      pinnedAt: pinned ? ChatSessionStorage.normalizedOptionalNumber(summary.pinnedAt) : 0
    };
  }

  private static normalizeSummaries(sessions: ChatSessionSummary[]): ChatSessionSummary[] {
    let normalized: ChatSessionSummary[] = [];
    for (let i = 0; i < sessions.length; i++) {
      normalized.push(ChatSessionStorage.normalizeSummary(sessions[i]));
    }
    return normalized;
  }

  private static stripFileUri(path: string): string {
    return path.startsWith('file://') ? path.substring(7) : path;
  }

  private static fileNameFromPath(path: string): string {
    let slashIndex = path.lastIndexOf('/');
    let fileName = slashIndex >= 0 ? path.substring(slashIndex + 1) : path;
    return ChatSessionStorage.safeAssetFileName(fileName);
  }

  private static safeAssetFileName(fileName: string): string {
    let safe = '';
    for (let i = 0; i < fileName.length; i++) {
      let code = fileName.charCodeAt(i);
      let char = fileName.charAt(i);
      let isNumber = code >= 48 && code <= 57;
      let isUpper = code >= 65 && code <= 90;
      let isLower = code >= 97 && code <= 122;
      let isSymbol = char === '.' || char === '_' || char === '-';
      let nextChar = (isNumber || isUpper || isLower || isSymbol) ? char : '_';
      safe += nextChar;
    }
    return safe.length > 0 ? safe : 'agent_snapshot_' + String(new Date().getTime()) + '.jpg';
  }

  private static uniqueAssetPath(filesDir: string, sessionId: string, fileName: string): string {
    let safeFileName = ChatSessionStorage.safeAssetFileName(fileName);
    let targetPath = ChatSessionStorage.sessionAssetPath(filesDir, sessionId, safeFileName);
    if (!ChatSessionStorage.pathExists(targetPath)) {
      return targetPath;
    }
    let dotIndex = safeFileName.lastIndexOf('.');
    let baseName = dotIndex > 0 ? safeFileName.substring(0, dotIndex) : safeFileName;
    let extension = dotIndex > 0 ? safeFileName.substring(dotIndex) : '';
    let suffix = 1;
    while (true) {
      let candidate = ChatSessionStorage.sessionAssetPath(filesDir, sessionId,
        baseName + '-' + String(suffix) + extension);
      if (!ChatSessionStorage.pathExists(candidate)) {
        return candidate;
      }
      suffix += 1;
    }
  }

  private static copyFile(sourcePath: string, targetPath: string): void {
    let sourceFile = fs.openSync(sourcePath, fs.OpenMode.READ_ONLY);
    let targetFile = fs.openSync(targetPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let stat = fs.statSync(sourcePath);
      let buffer = new ArrayBuffer(stat.size);
      fs.readSync(sourceFile.fd, buffer);
      fs.writeSync(targetFile.fd, buffer);
    } finally {
      fs.closeSync(sourceFile);
      fs.closeSync(targetFile);
    }
  }

  private static childPath(parent: string, child: string): string {
    if (child.startsWith('/')) {
      return child;
    }
    return parent + '/' + child;
  }

  private static basename(path: string): string {
    let normalized = path.replace(/\\/g, '/');
    let index = normalized.lastIndexOf('/');
    return index >= 0 ? normalized.substring(index + 1) : normalized;
  }

  private static normalizeListFileEntry(entry: ListFileEntry): string {
    if (typeof entry === 'string') {
      return ChatSessionStorage.basename(entry);
    }
    let record = entry as Record<string, Object | string | number | boolean | null>;
    let keys: string[] = ['fileName', 'filename', 'name', 'path', 'uri'];
    for (let i = 0; i < keys.length; i++) {
      let value = record[keys[i]];
      if (typeof value === 'string' && value.length > 0) {
        return ChatSessionStorage.basename(value);
      }
    }
    let text = String(entry);
    if (text.length === 0 || text === '[object Object]') {
      return '';
    }
    return ChatSessionStorage.basename(text);
  }

  private static listChildNames(path: string): string[] {
    try {
      let entries = fs.listFileSync(path) as ListFileEntry[];
      let names: string[] = [];
      for (let i = 0; i < entries.length; i++) {
        let name = ChatSessionStorage.normalizeListFileEntry(entries[i]);
        if (name.length > 0) {
          names.push(name);
        }
      }
      return names;
    } catch (e) {
      return [];
    }
  }

  private static isDirectory(path: string): boolean {
    try {
      if (!ChatSessionStorage.pathExists(path)) {
        return false;
      }
      return fs.statSync(path).isDirectory();
    } catch (e) {
      return false;
    }
  }

  private static deletePathRecursive(path: string): void {
    if (!ChatSessionStorage.pathExists(path)) {
      return;
    }
    if (!ChatSessionStorage.isDirectory(path)) {
      try {
        fs.unlinkSync(path);
      } catch (e) {
      }
      return;
    }
    try {
      let children = ChatSessionStorage.listChildNames(path);
      for (let i = 0; i < children.length; i++) {
        ChatSessionStorage.deletePathRecursive(ChatSessionStorage.childPath(path, children[i]));
      }
      fs.rmdirSync(path);
    } catch (e) {
      try {
        fs.unlinkSync(path);
      } catch (err) {
      }
    }
  }
}
