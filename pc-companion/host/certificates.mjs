import { execFileSync } from 'node:child_process';
import os from 'node:os';
import { installLayout } from './paths.mjs';

export function lanAddresses() {
  const addresses = [];
  for (const values of Object.values(os.networkInterfaces())) {
    for (const value of values || []) if (value.family === 'IPv4' && !value.internal) addresses.push(value.address);
  }
  return [...new Set(addresses)].sort((a, b) => a.localeCompare(b));
}
// Native crypto/x509 is shipped in the launcher; users need no OpenSSL or system CA installation.
export function ensureCertificates(directory, addresses = lanAddresses(), launcher = installLayout().launcher) {
  return JSON.parse(execFileSync(launcher, ['--internal-certificates', directory, JSON.stringify(addresses)],
    { windowsHide: true, timeout: 20000, encoding: 'utf8', maxBuffer: 16000 }));
}
