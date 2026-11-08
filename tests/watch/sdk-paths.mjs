import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

export function loadSdkTypeScript() {
  const deveco = process.env.DEVECO_HOME;
  if (!deveco) { throw new Error('Set DEVECO_HOME to your DevEco Studio directory before running SDK integration tests.'); }
  const compiler = path.join(deveco,
    'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js');
  if (!fs.existsSync(compiler)) { throw new Error('DevEco SDK TypeScript compiler not found. Check DEVECO_HOME and installed SDK components.'); }
  return require(compiler);
}
