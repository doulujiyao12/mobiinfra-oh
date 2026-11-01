import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { JSON as ArkJSON } from '@kit.ArkTS';
import {
  normalizeWechatAutoSummaryMode,
  WECHAT_AUTO_SUMMARY_COLLECTION_DAYS_INPUT_KEY,
  WECHAT_AUTO_SUMMARY_COLLECTION_MAX_CONTACTS_INPUT_KEY,
  WECHAT_AUTO_SUMMARY_COLLECTION_MODE_KEY,
  WECHAT_AUTO_SUMMARY_COLLECTION_TARGET_CONTACT_INPUT_KEY,
  WECHAT_AUTO_SUMMARY_MODE_RECENT
} from './WechatAutoSummaryTypes';

export class WechatCollectionForm {
  mode: string = WECHAT_AUTO_SUMMARY_MODE_RECENT;
  daysInput: string = '';
  maxContactsInput: string = '';
  targetContactInput: string = '';
}

// Flush explicitly before launching another App. Preserve raw input, including an
// intentional blank field, so that neither page recreation nor a restart resets it.
export class WechatAutoSummarySettings {
  private static store(context: common.Context): preferences.Preferences {
    return preferences.getPreferencesSync(context, { name: 'wechat_collection_settings' });
  }

  private static legacyText(key: string, fallback: string = ''): string {
    let value = AppStorage.get<string>(key);
    return typeof value === 'string' ? value : fallback;
  }

  static load(context: common.Context): WechatCollectionForm {
    let raw = WechatAutoSummarySettings.store(context).getSync('form', '');
    let form = new WechatCollectionForm();
    if (raw === '') {
      // One-time migration from the existing PersistentStorage/AppStorage keys.
      form.mode = normalizeWechatAutoSummaryMode(WechatAutoSummarySettings.legacyText(
        WECHAT_AUTO_SUMMARY_COLLECTION_MODE_KEY, WECHAT_AUTO_SUMMARY_MODE_RECENT));
      form.daysInput = WechatAutoSummarySettings.legacyText(WECHAT_AUTO_SUMMARY_COLLECTION_DAYS_INPUT_KEY);
      form.maxContactsInput = WechatAutoSummarySettings.legacyText(WECHAT_AUTO_SUMMARY_COLLECTION_MAX_CONTACTS_INPUT_KEY);
      form.targetContactInput = WechatAutoSummarySettings.legacyText(WECHAT_AUTO_SUMMARY_COLLECTION_TARGET_CONTACT_INPUT_KEY);
      WechatAutoSummarySettings.save(context, form);
      return form;
    }
    if (typeof raw !== 'string') { throw new Error('微信采集参数格式无效'); }
    let saved = ArkJSON.parse(raw) as WechatCollectionForm;
    if (!saved || typeof saved.mode !== 'string' || typeof saved.daysInput !== 'string' ||
      typeof saved.maxContactsInput !== 'string' || typeof saved.targetContactInput !== 'string') {
      throw new Error('微信采集参数不完整，请重新填写并保存');
    }
    form.mode = normalizeWechatAutoSummaryMode(saved.mode);
    form.daysInput = saved.daysInput;
    form.maxContactsInput = saved.maxContactsInput;
    form.targetContactInput = saved.targetContactInput;
    return form;
  }

  static save(context: common.Context, form: WechatCollectionForm): void {
    let store = WechatAutoSummarySettings.store(context);
    store.putSync('form', ArkJSON.stringify(form));
    store.flushSync();
  }
}
