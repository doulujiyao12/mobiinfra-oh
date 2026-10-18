import { Configuration, ConfigurationConstant, common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { UIContext } from '@kit.ArkUI';

export const APP_DARK_MODE_KEY: string = 'appDarkMode';

interface ThemeTone {
  alpha: number;
  minimum: number;
  maximum: number;
  saturation: number;
  hue: number;
}

enum ThemeFamily {
  Red, Orange, Gold, Green, Cyan, Blue, Purple, Pink
}

// UI uses resource handles, not resolved strings: ArkUI can update them when the
// system switches appearance. The adapters also cover colors from saved workflow
// metadata without changing the stored data or its business types.
export class AppTheme {
  static syncSystemMode(context: common.UIAbilityContext, configuration?: Configuration): void {
    let mode = configuration?.colorMode ?? context.config.colorMode;
    let dark = AppStorage.get<boolean>(APP_DARK_MODE_KEY) ?? false;
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      dark = true;
    } else if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      dark = false;
    } else {
      try {
        dark = context.resourceManager.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK;
      } catch (e) {
        // A transient configuration failure keeps the last known appearance.
      }
    }
    AppStorage.setOrCreate(APP_DARK_MODE_KEY, dark);
  }

  static text(color: ResourceColor): ResourceColor {
    let tone = AppTheme.tone(color);
    if (tone === null || tone.alpha === 0) { return color; }
    if (tone.minimum >= 0.85) { return $r('app.color.ui_text_on_fill'); }
    if (tone.alpha < 0.7) { return $r('app.color.ui_text_muted'); }
    if (tone.maximum < 0.25) { return $r('app.color.ui_text_primary'); }
    if (AppTheme.isNeutral(tone)) {
      return tone.maximum < 0.55 ? $r('app.color.ui_text_secondary') : $r('app.color.ui_text_muted');
    }
    return AppTheme.accent(AppTheme.family(tone));
  }

  // promptAction.Button accepts string | Resource rather than ResourceColor.
  static dialogText(color: string): Resource {
    let adapted = AppTheme.text(color);
    return typeof adapted === 'object' ? adapted : $r('app.color.ui_text_primary');
  }

  static background(color: ResourceColor): ResourceColor {
    let tone = AppTheme.tone(color);
    if (tone === null || tone.alpha === 0) { return color; }
    if (tone.alpha < 1 && tone.minimum > 0.85) {
      if (tone.alpha <= 0.2) { return $r('app.color.ui_glass_title'); }
      if (tone.alpha <= 0.5) { return $r('app.color.ui_glass_mask'); }
      return $r('app.color.ui_glass_surface');
    }
    if (tone.alpha < 1 && tone.maximum < 0.12) { return $r('app.color.ui_scrim'); }
    if (tone.minimum > 0.985) { return $r('app.color.ui_surface'); }
    if (AppTheme.isNeutral(tone)) {
      if (tone.maximum > 0.9) { return $r('app.color.ui_surface_soft'); }
      if (tone.maximum > 0.65) { return $r('app.color.ui_surface_muted'); }
      // Dark user bubbles and solid toolbar controls retain white foregrounds.
      return $r('app.color.ui_surface_emphasized');
    }
    if (tone.maximum < 0.3) { return $r('app.color.ui_surface_emphasized'); }
    if (tone.minimum > 0.62 || tone.alpha < 0.55) {
      return AppTheme.soft(AppTheme.family(tone));
    }
    return AppTheme.fill(AppTheme.family(tone));
  }

  // Use for controls with an unconditional white foreground, including disabled
  // buttons and avatar initials. Pale legacy fills must not become white cards.
  static filledBackground(color: ResourceColor): ResourceColor {
    let tone = AppTheme.tone(color);
    if (tone === null || tone.alpha === 0) { return color; }
    if (AppTheme.isNeutral(tone) || tone.maximum < 0.3) {
      return tone.maximum > 0.6 ? $r('app.color.ui_fill_neutral') : $r('app.color.ui_surface_emphasized');
    }
    return AppTheme.fill(AppTheme.family(tone));
  }

  static border(color: ResourceColor): ResourceColor {
    let tone = AppTheme.tone(color);
    if (tone === null || tone.alpha === 0) { return color; }
    if (tone.minimum > 0.9 && tone.alpha < 1) { return $r('app.color.ui_glass_border'); }
    if (AppTheme.isNeutral(tone) || tone.minimum > 0.7 || tone.maximum < 0.35) {
      return $r('app.color.ui_border');
    }
    return AppTheme.accent(AppTheme.family(tone));
  }

  static shadow(color: ResourceColor): ResourceColor {
    let tone = AppTheme.tone(color);
    if (tone === null || tone.alpha === 0) { return color; }
    return $r('app.color.ui_shadow');
  }

  static pageBackground(color: ResourceColor = '#F6F8FC'): ResourceColor {
    let tone = AppTheme.tone(color);
    return tone !== null && tone.minimum > 0.985 ?
      $r('app.color.ui_page_white') : $r('app.color.ui_page_background');
  }
  static inputBackground(): ResourceColor { return $r('app.color.ui_input_background'); }

  // Window APIs require a string; resolve only at this boundary, never cache
  // the resulting string in a component's state or in persisted configuration.
  static resolve(uiContext: UIContext, color: ResourceColor): string {
    if (typeof color === 'string') { return color; }
    let context = uiContext.getHostContext();
    if (context !== undefined && typeof color === 'object') {
      try {
        let value = context.resourceManager.getColorSync(color as Resource);
        return '#' + (value >>> 0).toString(16).padStart(8, '0');
      } catch (e) {
      }
    }
    return AppStorage.get<boolean>(APP_DARK_MODE_KEY) ? '#11151D' : '#F6F8FC';
  }

  private static tone(color: ResourceColor): ThemeTone | null {
    let hex: string = '';
    if (color === Color.White) { hex = '#FFFFFF'; }
    else if (color === Color.Black) { hex = '#000000'; }
    else if (color === Color.Gray) { hex = '#808080'; }
    else if (color === Color.Blue) { hex = '#007DFF'; }
    else if (color === Color.Green) { hex = '#008000'; }
    else if (color === Color.Red) { hex = '#FF0000'; }
    else if (color === Color.Orange) { hex = '#FFA500'; }
    else if (color === Color.Pink) { hex = '#FFC0CB'; }
    else if (color === Color.Yellow) { hex = '#FFFF00'; }
    else if (color === Color.Transparent) { hex = '#00000000'; }
    else if (typeof color === 'string') { hex = color; }
    if (!/^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(hex)) { return null; }
    let alpha = hex.length === 9 ? parseInt(hex.substring(1, 3), 16) / 255 : 1;
    let offset = hex.length === 9 ? 3 : 1;
    let red = parseInt(hex.substring(offset, offset + 2), 16) / 255;
    let green = parseInt(hex.substring(offset + 2, offset + 4), 16) / 255;
    let blue = parseInt(hex.substring(offset + 4, offset + 6), 16) / 255;
    let minimum = Math.min(red, green, blue);
    let maximum = Math.max(red, green, blue);
    let delta = maximum - minimum;
    let hue = 0;
    if (delta > 0) {
      if (maximum === red) { hue = 60 * ((green - blue) / delta); }
      else if (maximum === green) { hue = 60 * ((blue - red) / delta + 2); }
      else { hue = 60 * ((red - green) / delta + 4); }
      hue = (hue + 360) % 360;
    }
    let tone: ThemeTone = {
      alpha: alpha, minimum: minimum, maximum: maximum,
      saturation: maximum === 0 ? 0 : delta / maximum, hue: hue
    };
    return tone;
  }

  private static isNeutral(tone: ThemeTone): boolean {
    return tone.saturation < 0.2 || (tone.maximum < 0.6 && tone.saturation < 0.45);
  }

  private static family(tone: ThemeTone): ThemeFamily {
    if (tone.hue < 20 || tone.hue >= 350) { return ThemeFamily.Red; }
    if (tone.hue < 50) { return ThemeFamily.Orange; }
    if (tone.hue < 80) { return ThemeFamily.Gold; }
    if (tone.hue < 165) { return ThemeFamily.Green; }
    if (tone.hue < 205) { return ThemeFamily.Cyan; }
    if (tone.hue < 255) { return ThemeFamily.Blue; }
    if (tone.hue < 290) { return ThemeFamily.Purple; }
    return ThemeFamily.Pink;
  }

  private static accent(family: ThemeFamily): ResourceColor {
    switch (family) {
      case ThemeFamily.Red: return $r('app.color.ui_accent_red');
      case ThemeFamily.Orange: return $r('app.color.ui_accent_orange');
      case ThemeFamily.Gold: return $r('app.color.ui_accent_gold');
      case ThemeFamily.Green: return $r('app.color.ui_accent_green');
      case ThemeFamily.Cyan: return $r('app.color.ui_accent_cyan');
      case ThemeFamily.Blue: return $r('app.color.ui_accent_blue');
      case ThemeFamily.Purple: return $r('app.color.ui_accent_purple');
      default: return $r('app.color.ui_accent_pink');
    }
  }

  private static soft(family: ThemeFamily): ResourceColor {
    switch (family) {
      case ThemeFamily.Red: return $r('app.color.ui_soft_red');
      case ThemeFamily.Orange: return $r('app.color.ui_soft_orange');
      case ThemeFamily.Gold: return $r('app.color.ui_soft_gold');
      case ThemeFamily.Green: return $r('app.color.ui_soft_green');
      case ThemeFamily.Cyan: return $r('app.color.ui_soft_cyan');
      case ThemeFamily.Blue: return $r('app.color.ui_soft_blue');
      case ThemeFamily.Purple: return $r('app.color.ui_soft_purple');
      default: return $r('app.color.ui_soft_pink');
    }
  }

  private static fill(family: ThemeFamily): ResourceColor {
    switch (family) {
      case ThemeFamily.Red: return $r('app.color.ui_fill_red');
      case ThemeFamily.Orange: return $r('app.color.ui_fill_orange');
      case ThemeFamily.Gold: return $r('app.color.ui_fill_gold');
      case ThemeFamily.Green: return $r('app.color.ui_fill_green');
      case ThemeFamily.Cyan: return $r('app.color.ui_fill_cyan');
      case ThemeFamily.Blue: return $r('app.color.ui_fill_blue');
      case ThemeFamily.Purple: return $r('app.color.ui_fill_purple');
      default: return $r('app.color.ui_fill_pink');
    }
  }
}
