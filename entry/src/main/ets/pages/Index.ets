import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RelayStore } from '../common/RelayStore';
import { registerForPush } from '../common/PushRegister';
import { ColorTokens, themeTokens } from '../common/Theme';
import { GateView } from '../views/GateView';
import { MainShell } from '../views/MainShell';

const DOMAIN = 0x0000;
const TAG = 'fleet';

/// App root: decides between the pairing gate and the main shell. On a paired
/// launch it refreshes the push subscription in the background (the P5 flow).
@Entry
@Component
struct Index {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @State private paired: boolean = false;
  @State private checking: boolean = true;

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  aboutToAppear(): void {
    this.init();
  }

  private async init(): Promise<void> {
    try {
      const pairing = await RelayStore.loadPairing(this.ctx());
      this.paired = pairing !== null;
    } catch (e) {
      this.paired = false;
    }
    this.checking = false;
    if (this.paired) {
      // Refresh the push subscription on a paired launch (fire-and-forget) —
      // preserves the on-device-verified P5 flow (getToken → subscribe → OpenID).
      registerForPush(this.ctx())
        .then(() => {
          hilog.info(DOMAIN, TAG, 'push refreshed on launch');
        })
        .catch((e: Object) => {
          hilog.warn(DOMAIN, TAG, 'push refresh failed: %{public}s', JSON.stringify(e));
        });
    }
  }

  private async doRepair(): Promise<void> {
    await RelayStore.clearPairing(this.ctx());
    this.paired = false;
  }

  build() {
    Stack() {
      if (this.checking) {
        Column() {
          Text('Fleet')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.tk().text)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.tk().bg)
      } else if (!this.paired) {
        GateView({ onPaired: () => {
          this.paired = true;
        } })
      } else {
        MainShell({
          onRepair: () => {
            this.doRepair();
          },
          onNewSession: () => {
            // New-session composer lands in P6.
          },
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
