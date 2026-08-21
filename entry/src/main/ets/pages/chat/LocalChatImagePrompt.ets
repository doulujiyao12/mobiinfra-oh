import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import {
  LOCAL_VISION_LANDSCAPE_HEIGHT,
  LOCAL_VISION_LANDSCAPE_WIDTH,
  LOCAL_VISION_PORTRAIT_HEIGHT,
  LOCAL_VISION_PORTRAIT_WIDTH,
  LocalVisionImageSize,
  localVisionImageTargetSize
} from '../../utils/LocalVisionImageShape';

export const LOCAL_CHAT_IMAGE_MAX_COUNT: number = 1;
// MobiInfer 当前 Qwen3-VL 视觉块使用固定的长短边组合。横图只交换高宽，
// MNN 对 600/270 按视觉 patch 对齐后得到相同的 token shape，可复用同一套 NPU 视觉图。
export const LOCAL_CHAT_IMAGE_TARGET_WIDTH: number = LOCAL_VISION_PORTRAIT_WIDTH;
export const LOCAL_CHAT_IMAGE_TARGET_HEIGHT: number = LOCAL_VISION_PORTRAIT_HEIGHT;
export const LOCAL_CHAT_IMAGE_LANDSCAPE_WIDTH: number = LOCAL_VISION_LANDSCAPE_WIDTH;
export const LOCAL_CHAT_IMAGE_LANDSCAPE_HEIGHT: number = LOCAL_VISION_LANDSCAPE_HEIGHT;
let localChatImageFileSequence: number = 0;

export type LocalChatImageSize = LocalVisionImageSize;

function fileIoOpenTarget(uri: string): string {
  let normalized = uri.trim();
  if (normalized.startsWith('file:///')) {
    return normalized.substring('file://'.length);
  }
  return normalized;
}

function localFilePath(uri: string): string {
  let normalized = uri.trim();
  if (normalized.startsWith('file://')) {
    return normalized.substring('file://'.length);
  }
  return normalized;
}

export function localChatImageTargetSize(sourceWidth: number, sourceHeight: number): LocalChatImageSize {
  return localVisionImageTargetSize(sourceWidth, sourceHeight);
}

// App 侧只把原图等比缩小到目标边界，不再补黑边。最终固定 shape 的 resize
// 由 MNN 按 <hw> 完成，避免黑色画布占用大量视觉 token。
export function localChatResizeContentSize(sourceWidth: number, sourceHeight: number): LocalChatImageSize {
  let targetSize = localChatImageTargetSize(sourceWidth, sourceHeight);
  let scale = Math.min(targetSize.width / sourceWidth, targetSize.height / sourceHeight);
  return {
    width: Math.max(1, Math.min(targetSize.width, Math.round(sourceWidth * scale))),
    height: Math.max(1, Math.min(targetSize.height, Math.round(sourceHeight * scale)))
  };
}

function localChatPromptTargetSize(imageUri: string): LocalChatImageSize {
  let path = localFilePath(imageUri);
  let match = path.match(/local-chat-vlm-(270x600|600x270)-/);
  if (match !== null && match.length > 1 && match[1] === '600x270') {
    return {
      width: LOCAL_CHAT_IMAGE_LANDSCAPE_WIDTH,
      height: LOCAL_CHAT_IMAGE_LANDSCAPE_HEIGHT
    };
  }
  return {
    width: LOCAL_CHAT_IMAGE_TARGET_WIDTH,
    height: LOCAL_CHAT_IMAGE_TARGET_HEIGHT
  };
}

export function localChatImagePromptTag(imageUri: string): string {
  let path = localFilePath(imageUri);
  if (path.length === 0) {
    return '';
  }
  let targetSize = localChatPromptTargetSize(imageUri);
  // 使用 MNN 官方多模态格式：<hw> 位于图片路径之前，数值顺序为 height,width。
  return '<img><hw>' + String(targetSize.height) + ',' + String(targetSize.width) + '</hw>' + path +
    '</img>';
}

export function buildLocalChatMultimodalPrompt(text: string, imageUris: string[]): string {
  let tags: string[] = [];
  for (let i = 0; i < imageUris.length && tags.length < LOCAL_CHAT_IMAGE_MAX_COUNT; i++) {
    let tag = localChatImagePromptTag(imageUris[i]);
    if (tag.length > 0) {
      tags.push(tag);
    }
  }
  let normalizedText = text.trim();
  if (tags.length === 0) {
    return normalizedText;
  }
  if (normalizedText.length === 0) {
    return tags.join('\n');
  }
  return tags.join('\n') + '\n' + normalizedText;
}

function writePackedImage(path: string, data: ArrayBuffer): void {
  let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, data);
  } finally {
    fs.closeSync(file);
  }
}

function removeFile(path: string): void {
  if (path.length === 0) {
    return;
  }
  try {
    fs.unlinkSync(path);
  } catch (e) {
  }
}

export function cleanupLocalChatPreparedImages(paths: string[]): void {
  for (let i = 0; i < paths.length; i++) {
    removeFile(paths[i]);
  }
}

// App 侧只做等比缩小和 JPEG 归一化，不裁切、不补边；MNN 再根据提示词中的
// 270x600 或 600x270 完成固定 shape resize，既保留完整画面，也避免黑边稀释视觉特征。
export async function prepareLocalChatImage(filesDir: string, imageUri: string,
  sequence: number): Promise<string> {
  if (filesDir.length === 0) {
    throw new Error('文件目录未初始化');
  }
  if (imageUri.trim().length === 0) {
    throw new Error('图片地址为空');
  }

  let inputFile: fileIo.File | null = null;
  let imageSource: image.ImageSource | null = null;
  let resizedPixelMap: image.PixelMap | null = null;
  let packer: image.ImagePacker | null = null;
  let outputPath = '';
  try {
    inputFile = await fileIo.open(fileIoOpenTarget(imageUri), fileIo.OpenMode.READ_ONLY);
    imageSource = image.createImageSource(inputFile.fd);
    let sourceInfo = await imageSource.getImageInfo();
    let targetSize = localChatImageTargetSize(sourceInfo.size.width, sourceInfo.size.height);
    let contentSize = localChatResizeContentSize(sourceInfo.size.width, sourceInfo.size.height);
    resizedPixelMap = await imageSource.createPixelMap({
      desiredSize: {
        width: contentSize.width,
        height: contentSize.height
      },
      desiredDynamicRange: image.DecodingDynamicRange.SDR,
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: false
    });

    let resizedInfo = await resizedPixelMap.getImageInfo();
    if (resizedInfo.size.width <= 0 || resizedInfo.size.height <= 0 ||
      resizedInfo.size.width > targetSize.width || resizedInfo.size.height > targetSize.height) {
      throw new Error('图片缩放结果无效');
    }
    packer = image.createImagePacker();
    let packedData = await packer.packToData(resizedPixelMap, {
      format: 'image/jpeg',
      quality: 90
    });
    localChatImageFileSequence += 1;
    outputPath = filesDir + '/local-chat-vlm-' + String(targetSize.width) + 'x' + String(targetSize.height) + '-' +
      Date.now().toString() + '-' +
      String(sequence) + '-' + String(localChatImageFileSequence) + '.jpg';
    writePackedImage(outputPath, packedData);
    return outputPath;
  } catch (e) {
    removeFile(outputPath);
    let err = e as Error;
    throw new Error('本地图片预处理失败：' + err.message);
  } finally {
    if (packer !== null) {
      try {
        await packer.release();
      } catch (e) {
      }
    }
    if (resizedPixelMap !== null) {
      try {
        await resizedPixelMap.release();
      } catch (e) {
      }
    }
    if (imageSource !== null) {
      try {
        await imageSource.release();
      } catch (e) {
      }
    }
    if (inputFile !== null) {
      try {
        await fileIo.close(inputFile);
      } catch (e) {
      }
    }
  }
}

export async function prepareLocalChatImages(filesDir: string, imageUris: string[]): Promise<string[]> {
  let prepared: string[] = [];
  try {
    for (let i = 0; i < imageUris.length && prepared.length < LOCAL_CHAT_IMAGE_MAX_COUNT; i++) {
      prepared.push(await prepareLocalChatImage(filesDir, imageUris[i], i));
    }
    return prepared;
  } catch (e) {
    cleanupLocalChatPreparedImages(prepared);
    let err = e as Error;
    throw err;
  }
}
