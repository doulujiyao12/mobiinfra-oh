// Read-only SDK syntax/API checks. Does not run Hvigor, native build or package a HAP.
// node scripts/check_recording_sdk.cjs "D:/download/deveco/DevEco Studio/sdk/default"
const fs = require('node:fs'), path = require('node:path');
const {recordingArktsRules} = require('./recording_arkts_rules.cjs');
const sdkRoot = process.argv[2];
if (!sdkRoot) { console.error('Usage: node scripts/check_recording_sdk.cjs <HarmonyOS SDK/default directory>'); process.exit(2); }
const sdk = path.resolve(sdkRoot, 'openharmony/ets'), hms = path.resolve(sdkRoot, 'hms/ets');
const ts = require(path.join(sdk, 'build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
const options = {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.ESNext, strict: true,
  noEmit: true, skipLibCheck: true, allowNonTsExtensions: true, esModuleInterop: true,
  experimentalDecorators: true, lib: ['lib.es2021.d.ts'],
  ets: ts.parseConfigFileTextToJson('sdk', fs.readFileSync(path.join(sdk,'build-tools/ets-loader/tsconfig.json'),'utf8')).config.compilerOptions.ets
};
const host = ts.createCompilerHost(options), original = host.getSourceFile;
host.getSourceFile = (file, version, onError) => file.endsWith('.ets') ?
  ts.createSourceFile(file,fs.readFileSync(file,'utf8'),version,true,ts.ScriptKind.ETS,options) : original(file,version,onError);
host.resolveModuleNames = (names, containing) => names.map(name => {
  let found;
  if (name.startsWith('.')) {
    found = ['.ets','.d.ts','.d.ets'].map(ext=>path.resolve(path.dirname(containing),name+ext)).find(fs.existsSync);
  } else if (name === 'sherpa_onnx') {
    found = path.join(root,'entry/oh_modules/sherpa_onnx/Index.ets');
  } else if (name === 'libsherpa_onnx.so') {
    found = path.join(root,'entry/oh_modules/sherpa_onnx/src/main/cpp/types/libsherpa_onnx/Index.d.ts');
  } else if (name === 'libentry.so') {
    found = path.join(root,'entry/src/main/cpp/types/libentry/Index.d.ts');
  } else {
    found = [sdk+'/kits/'+name+'.d.ts',hms+'/kits/'+name+'.d.ts',sdk+'/api/'+name+'.d.ts',hms+'/api/'+name+'.d.ts',hms+'/api/'+name+'.d.ets'].find(fs.existsSync);
  }
  return found && fs.existsSync(found) ? {resolvedFileName:found,extension:found.endsWith('.d.ts')?ts.Extension.Dts:ts.Extension.Ts} : undefined;
});
const files = fs.readdirSync(path.join(root,'entry/src/main/ets/utils/recording'))
  .filter(f=>f.endsWith('.ets')).map(f=>path.join(root,'entry/src/main/ets/utils/recording',f));
files.push(path.join(root,'entry/src/main/ets/workers/RecordingAnalysisWorker.ets'),
  path.join(root,'entry/src/main/ets/workers/RecordingLiveWorker.ets'),
  path.join(root,'entry/src/main/ets/pages/recording/RecordingPage.ets'),
  path.join(root,'entry/src/main/ets/pages/recording/RecordingSummaryView.ets'),
  path.join(root,'entry/src/main/ets/utils/LocalTextInference.ets'),
  path.join(root,'entry/src/main/ets/utils/AppBackgroundTasks.ets'));
const authored = new Set(files.map(f=>path.resolve(f).replaceAll('\\','/')));
const syntax = [];
for (const file of files) {
  const parsed = host.getSourceFile(file,ts.ScriptTarget.ES2021);
  syntax.push(...parsed.parseDiagnostics);
  syntax.push(...recordingArktsRules(ts,parsed));
}
files.push(...fs.readdirSync(sdk+'/component').filter(f=>f.endsWith('.d.ts')).map(f=>sdk+'/component/'+f));
files.push(sdk+'/build-tools/ets-loader/declarations/global.d.ts');
const program = ts.createProgram(files,options,host);
const errors = [...syntax,...ts.getPreEmitDiagnostics(program)].filter(d=>d.category===ts.DiagnosticCategory.Error &&
  d.file && authored.has(path.resolve(d.file.fileName).replaceAll('\\','/')));
for (const d of errors) {
  const p = d.file.getLineAndCharacterOfPosition(d.start);
  console.error(path.relative(root,d.file.fileName)+':'+(p.line+1)+':'+(p.character+1),ts.flattenDiagnosticMessageText(d.messageText,' '));
}
console.log(`Recording SDK syntax/API and focused ArkTS rule errors: ${errors.length}. This does not replace an ArkTS build or device verification.`);
process.exitCode = errors.length ? 1 : 0;
