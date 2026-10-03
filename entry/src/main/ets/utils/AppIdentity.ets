import { bundleManager } from '@kit.AbilityKit';

let cachedBundleName: string = '';

/** Returns the bundle name installed for this app, sourced from AppScope/app.json5 at build time. */
export function getAppBundleName(): string {
  if (cachedBundleName.length > 0) {
    return cachedBundleName;
  }
  cachedBundleName = bundleManager.getBundleInfoForSelfSync(
    bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT
  ).name;
  return cachedBundleName;
}
