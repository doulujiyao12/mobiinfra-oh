import { JSON as ArkJSON } from '@kit.ArkTS';

// Same app aliases as harmony_agent.py; the PC source remains untouched.
const APP_BUNDLES: Record<string, string> = {
  '携程': 'com.ctrip.harmonynext', '携程旅行': 'com.ctrip.harmonynext', '飞猪': 'com.fliggy.hmos',
  '飞猪旅行': 'com.fliggy.hmos', 'IntelliOS': 'ohos.hongmeng.intellios', '同城': 'com.tongcheng.hmos',
  '饿了么': 'me.ele.eleme', '知乎': 'com.zhihu.hmos', '哔哩哔哩': 'yylx.danmaku.bili',
  '微信': 'com.tencent.wechat', '小红书': 'com.xingin.xhs_hos', 'QQ音乐': 'com.tencent.hm.qqmusic',
  '高德地图': 'com.amap.hmapp', '淘宝': 'com.taobao.taobao4hmos', '微博': 'com.sina.weibo.stage',
  '京东': 'com.jd.hm.mall', '天气': 'com.huawei.hmsapp.totemweather', '什么值得买': 'com.smzdm.client.hmos',
  '闲鱼': 'com.taobao.idlefish4ohos', '慧通差旅': 'com.smartcom.itravelhm', 'PowerAgent': 'com.example.osagent',
  '航旅纵横': 'com.umetrip.hm.app', '滴滴出行': 'com.sdu.didi.hmos.psnger', '电子邮件': 'com.huawei.hmos.email',
  '图库': 'com.huawei.hmos.photos', '日历': 'com.huawei.hmos.calendar', '心声社区': 'com.huawei.it.hmxinsheng',
  '信息': 'com.ohos.mms', '文件管理': 'com.huawei.hmos.files', '运动健康': 'com.huawei.hmos.health',
  '智慧生活': 'com.huawei.hmos.ailife', '豆包': 'com.larus.nova.hm', 'WeLink': 'com.huawei.it.welink',
  '设置': 'com.huawei.hmos.settings', '懂车帝': 'com.ss.dcar.auto', '美团外卖': 'com.meituan.takeaway',
  '大众点评': 'com.sankuai.dianping', '美团': 'com.sankuai.hmeituan', '浏览器': 'com.huawei.hmos.browser',
  '拼多多': 'com.xunmeng.pinduoduo.hos', '支付宝': 'com.alipay.mobile.client'
};

export function phoneHdcBundle(appName: string, packageName: string): string {
  let candidates = [packageName.trim(), appName.trim()];
  for (let index = 0; index < candidates.length; index++) {
    let candidate = APP_BUNDLES[candidates[index]] || candidates[index];
    if (/^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$/.test(candidate)) { return candidate; }
  }
  throw new Error('PHONE_HDC_APP: cannot resolve bundleName for ' + appName);
}

interface PhoneAppSkill { actions?: string[]; entities?: string[]; }
interface PhoneAppAbility { name?: string; moduleName?: string; skills?: PhoneAppSkill[]; }
interface PhoneAppModule {
  name?: string;
  moduleName?: string;
  mainAbility?: string;
  mainAbilityName?: string;
  mainElementName?: string;
  abilityInfos?: PhoneAppAbility[];
  abilities?: PhoneAppAbility[];
}
interface PhoneAppDump { mainEntry?: string; moduleInfos?: PhoneAppModule[]; hapModuleInfos?: PhoneAppModule[]; }

function abilityName(value?: string): string {
  return typeof value === 'string' && /^[A-Za-z_$][A-Za-z0-9_.$]*$/.test(value) ? value : '';
}

export function phoneHdcMainAbility(output: string): string {
  let start = output.indexOf('{'); let end = output.lastIndexOf('}');
  if (start < 0 || end <= start) {
    // Some bm versions expose the main entry as text rather than JSON. Only accept an explicit field.
    let match = /^\s*["']?(?:mainAbility|mainAbilityName|mainElementName)["']?\s*[:=]\s*["']?([A-Za-z_$][A-Za-z0-9_.$]*)["']?\s*,?\s*$/m.exec(output);
    if (match && abilityName(match[1])) { return match[1]; }
    throw new Error('PHONE_HDC_APP: bm dump did not return bundle metadata');
  }
  let info = ArkJSON.parse(output.substring(start, end + 1)) as PhoneAppDump;
  let modules = info.hapModuleInfos || info.moduleInfos || [];
  let selected = ''; let selectedScore = -1;
  for (let module of modules) {
    let main = abilityName(module.mainElementName || module.mainAbility || module.mainAbilityName);
    let moduleScore = (module.moduleName || module.name) === info.mainEntry && !!info.mainEntry ? 1 : 0;
    for (let ability of module.abilityInfos || module.abilities || []) {
      let name = abilityName(ability.name);
      if (!name) { continue; }
      let score = (name === main ? 1 : 0) +
        (ability.moduleName === info.mainEntry && !!info.mainEntry ? 1 : moduleScore);
      for (let skill of ability.skills || []) {
        if ((skill.actions || []).indexOf('action.system.home') >= 0) {
          score += 10; break;
        }
      }
      // Prefer a launcher, then the main ability and entry module, as the PC driver does.
      if (score > selectedScore && (score >= 10 || name === main)) { selected = name; selectedScore = score; }
    }
    if (main && moduleScore > selectedScore) { selected = main; selectedScore = moduleScore; }
  }
  if (selected) { return selected; }
  throw new Error('PHONE_HDC_APP: bundle metadata has no main UIAbility; refusing to guess EntryAbility');
}
