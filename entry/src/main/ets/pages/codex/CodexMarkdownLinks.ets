import { CodexArtifact } from './CodexTypes';

export function codexWebLink(target: string): boolean { return /^https?:\/\/[^\s<>]+$/i.test(target.trim()); }

// Remote filesystem links can only open an already-declared delivery from this
// task. Never use a model-supplied absolute path to read arbitrary phone files.
export function codexLinkedArtifact(target: string, artifacts: CodexArtifact[]): CodexArtifact | undefined {
  let link = target.trim().replace(/^<|>$/g, '');
  try { link = decodeURIComponent(link); } catch (e) { return undefined; }
  // Only relative paths, Windows drive paths and the file/sandbox formats used
  // in Codex deliveries are eligible. Web links are handled separately.
  if (link.startsWith('#') || (/^[a-z][a-z0-9+.-]*:/i.test(link) &&
    !/^(file|sandbox):/i.test(link) && !/^[a-z]:[\\/]/i.test(link))) { return undefined; }
  link = link.replace(/\\/g, '/').split('#')[0].split('?')[0];
  let name = link.substring(link.lastIndexOf('/') + 1);
  const matches = artifacts.filter((artifact: CodexArtifact): boolean => artifact.name === name);
  return matches.length === 1 ? matches[0] : undefined;
}

export function codexMarkdownExcerpt(text: string, expanded: boolean): string {
  if (expanded || text.length <= 1600) { return text; }
  let end = text.lastIndexOf('\n\n', 1600);
  if (end < 800) { end = text.lastIndexOf('\n', 1600); }
  if (end < 800) { end = 1600; }
  if (text.charCodeAt(end - 1) >= 0xD800 && text.charCodeAt(end - 1) <= 0xDBFF) { end--; }
  return text.substring(0, end);
}
