import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;
const TAG = 'fleet';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.captureLaunchRoute(want);
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
