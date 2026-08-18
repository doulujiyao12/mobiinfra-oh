export const LOCAL_VISION_PORTRAIT_WIDTH: number = 270;
export const LOCAL_VISION_PORTRAIT_HEIGHT: number = 600;
export const LOCAL_VISION_LANDSCAPE_WIDTH: number = 600;
export const LOCAL_VISION_LANDSCAPE_HEIGHT: number = 270;

export interface LocalVisionImageSize {
  width: number;
  height: number;
}

export function localVisionImageTargetSize(sourceWidth: number, sourceHeight: number): LocalVisionImageSize {
  if (sourceWidth <= 0 || sourceHeight <= 0) {
    throw new Error('图片尺寸无效');
  }
  if (sourceWidth > sourceHeight) {
    return {
      width: LOCAL_VISION_LANDSCAPE_WIDTH,
      height: LOCAL_VISION_LANDSCAPE_HEIGHT
    };
  }
  return {
    width: LOCAL_VISION_PORTRAIT_WIDTH,
    height: LOCAL_VISION_PORTRAIT_HEIGHT
  };
}

export function localVisionImageTargetSizeOrDefault(sourceWidth: number,
  sourceHeight: number): LocalVisionImageSize {
  if (sourceWidth <= 0 || sourceHeight <= 0) {
    return {
      width: LOCAL_VISION_PORTRAIT_WIDTH,
      height: LOCAL_VISION_PORTRAIT_HEIGHT
    };
  }
  return localVisionImageTargetSize(sourceWidth, sourceHeight);
}

export function localVisionPromptHw(sourceWidth: number, sourceHeight: number): string {
  let target = localVisionImageTargetSizeOrDefault(sourceWidth, sourceHeight);
  return String(target.height) + ',' + String(target.width);
}
