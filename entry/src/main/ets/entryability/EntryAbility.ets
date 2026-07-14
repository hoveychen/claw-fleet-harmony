import { AbilityConstant, ConfigurationConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { initTheme, setSystemDark } from '../common/Theme';
import { initI18n } from '../common/I18n';

const DOMAIN = 0x0000;
const TAG = 'fleet';

/// COLOR_MODE_LIGHT → light; DARK and NOT_SET both resolve to dark, matching the
/// web client's `color-scheme: dark` default.
function isDark(mode?: ConfigurationConstant.ColorMode): boolean {
  return mode !== ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    const cfg = this.context.config;
    const deviceIsZh = (cfg.language ?? 'zh').toLowerCase().startsWith('zh');
    initI18n(deviceIsZh);
    initTheme(isDark(cfg.colorMode));
    this.captureLaunchRoute(want);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // Follow OS light/dark flips while the app is running.
    setSystemDark(isDark(newConfig.colorMode));
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    // Re-launched while already alive — e.g. a notification tap.
    this.captureLaunchRoute(want);
  }

  /// A notification tap may carry routing params in `want.parameters`. The exact
  /// clickAction → want mapping for the v1 service_notification channel is not
  /// yet verified on-device (and the relay send-side does not set a clickAction
  /// yet), so we conservatively stash any `tag` that arrives into AppStorage for
  /// the page to consume; wiring the send-side clickAction is a follow-up once
  /// its schema is confirmed.
  private captureLaunchRoute(want: Want): void {
    const params = want.parameters;
    if (!params) {
      return;
    }
    const tag = params.tag;
    if (typeof tag === 'string' && tag.length > 0) {
      AppStorage.setOrCreate('pendingRoute', tag);
      hilog.info(DOMAIN, TAG, 'launch route tag: %{public}s', tag);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }
}
