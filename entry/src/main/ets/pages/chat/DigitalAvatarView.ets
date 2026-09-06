import {
  digitalAvatarContainerHeight,
  digitalAvatarContainerWidth,
  digitalAvatarFallbackSize,
  digitalAvatarFrameHeight,
  digitalAvatarFrameWidth,
  DigitalAvatarSize,
  DigitalAvatarVisualState
} from './DigitalAvatarTypes';
import { AppLogger } from '../../utils/AppLogger';

@Component
export struct DigitalAvatarView {
  @Prop @Watch('onAvatarForegroundUriChanged') avatarForegroundUri: string = '';
  @Prop fallbackText: string = '助';
  @Prop fallbackColor: string = '#5968FF';
  @Prop avatarSize: DigitalAvatarSize = 'message';
  @Prop @Watch('onVisualStateChanged') visualState: DigitalAvatarVisualState = 'idle';
  @Prop debugSource: string = '';
  @State imageLoadFailed: boolean = false;
  @State thinkingPulse: boolean = false;
  @State tapScale: number = 1;
  @State tapTranslateY: number = 0;
  @State tapShadowScale: number = 1;
  @State tapShadowOpacity: number = 0.22;
  @State tapHaloScale: number = 0.86;
  @State tapHaloOpacity: number = 0;
  private thinkingTimerId: number = -1;
  private tapFrameTimerIds: number[] = [];
  private tapUnlockTimerId: number = -1;
  private tapLocked: boolean = false;

  aboutToAppear(): void {
    this.syncThinkingTimer();
  }

  aboutToDisappear(): void {
    this.clearThinkingTimer();
    this.clearTapFrameTimers();
    this.clearTapUnlockTimer();
    this.tapLocked = false;
  }

  private onAvatarForegroundUriChanged(): void {
    this.imageLoadFailed = false;
    this.syncThinkingTimer();
  }

  private onVisualStateChanged(): void {
    this.syncThinkingTimer();
  }

  private hasForegroundImage(): boolean {
    return this.avatarForegroundUri.length > 0 && !this.imageLoadFailed;
  }

  private hasAvatarFrame(): boolean {
    return this.avatarForegroundUri.length > 0;
  }

  private avatarLogContext(): string {
    let source: string = this.debugSource.length > 0 ? this.debugSource : 'unknown';
    return 'source=' + source +
      ', size=' + this.avatarSize +
      ', visualState=' + this.visualState +
      ', hasUri=' + String(this.avatarForegroundUri.length > 0) +
      ', imageLoadFailed=' + String(this.imageLoadFailed) +
      ', tapLocked=' + String(this.tapLocked);
  }

  private logAvatarInfo(message: string): void {
    AppLogger.info('Chat.Avatar', message + ' ' + this.avatarLogContext());
  }

  private logAvatarWarn(message: string): void {
    AppLogger.warn('Chat.Avatar', message + ' ' + this.avatarLogContext());
  }

  private containerWidth(): number {
    return digitalAvatarContainerWidth(this.avatarSize, this.hasAvatarFrame());
  }

  private containerHeight(): number {
    return digitalAvatarContainerHeight(this.avatarSize, this.hasAvatarFrame());
  }

  private frameWidth(): number {
    return digitalAvatarFrameWidth(this.avatarSize);
  }

  private frameHeight(): number {
    return digitalAvatarFrameHeight(this.avatarSize);
  }

  private fallbackSize(): number {
    return digitalAvatarFallbackSize(this.avatarSize);
  }

  private fallbackFontSize(): number {
    return this.avatarSize === 'hero' ? 20 : 13;
  }

  private fallbackRadius(): number {
    return this.avatarSize === 'hero' ? 18 : 13;
  }

  private ringSize(): number {
    return this.avatarSize === 'hero' ? 104 : 40;
  }

  private ringRadius(): number {
    return this.avatarSize === 'hero' ? 52 : 20;
  }

  private shadowWidth(): number {
    return this.avatarSize === 'hero' ? 92 : 32;
  }

  private shadowHeight(): number {
    return this.avatarSize === 'hero' ? 16 : 8;
  }

  private shadowRadius(): number {
    return this.avatarSize === 'hero' ? 8 : 4;
  }

  private shadowTranslateY(): number {
    return this.avatarSize === 'hero' ? 57 : 19;
  }

  private highlightWidth(): number {
    return this.avatarSize === 'hero' ? 22 : 10;
  }

  private highlightHeight(): number {
    return this.avatarSize === 'hero' ? 86 : 34;
  }

  private highlightRadius(): number {
    return this.avatarSize === 'hero' ? 11 : 5;
  }

  private highlightTranslateX(): number {
    return this.avatarSize === 'hero' ? 28 : 10;
  }

  private highlightTranslateY(): number {
    return this.avatarSize === 'hero' ? -12 : -2;
  }

  private waveBarWidth(): number {
    return this.avatarSize === 'hero' ? 5 : 3;
  }

  private waveBarGap(): number {
    return this.avatarSize === 'hero' ? 5 : 3;
  }

  private waveBarRadius(): number {
    return this.avatarSize === 'hero' ? 3 : 2;
  }

  private waveTranslateX(): number {
    return this.avatarSize === 'hero' ? 55 : 19;
  }

  private waveTranslateY(): number {
    return this.avatarSize === 'hero' ? -10 : -2;
  }

  private waveBarMaxHeight(): number {
    return this.avatarSize === 'hero' ? 28 : 15;
  }

  private waveBarScaleY(index: number): number {
    let small: number = this.avatarSize === 'hero' ? 12 : 7;
    let large: number = this.waveBarMaxHeight();
    let targetHeight: number = 0;
    if (this.visualState === 'interrupted') {
      targetHeight = small;
    } else if (this.visualState === 'speaking') {
      if (index === 1) {
        targetHeight = this.thinkingPulse ? large : small;
      } else {
        targetHeight = this.thinkingPulse ? small : large;
      }
    }
    return targetHeight > 0 ? targetHeight / large : 0.01;
  }

  private waveOpacity(): number {
    if (this.visualState === 'speaking') {
      return this.thinkingPulse ? 1 : 0.72;
    }
    if (this.visualState === 'interrupted') {
      return 0.5;
    }
    return 0;
  }

  private tapLiftY(): number {
    return this.avatarSize === 'hero' ? -16 : -10;
  }

  private tapPeakScale(): number {
    return this.avatarSize === 'hero' ? 1.16 : 1.28;
  }

  private tapSettleScale(): number {
    return this.avatarSize === 'hero' ? 1.04 : 1.08;
  }

  private tapForegroundAnimationDuration(): number {
    if (this.tapScale !== 1 || this.tapTranslateY !== 0) {
      return 120;
    }
    return this.isAnimatedVoiceState() ? 620 : 120;
  }

  private tapShadowAnimationDuration(): number {
    if (this.tapShadowScale !== 1 || this.tapShadowOpacity !== 0.22) {
      return 120;
    }
    return this.isAnimatedVoiceState() ? 620 : 120;
  }

  private isAnimatedVoiceState(): boolean {
    return this.visualState === 'thinking' || this.visualState === 'listening' || this.visualState === 'speaking';
  }

  private foregroundScale(): number {
    let pulseScale: number = this.isAnimatedVoiceState() && this.thinkingPulse ? this.voicePulseScale() : 1;
    return this.tapScale * pulseScale;
  }

  private voicePulseScale(): number {
    if (this.visualState === 'listening') {
      return 1.03;
    }
    if (this.visualState === 'speaking') {
      return 1.07;
    }
    return 1.04;
  }

  private ringScale(): number {
    if (this.visualState === 'interrupted') {
      return 1.04;
    }
    if (!this.isAnimatedVoiceState()) {
      return 0.92;
    }
    if (this.visualState === 'speaking') {
      return this.thinkingPulse ? 1.26 : 0.94;
    }
    return this.thinkingPulse ? 1.18 : 0.92;
  }

  private ringOpacity(): number {
    if (this.visualState === 'interrupted') {
      return 0.42;
    }
    if (!this.isAnimatedVoiceState()) {
      return 0.22;
    }
    if (this.visualState === 'listening') {
      return this.thinkingPulse ? 0.48 : 0.2;
    }
    if (this.visualState === 'speaking') {
      return this.thinkingPulse ? 0.66 : 0.24;
    }
    return this.thinkingPulse ? 0.58 : 0.22;
  }

  private shadowScale(): number {
    let pulseScale: number = this.isAnimatedVoiceState() && this.thinkingPulse ? 0.92 : 1;
    return this.tapShadowScale * pulseScale;
  }

  private fallbackRingSize(): number {
    return this.fallbackSize();
  }

  private fallbackRingRadius(): number {
    return this.fallbackSize() / 2;
  }

  // 思考态仅通过脉冲状态驱动 transform/opacity，避免频繁触发布局计算。
  private startThinkingTimer(): void {
    if (this.thinkingTimerId !== -1) {
      return;
    }
    this.thinkingTimerId = setInterval(() => {
      this.thinkingPulse = !this.thinkingPulse;
    }, 800);
  }

  private clearThinkingTimer(): void {
    if (this.thinkingTimerId === -1) {
      return;
    }
    clearInterval(this.thinkingTimerId);
    this.thinkingTimerId = -1;
  }

  private stopThinkingTimer(): void {
    this.clearThinkingTimer();
    this.thinkingPulse = false;
  }

  private clearTapUnlockTimer(): void {
    if (this.tapUnlockTimerId === -1) {
      return;
    }
    clearTimeout(this.tapUnlockTimerId);
    this.tapUnlockTimerId = -1;
  }

  private clearTapFrameTimers(): void {
    for (let i = 0; i < this.tapFrameTimerIds.length; i++) {
      clearTimeout(this.tapFrameTimerIds[i]);
    }
    this.tapFrameTimerIds = [];
  }

  private syncThinkingTimer(): void {
    if (this.isAnimatedVoiceState() && (this.hasForegroundImage() || this.fallbackText.length > 0)) {
      this.startThinkingTimer();
      return;
    }
    this.stopThinkingTimer();
  }

  // 点击反馈用关键帧同步前景与投影，形成轻量 2.5D 弹跳效果。
  private handleAvatarClick(): void {
    this.logAvatarInfo('click received');
    this.triggerTapFeedback();
  }

  private applyTapFeedbackFrame(stage: string, tapScale: number, tapTranslateY: number, tapShadowScale: number,
    tapShadowOpacity: number, tapHaloScale: number, tapHaloOpacity: number): void {
    this.tapScale = tapScale;
    this.tapTranslateY = tapTranslateY;
    this.tapShadowScale = tapShadowScale;
    this.tapShadowOpacity = tapShadowOpacity;
    this.tapHaloScale = tapHaloScale;
    this.tapHaloOpacity = tapHaloOpacity;
    this.logAvatarInfo('tap feedback frame=' + stage);
  }

  private scheduleTapFeedbackFrame(delay: number, stage: string, tapScale: number, tapTranslateY: number,
    tapShadowScale: number, tapShadowOpacity: number, tapHaloScale: number, tapHaloOpacity: number): void {
    let timerId = setTimeout(() => {
      this.applyTapFeedbackFrame(stage, tapScale, tapTranslateY, tapShadowScale, tapShadowOpacity, tapHaloScale,
        tapHaloOpacity);
    }, delay);
    this.tapFrameTimerIds.push(timerId);
  }

  private triggerTapFeedback(): void {
    if (!this.hasAvatarFrame() && this.fallbackText.length === 0) {
      this.logAvatarWarn('tap ignored reason=empty-avatar');
      return;
    }
    if (this.tapLocked) {
      this.logAvatarWarn('tap ignored reason=tap-locked');
      return;
    }
    this.logAvatarInfo('tap feedback start');
    this.tapLocked = true;
    this.clearTapFrameTimers();
    this.clearTapUnlockTimer();
    this.applyTapFeedbackFrame('lift', this.tapPeakScale(), this.tapLiftY(), 0.68, 0.08, 1.34, 0.72);
    this.scheduleTapFeedbackFrame(170, 'settle', this.tapSettleScale(), 2, 1.18, 0.28, 1.16, 0.34);
    this.scheduleTapFeedbackFrame(340, 'restore', 1, 0, 1, 0.22, 1.58, 0);
    this.tapUnlockTimerId = setTimeout(() => {
      this.tapLocked = false;
      this.tapUnlockTimerId = -1;
      this.clearTapFrameTimers();
      this.logAvatarInfo('tap feedback unlocked');
    }, 560);
  }

  @Builder FallbackAvatar() {
    // 无前景图时也保留固定尺寸的语音反馈层，避免图片失败后状态不可见。
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width(this.fallbackRingSize())
        .height(this.fallbackRingSize())
        .backgroundColor('#335968FF')
        .borderRadius(this.fallbackRingRadius())
        .opacity(this.ringOpacity())
        .scale({ x: this.ringScale(), y: this.ringScale() })
        .animation({ duration: 760, curve: Curve.EaseInOut });

      Text(this.fallbackText)
        .fontSize(this.fallbackFontSize())
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .width(this.fallbackSize())
        .height(this.fallbackSize())
        .textAlign(TextAlign.Center)
        .backgroundColor(this.fallbackColor)
        .borderRadius(this.fallbackRadius())
        .translate({ x: 0, y: this.tapTranslateY })
        .scale({ x: this.foregroundScale(), y: this.foregroundScale() })
        .animation({ duration: this.tapForegroundAnimationDuration(), curve: Curve.EaseOut });
    }
    .width(this.fallbackSize())
    .height(this.fallbackSize());
  }

  @Builder ForegroundAvatar() {
    // 背景光圈、地面投影、透明前景图与高光分层叠加，保持头像尺寸稳定。
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width(this.ringSize())
        .height(this.ringSize())
        .backgroundColor('#445968FF')
        .borderRadius(this.ringRadius())
        .opacity(this.tapHaloOpacity)
        .scale({ x: this.tapHaloScale, y: this.tapHaloScale })
        .animation({ duration: 120, curve: Curve.EaseOut });

      Row()
        .width(this.ringSize())
        .height(this.ringSize())
        .backgroundColor('#335968FF')
        .borderRadius(this.ringRadius())
        .opacity(this.ringOpacity())
        .scale({ x: this.ringScale(), y: this.ringScale() })
        .animation({ duration: 760, curve: Curve.EaseInOut });

      Row()
        .width(this.shadowWidth())
        .height(this.shadowHeight())
        .backgroundColor('#35222B46')
        .borderRadius(this.shadowRadius())
        .translate({ x: 0, y: this.shadowTranslateY() })
        .opacity(this.tapShadowOpacity)
        .scale({ x: this.shadowScale(), y: 1 })
        .animation({ duration: this.tapShadowAnimationDuration(), curve: Curve.EaseOut });

      Image(this.avatarForegroundUri)
        .width(this.frameWidth())
        .height(this.frameHeight())
        .objectFit(ImageFit.Contain)
        .translate({ x: 0, y: this.tapTranslateY })
        .scale({ x: this.foregroundScale(), y: this.foregroundScale() })
        .animation({ duration: this.tapForegroundAnimationDuration(), curve: Curve.EaseOut })
        .onError(() => {
          this.imageLoadFailed = true;
          this.stopThinkingTimer();
          this.logAvatarWarn('foreground image load failed');
        });

      Row()
        .width(this.highlightWidth())
        .height(this.highlightHeight())
        .backgroundColor('#33FFFFFF')
        .borderRadius(this.highlightRadius())
        .translate({ x: this.highlightTranslateX(), y: this.highlightTranslateY() })
        .opacity(0.32);

      Row({ space: this.waveBarGap() }) {
        Row()
          .width(this.waveBarWidth())
          .height(this.waveBarMaxHeight())
          .backgroundColor('#5968FF')
          .borderRadius(this.waveBarRadius())
          .scale({ x: 1, y: this.waveBarScaleY(0) })
        Row()
          .width(this.waveBarWidth())
          .height(this.waveBarMaxHeight())
          .backgroundColor('#5968FF')
          .borderRadius(this.waveBarRadius())
          .scale({ x: 1, y: this.waveBarScaleY(1) })
        Row()
          .width(this.waveBarWidth())
          .height(this.waveBarMaxHeight())
          .backgroundColor('#5968FF')
          .borderRadius(this.waveBarRadius())
          .scale({ x: 1, y: this.waveBarScaleY(2) })
      }
      .height(this.waveBarMaxHeight())
      .alignItems(VerticalAlign.Center)
      .translate({ x: this.waveTranslateX(), y: this.waveTranslateY() })
      .opacity(this.waveOpacity())
      .animation({ duration: 360, curve: Curve.EaseInOut });
    }
    .width(this.frameWidth())
    .height(this.frameHeight());
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.hasForegroundImage()) {
        this.ForegroundAvatar();
      } else {
        this.FallbackAvatar();
      }
    }
    .width(this.containerWidth())
    .height(this.containerHeight())
    .onClick(() => {
      this.handleAvatarClick();
    });
  }
}
