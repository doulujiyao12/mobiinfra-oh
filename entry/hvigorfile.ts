import { Json5Reader } from '@ohos/hvigor';
import type { HvigorNode, HvigorPlugin } from '@ohos/hvigor';
import { hapTasks, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import type { OhosHapContext } from '@ohos/hvigor-ohos-plugin';

interface AppConfiguration {
  app?: {
    bundleName?: string;
  };
}

const shareBundleNamePlugin: HvigorPlugin = {
  pluginId: 'com.coevomind.bundle-identity',
  apply(node: HvigorNode): void {
    const appConfigPath = node.getNodeDir().getPath() + '/../AppScope/app.json5';
    const appConfig = Json5Reader.getJson5Obj(appConfigPath) as AppConfiguration;
    const bundleName = appConfig.app?.bundleName?.trim();
    if (!bundleName) {
      throw new Error(`Missing app.bundleName in ${appConfigPath}`);
    }

    const hapContext = node.getContext(OhosPluginId.OHOS_HAP_PLUGIN) as OhosHapContext;
    const moduleJson = hapContext.getModuleJsonOpt();
    const metadata = moduleJson.module.metadata ?? [];
    const shareBundleName = metadata.find((item) => item.name === 'shareBundleName');
    if (shareBundleName) {
      shareBundleName.value = bundleName;
    } else {
      metadata.push({
        name: 'shareBundleName',
        value: bundleName
      });
    }
    moduleJson.module.metadata = metadata;
    hapContext.setModuleJsonOpt(moduleJson);
  }
};

export default {
  system: hapTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [shareBundleNamePlugin]
}
