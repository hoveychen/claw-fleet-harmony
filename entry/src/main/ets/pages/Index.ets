import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { parsePairingUrl, RelayStore } from '../common/RelayStore';
import { registerForPush } from '../common/PushRegister';

const DOMAIN = 0x0000;
const TAG = 'fleet';

@Entry
@Component
struct Index {
  @State private paired: boolean = false;
  @State private relayHost: string = '';
  @State private status: string = '正在检查配对状态…';
  @State private busy: boolean = false;
  @StorageLink('pendingRoute') private pendingRoute: string = '';

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.refresh();
  }

  /// Load pairing state; if paired, silently refresh the push subscription.
  private async refresh(): Promise<void> {
    const pairing = await RelayStore.loadPairing(this.context());
    if (pairing === null) {
      this.paired = false;
      this.relayHost = '';
      this.status = '尚未配对。请扫描 Fleet 桌面端「移动端」页的二维码。';
      return;
    }
    this.paired = true;
    this.relayHost = hostOf(pairing.relayUrl);
    await this.register('已配对，正在刷新推送订阅…');
  }

  /// Run the push-registration flow, surfacing progress/errors in `status`.
  private async register(pendingMsg: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.status = pendingMsg;
    try {
      const state = await registerForPush(this.context());
      this.status = state === 'subscribed'
        ? '推送已启用。桌面端有新决策时会通知这台设备。'
        : '尚未配对。请先扫码配对。';
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'register failed: %{public}s', JSON.stringify(err));
      this.status = '订阅失败：' + (err.message ?? JSON.stringify(err));
    } finally {
      this.busy = false;
    }
  }

  /// Scan the desktop QR, persist the pairing, then register for push.
  private async startPairing(): Promise<void> {
    if (this.busy) {
      return;
    }
    try {
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true,
      };
      const result = await scanBarcode.startScanForResult(this.context(), options);
      const pairing = parsePairingUrl(result.originalValue);
      if (pairing === null) {
        this.status = '二维码无法识别为 Fleet 配对码。';
        return;
      }
      await RelayStore.savePairing(this.context(), pairing);
      this.paired = true;
      this.relayHost = hostOf(pairing.relayUrl);
      await this.register('配对成功，正在订阅推送…');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'scan failed: %{public}s', JSON.stringify(err));
      this.status = '扫码取消或失败。';
    }
  }

  build() {
    Column({ space: 20 }) {
      Text('Claw Fleet')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)

      Text(this.paired ? ('已连接 · ' + this.relayHost) : '未配对')
        .fontSize(15)
        .fontColor(this.paired ? '#1a7f37' : '#8a6d3b')

      Text(this.status)
        .fontSize(16)
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })

      if (this.pendingRoute.length > 0) {
        Text('有一条待处理决策：' + this.pendingRoute)
          .fontSize(14)
          .fontColor('#0a5bd3')
          .padding({ left: 24, right: 24 })
      }

      Button(this.paired ? '重新扫码配对' : '扫码配对')
        .width('70%')
        .enabled(!this.busy)
        .onClick(() => {
          this.startPairing();
        })

      if (this.paired) {
        Button('刷新推送订阅')
          .width('70%')
          .backgroundColor('#eef1f5')
          .fontColor('#333333')
          .enabled(!this.busy)
          .onClick(() => {
            this.register('正在刷新推送订阅…');
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 16, right: 16 })
  }
}

/// Host (and port) of a relay URL for a compact status line.
function hostOf(url: string): string {
  let s = url.replace(/^https?:\/\//, '');
  const slash = s.indexOf('/');
  if (slash >= 0) {
    s = s.substring(0, slash);
  }
  return s;
}
