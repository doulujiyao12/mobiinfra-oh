import { MarkdownBlock, MarkdownInline, parseMarkdown } from './MarkdownParser';

export interface CodexMathDocument {
  html: string;
  links: string[];
}

interface MathFragment {
  raw: string;
  latex: string;
  display: boolean;
}

interface MathSource {
  markdown: string;
  prefix: string;
  fragments: MathFragment[];
}

const MAX_FORMULA_LENGTH: number = 4096;
const MAX_FORMULAS: number = 160;

function escapedAt(text: string, index: number): boolean {
  let backslashes = 0;
  while (index > 0 && text.charAt(--index) === '\\') { backslashes++; }
  return backslashes % 2 === 1;
}

function findClosing(text: string, start: number, close: string, display: boolean): number {
  const limit = Math.min(start + MAX_FORMULA_LENGTH, text.length);
  for (let i = start; i < limit; i++) {
    if (text.charAt(i) === '\n' && (!display || /^\n[ \t]*(?:```|~~~)/.test(text.substring(i, i + 24)))) { return -1; }
    if (!text.startsWith(close, i) || escapedAt(text, i)) { continue; }
    if (close === '$') {
      if (text.charAt(i + 1) === '$' || text.charAt(i - 1) === '$') { return -1; }
      if (/\s/.test(text.charAt(i - 1)) || /[0-9]/.test(text.charAt(i + 1))) { return -1; }
    }
    return i;
  }
  return -1;
}

function extractMath(text: string): MathSource {
  const source = text.replace(/\r\n?/g, '\n');
  let prefix = '\uE000cmath';
  while (source.includes(prefix)) { prefix += 'm'; }
  const fragments: MathFragment[] = [];
  const parts: string[] = [];
  let fence = '';
  let code = '';
  let copied = 0;
  for (let i = 0; i < source.length && fragments.length < MAX_FORMULAS; i++) {
    const ch = source.charAt(i);
    if ((i === 0 || source.charAt(i - 1) === '\n') && !code) {
      const marker = /^[ \t]*(`{3,}|~{3,})/.exec(source.substring(i, i + 48));
      if (marker !== null) {
        if (!fence) { fence = marker[1]; }
        else if (marker[1].charAt(0) === fence.charAt(0) && marker[1].length >= fence.length) { fence = ''; }
        const lineEnd = source.indexOf('\n', i);
        if (lineEnd < 0) { break; }
        i = lineEnd;
        continue;
      }
    }
    if (fence) { continue; }
    if (ch === '`' && !escapedAt(source, i)) {
      let end = i + 1;
      while (source.charAt(end) === '`') { end++; }
      const marker = source.substring(i, end);
      if (code === marker) { code = ''; }
      else if (!code && source.indexOf(marker, end) >= 0) { code = marker; }
      i = end - 1;
      continue;
    }
    if (code || (ch !== '$' && ch !== '\\') || escapedAt(source, i)) { continue; }
    let close = '';
    let length = 2;
    let display = false;
    if (source.startsWith('\\[', i) || source.startsWith('$$', i)) {
      display = true;
      close = ch === '$' ? '$$' : '\\]';
    } else if (source.startsWith('\\(', i)) {
      close = '\\)';
    } else if (ch === '$' && source.charAt(i - 1) !== '$' && /\S/.test(source.charAt(i + 1))) {
      close = '$';
      length = 1;
    }
    if (!close) { continue; }
    const end = findClosing(source, i + length, close, display);
    if (end < 0) { continue; }
    const latex = source.substring(i + length, end).trim();
    if (!latex) { continue; }
    const after = end + close.length;
    const token = prefix + fragments.length.toString() + '\uE001';
    parts.push(source.substring(copied, i));
    // Keep a standalone formula separate even if the model omits blank lines.
    const lineStart = source.lastIndexOf('\n', i - 1) + 1;
    const lineEnd = source.indexOf('\n', after);
    const standalone = display && !source.substring(lineStart, i).trim() &&
      !source.substring(after, lineEnd < 0 ? source.length : lineEnd).trim();
    parts.push(standalone ? '\n\n' + token + '\n\n' : token);
    fragments.push({ raw: source.substring(i, after), latex: latex, display: display });
    copied = after;
    i = after - 1;
  }
  parts.push(source.substring(copied));
  return { markdown: parts.join(''), prefix: prefix, fragments: fragments };
}

function escapeHtml(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function renderText(text: string, source: MathSource): string {
  const tokens = new RegExp(source.prefix + '([0-9]+)\uE001', 'g');
  return escapeHtml(text).replace(tokens, (token: string, number: string): string => {
    const fragment = source.fragments[Number(number)];
    if (!fragment) { return token; }
    const mode = fragment.display ? 'block' : 'inline';
    return '<span class="math-' + mode + '" data-tex="' + escapeHtml(fragment.latex) + '">' +
      escapeHtml(fragment.raw) + '</span>';
  });
}

function renderInlines(inlines: MarkdownInline[], fallback: string, source: MathSource, links: string[]): string {
  if (inlines.length === 0) { return renderText(fallback, source); }
  return inlines.map((inline: MarkdownInline): string => {
    if (inline.type === 'code') { return '<code>' + escapeHtml(inline.text) + '</code>'; }
    const text = renderText(inline.text, source);
    if (inline.type === 'strong') { return '<strong>' + text + '</strong>'; }
    if (inline.type === 'link') {
      const index = links.length;
      links.push(inline.href);
      return '<a href="#" data-link="' + index.toString() + '">' + text + '</a>';
    }
    return text;
  }).join('');
}

function renderCells(cells: string[], tag: string, source: MathSource): string {
  return '<tr>' + cells.map((cell: string): string => '<' + tag + '>' + renderText(cell, source) + '</' + tag + '>')
    .join('') + '</tr>';
}

function renderBlock(block: MarkdownBlock, source: MathSource, links: string[]): string {
  if (block.type === 'divider') { return '<hr>'; }
  if (block.type === 'code') { return '<pre><code>' + escapeHtml(block.text) + '</code></pre>'; }
  if (block.type === 'table') {
    return '<div class="table"><table><thead>' + renderCells(block.headers, 'th', source) + '</thead><tbody>' +
      block.rows.map((row: string[]): string => renderCells(row, 'td', source)).join('') + '</tbody></table></div>';
  }
  if (block.type === 'list') {
    const tag = block.ordered ? 'ol' : 'ul';
    const items: string[] = [];
    for (const item of block.items) {
      const value = block.ordered ? ' value="' + parseInt(item.marker, 10).toString() + '"' : '';
      items.push('<li' + value + '>' + renderInlines(item.inlines, item.text, source, links) + '</li>');
    }
    return '<' + tag + '>' + items.join('') + '</' + tag + '>';
  }
  const tag = block.type === 'heading' ? 'h' + block.level.toString() : block.type === 'quote' ? 'blockquote' : 'p';
  return '<' + tag + '>' + renderInlines(block.inlines, block.text, source, links) + '</' + tag + '>';
}

export function buildCodexMathDocument(text: string): CodexMathDocument | null {
  if (!text.includes('\\(') && !text.includes('\\[') && !text.includes('$')) { return null; }
  const source = extractMath(text);
  if (source.fragments.length === 0) { return null; }
  const links: string[] = [];
  const html = parseMarkdown(source.markdown).map((block: MarkdownBlock): string => renderBlock(block, source, links)).join('');
  if (!html.includes(' data-tex="')) { return null; }
  return { html: html, links: links };
}
