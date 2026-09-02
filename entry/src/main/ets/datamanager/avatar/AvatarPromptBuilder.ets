import { DataManagerStorage } from '../DataManagerStorage';
import {
  DOMAIN_DISPLAY_NAMES,
  ProfileClaim,
  ProfileDomainState,
  ProfileState
} from '../DataManagerTypes';
import { normalizeFreeText } from '../DataManagerUtils';
import {
  AvatarDomainSnapshot,
  AvatarGenerationMode,
  AvatarProfileSnapshot
} from './AvatarTypes';
import { stringifyJsonCompat } from '../../utils/JsonCompat';

const DEFAULT_AVATAR_GENDER: string = '男';
const DEFAULT_AVATAR_AGE: string = '';

export class AvatarPromptBuilder {
  private storage: DataManagerStorage;

  constructor(storage: DataManagerStorage) {
    this.storage = storage;
  }

  buildSnapshot(profile: ProfileState, completeness: number): AvatarProfileSnapshot {
    let domains: AvatarDomainSnapshot[] = [];
    ['eat', 'wear', 'live', 'travel'].forEach((domain: string) => {
      let doc = profile.domains[domain];
      domains.push(this.domainSnapshot(domain, doc));
    });
    let snapshot: AvatarProfileSnapshot = {
      generated_at: normalizeFreeText(profile.generated_at),
      event_count: profile.event_count,
      completeness: completeness,
      gender: DEFAULT_AVATAR_GENDER,
      age: DEFAULT_AVATAR_AGE,
      domains: domains,
      prompt_profile_text: this.promptProfileText(domains)
    };
    return snapshot;
  }

  snapshotHash(snapshot: AvatarProfileSnapshot): string {
    return this.storage.sha256Text(stringifyJsonCompat(snapshot as Object));
  }

  buildPrompt(snapshot: AvatarProfileSnapshot, mode: AvatarGenerationMode = 'text_to_image'): string {
    let lines: string[] = [
      '任务目标: 生成一张 4:3 横向首页场景图（home hero banner），画面主体是一个生动、温暖且极具表现力、亲和力的 3D 卡通风格个人数字形象，用于移动生活助手 App 的主页上方展示。'
    ];
    if (mode === 'image_to_image') {
      lines.push(this.photoReferencePrompt());
    }
    lines.push(
      '构图与姿态: 人物位于画面中心安全区，脸部和上半身清晰，姿态自然亲近；画面需要适配移动端首页横幅裁切，人物不要贴边，面部和关键上半身不要被裁切。',
      '场景与 profile 融合: 围绕人物自然融入适量 profile 相关物品和事项元素，让吃、穿、住、行画像中的具体内容成为场景道具、环境细节、服装配饰或桌面物件，整体形成一个自洽、整洁、有生活感的场景，而不是孤立证件照。',
      '细节与灵感（结合变量）: 请自然融入以下个人生活方式和描述，启发角色的服装、细微配饰、色彩倾向、环境道具和整体氛围。',
      this.supplementalProfileText(snapshot),
      '个人 profile 内容:',
      snapshot.prompt_profile_text,
      '约束：严格仅反映所提供的文本内容。profile 元素数量克制，只选择有证据、适合视觉化的物品或事项，避免堆砌。',
      '风格与灯光: 高品质现代 3D 动画风格（皮克斯/迪士尼灵感），精致、亲切，带有淡淡的未来感智能助手美学。柔和的光线，鲜艳但平衡的色彩。',
      '背景与排除项: 背景应是柔和、整洁、轻量的生活场景或智能助手空间，保留足够留白和层次，适合首页顶部横幅展示。除服务端添加的合规 AI 标识外，要求无其他文字、无其他水印、无 Logo、无繁杂的背景元素。'
    );
    return lines.join('\n');
  }

  private domainSnapshot(domain: string, doc: ProfileDomainState | undefined): AvatarDomainSnapshot {
    let claims: string[] = [];
    if (doc) {
      (doc.claims || []).forEach((claim: ProfileClaim) => {
        let statement = normalizeFreeText(claim.statement);
        if (statement.length > 0 && claims.length < 3) {
          claims.push(statement);
        }
      });
    }
    return {
      domain: domain,
      display_name: DOMAIN_DISPLAY_NAMES[domain] || domain,
      short_summary: doc ? normalizeFreeText(doc.short_summary) : '',
      summary: doc ? normalizeFreeText(doc.summary) : '',
      claims: claims,
      event_count: doc ? doc.event_count : 0
    };
  }

  private promptProfileText(domains: AvatarDomainSnapshot[]): string {
    let lines: string[] = [];
    domains.forEach((domain: AvatarDomainSnapshot) => {
      let parts: string[] = [];
      if (domain.short_summary.length > 0) {
        parts.push(domain.short_summary);
      }
      if (domain.summary.length > 0) {
        parts.push(domain.summary);
      }
      if (domain.claims.length > 0) {
        parts.push(domain.claims.join('；'));
      }
      lines.push(`${domain.display_name}: ${parts.join('；') || '暂无稳定画像'}`);
    });
    return lines.join('\n');
  }

  private supplementalProfileText(snapshot: AvatarProfileSnapshot): string {
    let parts: string[] = [];
    let gender = normalizeFreeText(snapshot.gender);
    if (gender === '男') {
      parts.push('gender=male');
    } else if (gender === '女') {
      parts.push('gender=female');
    } else if (gender.length > 0) {
      parts.push('gender=' + gender);
    }
    let age = normalizeFreeText(snapshot.age);
    if (age.length > 0) {
      parts.push('age=' + age);
    }
    return 'Supplemental demographic profile: ' + (parts.length > 0 ? parts.join(', ') : 'not specified');
  }

  private photoReferencePrompt(): string {
    return '参考照片约束: 当提供个人参考照片时，请以参考照片中的人物作为主要身份与形象基础：保留参考照片中的核心脸部特征、发型轮廓、年龄感、性别表达、整体气质和亲和力；将其转化为高品质现代 3D 卡通风格个人数字分身，而不是生成另一个陌生角色。个人 profile 内容只用于补充服装、配饰、色彩、生活方式氛围和细节灵感；不要让 profile 覆盖或替换参考照片中的人物身份特征。忽略参考照片中的背景、无关人物、文字、水印和杂乱物体。';
  }
}
