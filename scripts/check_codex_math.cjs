// Node-only checks of formula extraction, real KaTeX output and the offline assets.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const root = path.join(__dirname, '..', 'entry', 'src', 'main');
const sourceDir = path.join(root, 'ets', 'utils', 'markdown');
const assets = path.join(root, 'resources', 'rawfile', 'codex_math');

function load(name) {
  const filename = path.join(sourceDir, name + '.ets');
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    fileName: filename + '.ts', reportDiagnostics: true
  });
  assert.equal(result.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const module = { exports: {} };
  vm.runInNewContext(result.outputText, { exports: module.exports, require: id => load(path.basename(id)) });
  return module.exports;
}

const { buildCodexMathDocument } = load('CodexMathDocument');
assert.equal(buildCodexMathDocument('普通 Markdown **标题**'), null);
assert.equal(buildCodexMathDocument('价格 $5 或 $10'), null);
assert.equal(buildCodexMathDocument('价格 \\$5 与开放的 \\(x'), null);
assert.equal(buildCodexMathDocument('```tex\n\\[x^2\\]\n```\n`$y$`'), null);

const example = String.raw`质数列表
\[
2,\ 3,\ 5,\ 7,\dots
\]
例如：
\[ 60=2^2\times3\times5. \]

**不超过某个数 \(x\) 的质数**记作 \(\pi(x)\)。另见 $x_1$。

| \(x\) | 质数个数 $\pi(x)$ |
| --- | --- |
| 10 | 4 |

$$\frac{1}{2}+\sqrt{x}$$

<script>alert(1)</script> [详情](https://example.com) ` + '`$leave_this_alone$`';
const doc = buildCodexMathDocument(example);
assert.match(doc.html, /<p><span class="math-block" data-tex="2,/);
assert.match(doc.html, /<strong>不超过某个数 <span class="math-inline" data-tex="x">/);
assert.match(doc.html, /<th><span class="math-inline" data-tex="x">/);
assert.match(doc.html, /<code>\$leave_this_alone\$<\/code>/);
assert.match(doc.html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
assert.doesNotMatch(doc.html, /https:\/\/example.com|<script>/);
assert.deepEqual(Array.from(doc.links), ['https://example.com']);

const katex = require(path.join(assets, 'katex.min.js'));
let onClick;
const opened = [];
const mathNodes = [
  { dataset: { tex: String.raw`60=2^2\times3\times5` }, innerHTML: '', classList: { contains: () => true } },
  { dataset: { tex: String.raw`\frac{1}{\sqrt{x}}` }, innerHTML: '', classList: { contains: () => false } },
  { dataset: { tex: String.raw`\unknown{x}` }, innerHTML: '保留原式', classList: { contains: () => false } }
];
for (const node of mathNodes) node.removeAttribute = () => {};
const element = { innerHTML: '', querySelectorAll: () => mathNodes, addEventListener: (_, handler) => { onClick = handler; } };
const document = { getElementById: () => element, body: { classList: { toggle: () => {} } } };
const window = { katex, codexMathLinks: { open: (...args) => opened.push(args) } };
vm.runInNewContext(fs.readFileSync(path.join(assets, 'message.js'), 'utf8'), { document, window });
window.renderCodexMath(doc.html, 42, false);
assert.match(mathNodes[0].innerHTML, /katex-display/);
assert.match(mathNodes[0].innerHTML, /×/);
assert.match(mathNodes[1].innerHTML, /mfrac/);
assert.match(mathNodes[1].innerHTML, /sqrt/);
assert.equal(mathNodes[2].innerHTML, '保留原式');
onClick({ target: { closest: () => ({ dataset: { link: '0' } }) }, preventDefault() {} });
assert.deepEqual(opened, [[0, 42]]);
for (const match of fs.readFileSync(path.join(assets, 'katex.min.css'), 'utf8').matchAll(/url\((fonts\/[^)]+)\)/g)) {
  assert.ok(fs.existsSync(path.join(assets, match[1])), match[1]);
}
console.log('Codex math checks passed: inline/display delimiters, tables, code, literal HTML, links, KaTeX and local fonts.');
