// ThemeService.ets — App color mode (follow system by default; manual light/dark override)
import { common } from '@kit.AbilityKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

export type ThemeMode = 'SYSTEM' | 'LIGHT' | 'DARK';

interface ThemeSettingsFile {
  mode: ThemeMode;
}

@ObservedV2
export class ThemeService {
  private static instance: ThemeService | null = null;

  @Trace mode: ThemeMode = 'SYSTEM';
  @Trace systemIsDark: boolean = false;

  private filesDir: string = '';
  private appContext: common.ApplicationContext | null = null;

  public static getInstance(): ThemeService {
    if (!ThemeService.instance) {
      ThemeService.instance = new ThemeService();
    }
    return ThemeService.instance;
  }

  get isDark(): boolean {
    if (this.mode === 'DARK') {
      return true;
    }
    if (this.mode === 'LIGHT') {
      return false;
    }
    return this.systemIsDark;
  }

  // Palette tokens used by shared chrome. Photo grid / viewer stay dark by design.
  get bg(): string { return this.isDark ? '#121212' : '#F2F2F7'; }
  get surface(): string { return this.isDark ? '#1E1E1E' : '#FFFFFF'; }
  get textPrimary(): string { return this.isDark ? '#FFFFFF' : '#1C1C1E'; }
  get textSecondary(): string { return this.isDark ? '#909399' : '#6E6E73'; }
  get textTertiary(): string { return this.isDark ? '#606266' : '#AEAEB2'; }
  get divider(): string { return this.isDark ? '#2C2C2E' : '#E5E5EA'; }
  get iconTint(): string { return this.isDark ? '#DCDFE6' : '#3A3A3C'; }
  get tabBarBg(): string { return this.isDark ? '#000000' : '#FFFFFF'; }
  get segmentBg(): string { return this.isDark ? '#2C2C2E' : '#E5E5EA'; }
  get avatarBg(): string { return this.isDark ? '#3A3A3C' : '#D1D1D6'; }
  get avatarIcon(): string { return this.isDark ? '#A4A9B2' : '#48484A'; }

  /** Called once from EntryAbility.onCreate with the ability context. */
  public init(context: common.UIAbilityContext, filesDir: string, appContext: common.ApplicationContext): void {
    this.filesDir = filesDir;
    this.appContext = appContext;
    this.systemIsDark = context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.load();
    this.applyToApp();
  }

  /** Called from EntryAbility.onConfigurationUpdate when the system color mode changes. */
  public onSystemColorModeChanged(colorMode: ConfigurationConstant.ColorMode | undefined): void {
    this.systemIsDark = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  public setMode(mode: ThemeMode): void {
    this.mode = mode;
    this.applyToApp();
    this.save();
  }

  private applyToApp(): void {
    if (!this.appContext) {
      return;
    }
    let target = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (this.mode === 'DARK') {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (this.mode === 'LIGHT') {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    this.appContext.setColorMode(target);
  }

  private settingsPath(): string {
    return `${this.filesDir}/app_settings.json`;
  }

  private load(): void {
    if (!this.filesDir) {
      return;
    }
    try {
      const path = this.settingsPath();
      if (!fs.accessSync(path)) {
        return;
      }
      const data = JSON.parse(fs.readTextSync(path)) as ThemeSettingsFile;
      if (data.mode === 'SYSTEM' || data.mode === 'LIGHT' || data.mode === 'DARK') {
        this.mode = data.mode;
      }
    } catch (err) {
      console.warn('[ThemeService] Failed to load settings, using system mode');
    }
  }

  private save(): void {
    if (!this.filesDir) {
      return;
    }
    try {
      const file = fs.openSync(this.settingsPath(), fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        const payload: ThemeSettingsFile = { mode: this.mode };
        fs.writeSync(file.fd, JSON.stringify(payload));
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      console.error('[ThemeService] Failed to save settings');
    }
  }
}
