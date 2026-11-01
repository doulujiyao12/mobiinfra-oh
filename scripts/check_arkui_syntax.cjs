// Parse original ArkUI source with the installed SDK's ETS parser. No builder
// masking, emit, Hvigor, signing, network, or device operations are performed.
// Usage: node scripts/check_arkui_syntax.cjs <sdk/openharmony/ets> [source.ets ...]
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const sdk = process.argv[2];
if (!sdk) { throw Error('Pass the installed SDK openharmony/ets directory.'); }
const loader = path.join(sdk, 'build-tools/ets-loader');
const ts = require(path.join(loader, 'node_modules/typescript'));
const root = path.resolve(__dirname, '..');
function etsFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const file = path.join(dir, entry.name);
    return entry.isDirectory() ? etsFiles(file) : file.endsWith('.ets') ? [file] : [];
  });
}
const uiFiles = ['components', 'pages'].flatMap(dir => etsFiles(path.join(root, 'entry/src/main/ets', dir)));
const sdkConfig = ts.readConfigFile(path.join(loader, 'tsconfig.json'), ts.sys.readFile);
if (sdkConfig.error) { throw Error('Cannot read installed SDK parser configuration.'); }
const ets = JSON.parse(JSON.stringify(sdkConfig.config.compilerOptions.ets));
const names = new Set(ets.components);
// UIDesignKit has SDK-provided containers such as HdsNavigation and HdsTabs.
for (const dir of [path.join(loader, 'components'), path.resolve(sdk, '../../hms/ets/build-tools/ets-loader/components')]) {
  if (!fs.existsSync(dir)) { continue; }
  for (const file of fs.readdirSync(dir).filter(name => name.endsWith('.json'))) {
    const component = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
    if (component.name) { names.add(component.name); }
  }
}
for (const file of uiFiles) {
  for (const match of fs.readFileSync(file, 'utf8').matchAll(/\bstruct\s+(\w+)/g)) { names.add(match[1]); }
}
ets.components = [...names];
const options = { ets };
function parse(file, text) { return ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, options); }

// A custom component call in an ordinary callback is valid JavaScript syntax,
// but the ArkUI lowering does not turn it into component creation. Calling the
// generated class as a function then crashes with "constructor ... without new".
// Keep UI construction in a named @Builder and delegate from builder callbacks.
function unsafeBuilderCalls(tree) {
  const errors = [];
  function visit(node) {
    if (ts.isPropertyAssignment(node) && ['contentBuilder', 'headerBuilder'].includes(node.name.getText(tree)) &&
      (ts.isArrowFunction(node.initializer) || ts.isFunctionExpression(node.initializer))) {
      function inspect(child) {
        if ((ts.isCallExpression(child) || ts.isEtsComponentExpression(child)) &&
          ts.isIdentifier(child.expression) && names.has(child.expression.text)) {
          errors.push({ start: child.getStart(tree), messageText:
            'UI component ' + child.expression.text + ' called in an ordinary builder callback; move it into a named @Builder.' });
        }
        ts.forEachChild(child, inspect);
      }
      inspect(node.initializer.body);
    }
    ts.forEachChild(node, visit);
  }
  visit(tree);
  return errors;
}

// Regression: a native container block in an ordinary object-property arrow is
// not a Builder. The previous body-masking semantic check hid this exact error.
const invalid = `@Component struct SyntaxProbe {
  build() { Column() { Panel({ contentBuilder: (): void => { Column() { Text('test') } } }) } }
}`;
const valid = `@Component struct SyntaxProbe {
  @Builder Content() { Column() { Text('test') } }
  build() { Column() { Panel({ contentBuilder: (): void => { this.Content(); } }) } }
}`;
assert.ok(parse('invalid.ets', invalid).parseDiagnostics.length > 0, 'Inline-container regression must be detected');
assert.equal(parse('valid.ets', valid).parseDiagnostics.length, 0, 'Named Builder must parse');
console.log('PASS inline container regression detected; named Builder accepted');

const runtimeInvalid = `@Component struct RuntimeProbe {
  build() { Column() { Panel({ contentBuilder: (): void => { CollectionSourceRow({ title: 'test' }); } }) } }
}`;
const runtimeValid = `@Component struct RuntimeProbe {
  @Builder Content() { CollectionSourceRow({ title: 'test' }) }
  build() { Column() { Panel({ contentBuilder: (): void => { this.Content(); } }) } }
}`;
const badRuntimeTree = parse('runtime-invalid.ets', runtimeInvalid);
assert.equal(badRuntimeTree.parseDiagnostics.length, 0, 'Crash regression must pass syntax parsing');
assert.equal(unsafeBuilderCalls(badRuntimeTree).length, 1, 'Bare component class call must be detected');
assert.equal(unsafeBuilderCalls(parse('runtime-valid.ets', runtimeValid)).length, 0, 'Named Builder delegation is safe');
console.log('PASS constructor-without-new regression detected despite valid syntax; Builder delegation accepted');

const files = process.argv.length > 3 ? process.argv.slice(3).map(file => path.resolve(root, file)) : uiFiles;
let failures = 0;
for (const file of files) {
  const tree = parse(file, fs.readFileSync(file, 'utf8'));
  for (const error of [...tree.parseDiagnostics, ...unsafeBuilderCalls(tree)]) {
    failures++;
    const position = tree.getLineAndCharacterOfPosition(error.start || 0);
    console.error(`${path.relative(root, file)}:${position.line + 1}:${position.character + 1} ` +
      ts.flattenDiagnosticMessageText(error.messageText, ' '));
  }
}
console.log(`ArkUI syntax and builder callbacks: ${files.length} original source files, ${failures} errors`);
process.exitCode = failures ? 1 : 0;
