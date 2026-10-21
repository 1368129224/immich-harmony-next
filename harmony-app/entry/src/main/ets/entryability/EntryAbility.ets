import { AbilityConstant, ConfigurationConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { ImmichApiService } from '../services/ImmichApiService';
import { ThemeService } from '../services/ThemeService';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    ImmichApiService.getInstance().setCacheDir(this.context.cacheDir);
    ImmichApiService.getInstance().setFilesDir(this.context.filesDir);
    ThemeService.getInstance().init(this.context, this.context.filesDir, this.context.getApplicationContext());
    hilog.info(0x0000, 'ImmichClient', '%{public}s', 'Ability onCreate');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    ThemeService.getInstance().onSystemColorModeChanged(newConfig.colorMode);
  }

  onDestroy(): void {
    hilog.info(0x0000, 'ImmichClient', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0000, 'ImmichClient', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'ImmichClient', 'Failed to load content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      hilog.info(0x0000, 'ImmichClient', 'Succeeded in loading content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, 'ImmichClient', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(0x0000, 'ImmichClient', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(0x0000, 'ImmichClient', '%{public}s', 'Ability onBackground');
  }
}
