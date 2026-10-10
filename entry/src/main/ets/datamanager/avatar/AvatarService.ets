import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { DataManagerPaths } from '../DataManagerPaths';
import { DataManagerStorage } from '../DataManagerStorage';
import { dataManagerWarn } from '../DataManagerLog';
import { ProfileState } from '../DataManagerTypes';
import { nowIsoLocal } from '../DataManagerUtils';
import { AvatarPromptBuilder } from './AvatarPromptBuilder';
import { AvatarForegroundService } from './AvatarForegroundService';
import { AvatarStorage } from './AvatarStorage';
import { SeedreamAvatarProvider } from './SeedreamAvatarProvider';
import {
  AvatarGenerateRequest,
  AvatarGenerationMode,
  AvatarGenerationParams,
  AvatarHomeViewModel,
  AvatarProviderConfig,
  AvatarProviderRequest,
  AvatarProviderResult,
  AvatarState,
  AvatarVersionState,
  AvatarVersionViewModel,
  avatarErrorMessage
} from './AvatarTypes';

export class AvatarService {
  private avatarStorage: AvatarStorage;
  private foregroundService: AvatarForegroundService;
  private promptBuilder: AvatarPromptBuilder;
  private provider: SeedreamAvatarProvider;

  constructor(paths: DataManagerPaths, storage: DataManagerStorage) {
    this.avatarStorage = new AvatarStorage(paths, storage);
    this.foregroundService = new AvatarForegroundService(paths, storage, this.avatarStorage);
    this.promptBuilder = new AvatarPromptBuilder(storage);
    this.provider = new SeedreamAvatarProvider();
  }

  ensureReady(): void {
    this.avatarStorage.ensureReady();
  }

  homeView(profile: ProfileState, completeness: number): AvatarHomeViewModel {
    this.ensureReady();
    let state = this.avatarStorage.loadState();
    let latestHash = profile.event_count > 0 ? this.previewProfileSnapshotHash(profile, completeness) : '';
    state = this.recoverFailedStateFromLatestSavedVersion(state, latestHash);
    if (profile.event_count > 0 && state.current_version_id.length > 0) {
      if (state.status === 'current' && latestHash !== state.profile_snapshot_hash) {
        state.status = 'stale';
        state.updated_at = nowIsoLocal();
        this.avatarStorage.saveState(state);
      }
    }
    let currentVersion = this.avatarStorage.loadVersion(state.current_version_id);
    return this.avatarStorage.homeViewFromState(state, currentVersion);
  }

  private recoverFailedStateFromLatestSavedVersion(state: AvatarState, latestHash: string): AvatarState {
    if (state.status !== 'failed' || latestHash.length === 0) {
      return state;
    }
    let versions = this.avatarStorage.listVersions();
    if (versions.length === 0) {
      return state;
    }
    let latestVersion = versions[0];
    if (latestVersion.version_id === state.current_version_id || latestVersion.image_path.length === 0 ||
      latestVersion.profile_snapshot_hash !== latestHash) {
      return state;
    }
    let recoveredState: AvatarState = {
      current_version_id: latestVersion.version_id,
      profile_snapshot_hash: latestVersion.profile_snapshot_hash,
      status: 'current',
      last_error_code: '',
      last_error_message: '',
      updated_at: latestVersion.created_at,
      reference_photo_path: state.reference_photo_path
    };
    // 兼容旧版本 bug：主图已写入历史版本后，派生前景抠图失败曾把状态误写为 failed。
    this.avatarStorage.saveState(recoveredState);
    dataManagerWarn('Avatar failed state recovered from latest saved version: ' + latestVersion.version_id);
    return recoveredState;
  }

  previewProfileSnapshotHash(profile: ProfileState, completeness: number): string {
    return this.promptBuilder.snapshotHash(this.promptBuilder.buildSnapshot(profile, completeness));
  }

  isCurrentProfileSnapshotUnchanged(profile: ProfileState, completeness: number): boolean {
    this.ensureReady();
    let state = this.avatarStorage.loadState();
    if (state.current_version_id.length === 0 || state.profile_snapshot_hash.length === 0) {
      return false;
    }
    return this.previewProfileSnapshotHash(profile, completeness) === state.profile_snapshot_hash;
  }

  listVersionViewModels(): AvatarVersionViewModel[] {
    this.ensureReady();
    return this.avatarStorage.listVersionViewModels();
  }

  currentHomeView(): AvatarHomeViewModel {
    this.ensureReady();
    return this.avatarStorage.currentHomeView();
  }

  async saveReferencePhoto(sourceUri: string): Promise<AvatarHomeViewModel> {
    this.ensureReady();
    let normalized = sourceUri.trim();
    if (normalized.length === 0) {
      throw new Error('请先选择参考照片');
    }
    // 选择器 URI 的读权限不一定长期有效，保存时转成应用沙箱内的 JPEG 缓存供下次打开复用。
    let bytes = await this.encodeReferencePhotoToJpeg(normalized);
    let relativePath = this.avatarStorage.saveReferencePhotoBytes(bytes, 'reference.jpg');
    let state = this.avatarStorage.loadState();
    state.reference_photo_path = relativePath;
    this.avatarStorage.saveState(state);
    return this.avatarStorage.homeViewFromState(state, this.avatarStorage.loadVersion(state.current_version_id));
  }

  async ensureCurrentForeground(): Promise<AvatarHomeViewModel> {
    this.ensureReady();
    let state = this.avatarStorage.loadState();
    let currentVersion = this.avatarStorage.loadVersion(state.current_version_id);
    if (currentVersion !== null && currentVersion.image_path.length > 0) {
      let foregroundMissing: boolean = !this.avatarStorage.foregroundExists(currentVersion.version_id);
      let messageForegroundMissing: boolean = !this.avatarStorage.messageForegroundExists(currentVersion.version_id);
      if (foregroundMissing || messageForegroundMissing) {
        await this.ensureForegroundBestEffort(currentVersion);
      }
    }
    let latestState = this.avatarStorage.loadState();
    let latestVersion = this.avatarStorage.loadVersion(latestState.current_version_id);
    return this.avatarStorage.homeViewFromState(latestState, latestVersion);
  }

  buildGenerateRequest(profile: ProfileState, completeness: number, mode: AvatarGenerationMode,
    sourceImage: string, consentedAt: string, photoSource?: string): AvatarGenerateRequest {
    let snapshot = this.promptBuilder.buildSnapshot(profile, completeness);
    let consentPhotoSource = photoSource === undefined ? sourceImage : photoSource;
    return {
      mode: mode,
      prompt: this.promptBuilder.buildPrompt(snapshot, mode),
      sourceImage: sourceImage,
      profileSnapshot: snapshot,
      profileSnapshotHash: this.promptBuilder.snapshotHash(snapshot),
      consent: {
        mode: mode,
        photo_used: mode === 'image_to_image' && sourceImage.trim().length > 0,
        consented_at: consentedAt,
        photo_source: consentPhotoSource
      }
    };
  }

  async generate(config: AvatarProviderConfig, request: AvatarGenerateRequest): Promise<AvatarHomeViewModel> {
    this.ensureReady();
    let previousState = this.avatarStorage.loadState();
    let generatingState: AvatarState = {
      current_version_id: previousState.current_version_id,
      profile_snapshot_hash: previousState.profile_snapshot_hash,
      status: 'generating',
      last_error_code: '',
      last_error_message: '',
      updated_at: nowIsoLocal(),
      reference_photo_path: previousState.reference_photo_path
    };
    this.avatarStorage.saveState(generatingState);

    try {
      let params: AvatarGenerationParams = {
        size: config.size,
        response_format: config.responseFormat,
        output_format: config.outputFormat,
        sequential_image_generation: config.sequentialImageGeneration,
        stream: config.stream,
        // 数字分身属于 AI 生成图片，始终请求服务端水印，避免历史配置关闭标识。
        watermark: true
      };
      let model = request.mode === 'image_to_image' ? config.imageToImageModel : config.textToImageModel;
      let providerRequest: AvatarProviderRequest = {
        prompt: request.prompt,
        sourceImage: request.sourceImage,
        model: model,
        params: params
      };
      let result: AvatarProviderResult = request.mode === 'image_to_image' ?
        await this.provider.generateImageToImage(config, providerRequest) :
        await this.provider.generateTextToImage(config, providerRequest);
      if (result.imageBytesBase64.trim().length === 0) {
        throw new Error('Avatar provider returned empty image data');
      }

      let versionId = this.nextVersionId();
      let createdAt = nowIsoLocal();
      let imagePath = this.avatarStorage.saveAssetBase64(versionId, result.imageBytesBase64, params.output_format);
      let version: AvatarVersionState = {
        version_id: versionId,
        created_at: createdAt,
        image_path: imagePath,
        thumbnail_path: '',
        mode: request.mode,
        provider: 'seedream',
        model: model,
        generation_params: params,
        prompt_snapshot: request.prompt,
        profile_snapshot: request.profileSnapshot,
        profile_snapshot_hash: request.profileSnapshotHash,
        consent_snapshot: request.consent
      };
      this.avatarStorage.saveVersion(version);
      let currentState: AvatarState = {
        current_version_id: versionId,
        profile_snapshot_hash: request.profileSnapshotHash,
        status: 'current',
        last_error_code: '',
        last_error_message: '',
        updated_at: createdAt,
        reference_photo_path: previousState.reference_photo_path
      };
      this.avatarStorage.saveState(currentState);
      await this.ensureForegroundBestEffort(version);
      return this.avatarStorage.homeViewFromState(currentState, version);
    } catch (e) {
      let message = avatarErrorMessage(e as Error | Object | string | number | boolean | null | undefined,
        'Avatar generation failed');
      let failedState: AvatarState = {
        current_version_id: previousState.current_version_id,
        profile_snapshot_hash: previousState.profile_snapshot_hash,
        status: 'failed',
        last_error_code: 'AVATAR_GENERATE_FAILED',
        last_error_message: message,
        updated_at: nowIsoLocal(),
        reference_photo_path: previousState.reference_photo_path
      };
      this.avatarStorage.saveState(failedState);
      throw new Error(message);
    }
  }

  private async ensureForegroundBestEffort(version: AvatarVersionState): Promise<void> {
    try {
      // 前景图是由版本原图派生出的透明 PNG 缓存，生成失败不能反向影响数字分身主图状态。
      await this.foregroundService.ensureForegroundForVersion(version.version_id, version.image_path);
    } catch (e) {
      dataManagerWarn('Avatar foreground best effort failed: ' +
        avatarErrorMessage(e as Error | Object | string | number | boolean | null | undefined,
          'unknown foreground error'));
    }
  }

  private async encodeReferencePhotoToJpeg(uri: string): Promise<Uint8Array> {
    let imageFile: fileIo.File | null = null;
    let imageSource: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      imageFile = await fileIo.open(this.fileIoOpenTarget(uri), fileIo.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(imageFile.fd);
      pixelMap = await imageSource.createPixelMap();
      packer = image.createImagePacker();
      let data = await packer.packToData(pixelMap, {
        format: 'image/jpeg',
        quality: 92
      });
      return new Uint8Array(data);
    } catch (e) {
      let err = e as Error;
      throw err;
    } finally {
      if (packer !== null) {
        try {
          await packer.release();
        } catch (e) {
        }
      }
      if (pixelMap !== null) {
        try {
          await pixelMap.release();
        } catch (e) {
        }
      }
      if (imageSource !== null) {
        try {
          await imageSource.release();
        } catch (e) {
        }
      }
      if (imageFile !== null) {
        try {
          await fileIo.close(imageFile);
        } catch (e) {
        }
      }
    }
  }

  private fileIoOpenTarget(uri: string): string {
    let normalized = uri.trim();
    if (normalized.startsWith('file:///')) {
      return normalized.substring('file://'.length);
    }
    return normalized;
  }

  private nextVersionId(): string {
    return 'avatar-' + String(Date.now()) + '-' + String(Math.floor(Math.random() * 1000000));
  }
}
