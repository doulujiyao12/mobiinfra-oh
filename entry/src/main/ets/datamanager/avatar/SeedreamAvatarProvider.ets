import { http } from '@kit.NetworkKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { parseJsonCompat } from '../../utils/JsonCompat';
import {
  AvatarGenerationParams,
  AvatarProviderConfig,
  AvatarProviderRequest,
  AvatarProviderResult,
  AvatarStringMap,
  createEmptyRawMetadata
} from './AvatarTypes';

export type SeedreamRequestBody = Record<string, Object | string | number | boolean | null>;

interface SeedreamDataItem {
  url?: string;
  b64_json?: string;
}

interface SeedreamResponse {
  id?: string;
  data?: SeedreamDataItem[];
}

function seedreamFirstDataString(raw: string, key: string): string {
  let parsed = parseJsonCompat<Record<string, Object | string | number | boolean | null>>(raw);
  let data = parsed['data'];
  if (!Array.isArray(data)) {
    return '';
  }
  if (data.length === 0) {
    return '';
  }
  let first: Object | string | number | boolean | null = data[0];
  if (first === null || typeof first !== 'object') {
    return '';
  }
  let item = first as Record<string, Object | string | number | boolean | null>;
  let value = item[key];
  if (typeof value !== 'string') {
    return '';
  }
  return value.trim();
}

function seedreamSupportsOutputFormat(model: string): boolean {
  return model.toLowerCase().indexOf('seedream-4-5') < 0;
}

export function createSeedreamRequestBody(model: string, prompt: string, image: string,
  params: AvatarGenerationParams): SeedreamRequestBody {
  let body = new Object() as SeedreamRequestBody;
  body['model'] = model;
  body['prompt'] = prompt;
  body['sequential_image_generation'] = params.sequential_image_generation;
  body['response_format'] = params.response_format;
  let outputFormat = params.output_format.trim();
  if (outputFormat.length > 0 && seedreamSupportsOutputFormat(model)) {
    body['output_format'] = outputFormat;
  }
  body['size'] = params.size;
  body['stream'] = params.stream;
  // 防御性强制开启：即使调用方传入旧配置，AI 生成图片也必须保留服务端水印。
  body['watermark'] = true;
  let normalizedImage = image.trim();
  if (normalizedImage.length > 0) {
    body['image'] = normalizedImage;
  }
  return body;
}

export function normalizeSeedreamImageUrl(raw: string): string {
  return seedreamFirstDataString(raw, 'url');
}

export function normalizeSeedreamImageBase64(raw: string): string {
  return seedreamFirstDataString(raw, 'b64_json');
}

export class SeedreamAvatarProvider {
  async generateTextToImage(config: AvatarProviderConfig, request: AvatarProviderRequest): Promise<AvatarProviderResult> {
    return this.generate(config, request, '');
  }

  async generateImageToImage(config: AvatarProviderConfig, request: AvatarProviderRequest): Promise<AvatarProviderResult> {
    let sourceImage = request.sourceImage.trim();
    if (sourceImage.length === 0) {
      throw new Error('Seedream image-to-image requires a source image');
    }
    return this.generate(config, request, sourceImage);
  }

  async downloadImageToBase64(url: string, timeoutMs: number): Promise<string> {
    let normalizedUrl = url.trim();
    if (normalizedUrl.length === 0) {
      throw new Error('Seedream image download URL is empty');
    }
    let requestOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      connectTimeout: 10000,
      readTimeout: timeoutMs,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    };

    let httpReq = http.createHttp();
    try {
      let response = await httpReq.request(normalizedUrl, requestOptions);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`Seedream image download HTTP ${response.responseCode}: ${response.result}`);
      }
      let bytes = new Uint8Array(response.result as ArrayBuffer);
      let helper = new util.Base64Helper();
      return helper.encodeToStringSync(bytes);
    } catch (e) {
      let err = e as Error;
      throw err;
    } finally {
      httpReq.destroy();
    }
  }

  private async generate(config: AvatarProviderConfig, request: AvatarProviderRequest,
    image: string): Promise<AvatarProviderResult> {
    let imageBaseUrl = config.imageBaseUrl.trim();
    if (imageBaseUrl.length === 0) {
      throw new Error('Seedream image base URL is empty');
    }
    let apiKey = config.apiKey.trim();
    if (apiKey.length === 0) {
      throw new Error('Seedream API key is empty');
    }
    let prompt = request.prompt.trim();
    if (prompt.length === 0) {
      throw new Error('Seedream prompt is empty');
    }
    let model = request.model.trim();
    if (model.length === 0) {
      model = image.length > 0 ? config.imageToImageModel.trim() : config.textToImageModel.trim();
    }
    if (model.length === 0) {
      throw new Error('Seedream model is empty');
    }

    let body = createSeedreamRequestBody(model, prompt, image, request.params);
    let headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + apiKey
    };
    let requestOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: ArkJSON.stringify(body as Object),
      connectTimeout: 10000,
      readTimeout: config.timeoutMs,
      expectDataType: http.HttpDataType.STRING
    };

    let httpReq = http.createHttp();
    try {
      let response = await httpReq.request(imageBaseUrl, requestOptions);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`Seedream HTTP ${response.responseCode}: ${response.result}`);
      }
      let raw = String(response.result);
      let imageBase64 = normalizeSeedreamImageBase64(raw);
      let imageUrl = normalizeSeedreamImageUrl(raw);
      if (imageBase64.length === 0 && imageUrl.length > 0) {
        imageBase64 = await this.downloadImageToBase64(imageUrl, config.timeoutMs);
      }
      if (imageBase64.length === 0) {
        throw new Error('Seedream response has no image data');
      }

      let metadata: AvatarStringMap = createEmptyRawMetadata();
      metadata['raw'] = raw;
      let parsed = parseJsonCompat<SeedreamResponse>(raw);
      let requestId = parsed.id === undefined ? '' : parsed.id;
      if (requestId.length > 0) {
        metadata['id'] = requestId;
      }
      if (imageUrl.length > 0) {
        metadata['image_url'] = imageUrl;
      }
      return {
        imageBytesBase64: imageBase64,
        imageUrl: imageUrl,
        providerRequestId: requestId,
        rawMetadata: metadata
      };
    } catch (e) {
      let err = e as Error;
      throw err;
    } finally {
      httpReq.destroy();
    }
  }
}
