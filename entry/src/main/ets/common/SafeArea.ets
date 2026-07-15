import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'fleet';

/// App-wide safe-area insets (in vp), published to AppStorage as `safeTop` /
/// `safeBottom` so any @StorageProp-bound header re-lays-out when they change.
///
/// The atomic service runs full-screen immersive — the window covers the whole
/// display (verified on device: window rect == [0,0,1276,2848]). That means the
/// app itself must reserve the top status-bar band and the bottom gesture bar;
/// nothing insets them for us. The system menu capsule (close / more, fixed at
/// the top-right) floats within the status-bar band, so reserving the status-bar
/// top inset also clears the capsule.
///
/// Read once from window.getWindowAvoidArea(TYPE_SYSTEM) and refreshed on
/// avoidAreaChange (rotation / fold). Both values default to 0, so if the read
/// ever fails the headers simply render at the very top, exactly as before.

let bound = false;

function publish(win: window.Window): void {
  const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
  const topVp = px2vp(sys.topRect.height);
  const bottomVp = px2vp(sys.bottomRect.height);
  AppStorage.setOrCreate('safeTop', topVp);
  AppStorage.setOrCreate('safeBottom', bottomVp);
  // One-shot calibration log: raw px + converted vp for the top status-bar band
  // (which contains the capsule) and the bottom gesture bar. grep 'safe-area'.
  hilog.info(DOMAIN, TAG,
    'safe-area: topRect px=%{public}d vp=%{public}f | bottomRect px=%{public}d vp=%{public}f',
    sys.topRect.height, topVp, sys.bottomRect.height, bottomVp);
}

/// Resolve the current window's system avoid area, publish it, and (once) keep it
/// live across rotation / fold. Call from EntryAbility.onWindowStageCreate.
export async function initSafeArea(context: common.UIAbilityContext): Promise<void> {
  try {
    const win = await window.getLastWindow(context);
    publish(win);
    if (!bound) {
      win.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          publish(win);
        }
      });
      bound = true;
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'safe-area init failed: %{public}s', JSON.stringify(e));
  }
}
