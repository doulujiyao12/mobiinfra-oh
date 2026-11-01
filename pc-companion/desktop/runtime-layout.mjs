import path from 'node:path';
import { installLayout } from '../host/paths.mjs';

// Portable Electron bundles may retain the upstream executable name. Electron's
// isPackaged flag alone must never send an installed app to the source-tree path.
export function desktopLayout({ resourcesPath, appPath, isPackaged }) {
  const installed = resourcesPath && appPath && ['app', 'app.asar'].some(name =>
    path.resolve(appPath) === path.resolve(resourcesPath, name));
  return installLayout(isPackaged || installed ? resourcesPath : undefined);
}
