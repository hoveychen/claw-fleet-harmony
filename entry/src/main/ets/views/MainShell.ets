import { common } from '@kit.AbilityKit';
import { ColorTokens, themeTokens } from '../common/Theme';
import { t } from '../common/I18n';
import { RelayClient, DeviceInfo, RelayHandlers } from '../common/Relay';
import { RelayStore } from '../common/RelayStore';
import { loadClientId, deviceLabel, DEVICE_PLATFORM } from '../common/Device';
import { SessionInfo } from '../models/Types';
import { DecisionsView } from './DecisionsView';
import { TasksView } from './TasksView';
import { WikiView } from './WikiView';
import { MoreView } from './MoreView';

/// The paired-state app shell: a top header, the active tab body, and a bottom
/// bar of 4 tabs split around a center "新会话" FAB. Mirrors mobile-web's App
/// shell (App.tsx).
///
/// This shell owns the single relay connection (the native peer of App.tsx's
/// clientRef) so every tab shares one WebSocket: the live `connected` /
/// `agentOnline` link state, the `sessions` snapshot, and the optimistic
/// read-marking all live here and flow down to the tab bodies. The connection
/// is opened once `clientId` resolves and torn down when the shell unmounts.
@Component
export struct MainShell {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @StorageProp('lang') lang: string = 'zh';
  @State tab: string = 'decisions';
  onRepair: () => void = () => {};
  onNewSession: () => void = () => {};

  // Relay link + snapshot state, pushed down to the tab bodies.
  @State private connected: boolean = false;
  @State private agentOnline: boolean = false;
  @State private sessionsLoaded: boolean = false;
  @State private sessions: SessionInfo[] = [];
  // Flips true once the relay client is constructed (after clientId resolves),
  // gating the shell body so TasksView is created with a non-null client.
  @State private ready: boolean = false;

  private client: RelayClient | null = null;
  private clientId: string = '';

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    loadClientId(this.ctx())
      .then((id: string) => {
        this.clientId = id;
        this.startRelay();
      })
      .catch(() => {
        // Even without a persisted id we still connect; the desktop just shows
        // this phone as a fresh device each launch.
        this.startRelay();
      });
  }

  aboutToDisappear(): void {
    if (this.client) {
      this.client.close();
      this.client = null;
    }
  }

  private deviceInfo(): DeviceInfo {
    const pushSubscribed = AppStorage.get<boolean>('pushSubscribed') ?? false;
    return {
      clientId: this.clientId,
      label: deviceLabel(),
      platform: DEVICE_PLATFORM,
      pushSubscribed,
      supportsGzip: false,
      supportsBinary: false,
    };
  }

  private async startRelay(): Promise<void> {
    const pairing = await RelayStore.loadPairing(this.ctx());
    if (pairing === null) {
      this.ready = true;
      return;
    }
    const handlers: RelayHandlers = {
      onStatus: (connected: boolean) => {
        this.connected = connected;
      },
      onAgentOnline: (online: boolean) => {
        this.agentOnline = online;
      },
      onSessions: (list: SessionInfo[]) => {
        this.sessions = list;
        this.sessionsLoaded = true;
      },
    };
    this.client = new RelayClient(pairing.relayUrl, pairing.secret, handlers, () => this.deviceInfo());
    this.client.connect();
    this.ready = true;
  }

  private statusColor(): string {
    if (!this.connected) {
      return this.tk().textDim;
    }
    return this.agentOnline ? this.tk().success : this.tk().warning;
  }

  private statusLabel(): string {
    if (!this.connected) {
      return t('连接中…');
    }
    return this.agentOnline ? t('桌面端在线') : t('桌面端离线');
  }

  @Builder
  header() {
    Row() {
      Text('Fleet')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.tk().text)
        .layoutWeight(1)
      Row({ space: 6 }) {
        Circle({ width: 8, height: 8 }).fill(this.statusColor())
        Text(this.statusLabel()).fontSize(12).fontColor(this.tk().textSecondary)
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.tk().bgGlass)
    .border({ width: { bottom: 1 }, color: this.tk().border })
  }

  @Builder
  tabItem(key: string, icon: string, label: string) {
    Column({ space: 2 }) {
      Text(icon).fontSize(20)
      Text(label)
        .fontSize(11)
        .fontColor(this.tab === key ? this.tk().accent : this.tk().textSecondary)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.tab = key;
    })
  }

  @Builder
  fab() {
    Column() {
      Stack() {
        Text('+').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#ffffff')
      }
      .width(46)
      .height(46)
      .borderRadius(23)
      .backgroundColor(this.tk().accent)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.onNewSession())
  }

  @Builder
  bottomBar() {
    Row() {
      this.tabItem('decisions', '📥', t('决策'))
      this.tabItem('tasks', '📋', t('任务'))
      this.fab()
      this.tabItem('wiki', '📚', t('知识库'))
      this.tabItem('more', '⋯', t('更多'))
    }
    .width('100%')
    .height(60)
    .backgroundColor(this.tk().bgGlass)
    .border({ width: { top: 1 }, color: this.tk().border })
  }

  build() {
    Column() {
      this.header()
      Stack() {
        if (this.tab === 'decisions') {
          DecisionsView()
        } else if (this.tab === 'tasks') {
          // Gate on `ready` so TasksView is only created once the relay client
          // exists — a plain (non-reactive) member wouldn't update if it were
          // null at first mount.
          if (this.ready) {
            TasksView({
              sessions: this.sessions,
              client: this.client,
              connected: this.connected,
              agentOnline: this.agentOnline,
              sessionsLoaded: this.sessionsLoaded,
              onOpenSession: (_s: SessionInfo) => {
                // Session detail overlay lands in P5.
              },
            })
          } else {
            Column() {
              LoadingProgress().width(40).height(40).color(this.tk().accent)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          }
        } else if (this.tab === 'wiki') {
          WikiView()
        } else {
          MoreView({ onRepair: this.onRepair })
        }
      }
      .layoutWeight(1)
      .width('100%')

      this.bottomBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.tk().bg)
  }
}
