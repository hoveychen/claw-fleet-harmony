import { common } from '@kit.AbilityKit';
import { ColorTokens, themeTokens } from '../common/Theme';
import { t } from '../common/I18n';
import { RelayClient, DeviceInfo, RelayHandlers } from '../common/Relay';
import { RelayStore } from '../common/RelayStore';
import { loadClientId, deviceLabel, DEVICE_PLATFORM } from '../common/Device';
import { SessionInfo, PendingDecision, PendingSnapshot, DecisionRequest, DecisionKind, TodayUsage } from '../models/Types';
import { GuardRequest, ElicitationRequest, FleetAskRequest } from '../models/Types';
import { PlanApprovalRequest, PermissionPromptRequest, A2uiRenderRequest } from '../models/Types';
import { DecisionsView } from './DecisionsView';
import { TasksView } from './TasksView';
import { WikiView } from './WikiView';
import { MoreView } from './MoreView';
import { SessionDetailView } from './SessionDetailView';
import { NewSessionSheet } from './Composer';
import { UsageView } from './UsageView';
import { RepoView } from './RepoView';
import { RepoDetailView } from './RepoDetailView';
import { WikiDocView } from './WikiDocView';
import { RepoSummary, WikiDoc } from '../models/Types';
import { Icon } from '../common/Icon';
import { CAPSULE_INSET_RIGHT, HEADER_HEIGHT } from '../common/SafeArea';

/// Every DecisionRequest variant carries a string `id`; this lets us read it off
/// the opaque business payload without discriminating the union.
interface DecisionReqId {
  id: string;
}

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
  @StorageProp('safeTop') safeTop: number = 0;
  @StorageProp('safeBottom') safeBottom: number = 0;
  @State tab: string = 'decisions';
  onRepair: () => void = () => {};
  onNewSession: () => void = () => {};

  // Relay link + snapshot state, pushed down to the tab bodies.
  @State private connected: boolean = false;
  @State private agentOnline: boolean = false;
  @State private sessionsLoaded: boolean = false;
  @State private sessions: SessionInfo[] = [];
  // Pending decision cards (native peer of App.tsx's `decisions`). Fed by the
  // live decision_created/decision_resolved events + the pending_snapshot pull;
  // rendered by DecisionsView (the 6 card kinds land in P4's view work).
  @State private decisions: PendingDecision[] = [];
  // Flips true once the relay client is constructed (after clientId resolves),
  // gating the shell body so TasksView is created with a non-null client.
  @State private ready: boolean = false;
  // The session whose detail overlay is open (null = shell only). Opened from a
  // TasksView card; closed by the detail view's back button.
  @State private selectedSession: SessionInfo | null = null;
  // The 新会话 sheet overlay (opened from the center FAB).
  @State private showNewSession: boolean = false;
  // The 账号与用量 overlay (opened from the More tab).
  @State private showUsage: boolean = false;
  // The 仓库 list overlay + the selected-repo detail overlay above it.
  @State private showRepo: boolean = false;
  @State private repoDetail: RepoSummary | null = null;
  // The open wiki doc (full-screen reader overlay), opened from the Wiki tab.
  @State private wikiDoc: WikiDoc | null = null;
  // Today's cumulative token/cost, polled while the desktop is online; shown in
  // the header and handed to the Usage page so it isn't recomputed there.
  @State private todayUsage: TodayUsage | null = null;

  private client: RelayClient | null = null;
  private clientId: string = '';
  // Generation counter cancelling the today_usage poll loop across reconnects.
  private usageGen: number = 0;

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
        // A freshly-online desktop replays its pending decisions via the
        // authoritative snapshot (live decision_created events may have been
        // missed while it was offline).
        if (online) {
          this.refreshPending();
          this.startUsagePoll();
        } else {
          this.usageGen += 1; // cancel the poll loop
        }
      },
      onSessions: (list: SessionInfo[]) => {
        this.sessions = list;
        this.sessionsLoaded = true;
      },
      onDecisionCreated: (kind: string, request: Object) => {
        this.addDecision(kind, request);
      },
      onDecisionResolved: (_kind: string, id: string) => {
        this.removeDecision(id);
      },
    };
    this.client = new RelayClient(pairing.relayUrl, pairing.secret, handlers, () => this.deviceInfo());
    this.client.connect();
    this.ready = true;
  }

  /// A live decision_created event. `request` is the opaque sealed payload's
  /// business object; every DecisionRequest variant carries a string `id`.
  private addDecision(kind: string, request: Object): void {
    const req = request as DecisionRequest;
    const id = (request as DecisionReqId).id;
    if (!id || id.length === 0) {
      return;
    }
    if (this.decisions.some((d: PendingDecision) => d.id === id)) {
      return;
    }
    const entry: PendingDecision = { kind: kind as DecisionKind, id, request: req, arrivedAt: Date.now() };
    this.decisions = this.decisions.concat(entry);
  }

  private removeDecision(id: string): void {
    this.decisions = this.decisions.filter((d: PendingDecision) => d.id !== id);
  }

  /// Poll today_usage while the desktop is online (20s cadence, the desktop
  /// computes the figure). A generation counter cancels stale loops so a
  /// reconnect doesn't stack timers.
  private startUsagePoll(): void {
    this.usageGen += 1;
    const gen = this.usageGen;
    const tick = () => {
      if (gen !== this.usageGen) {
        return;
      }
      const client = this.client;
      if (client && client.isAuthed) {
        client.request<TodayUsage>('today_usage')
          .then((u: TodayUsage) => {
            if (gen === this.usageGen) {
              this.todayUsage = u;
            }
          })
          .catch((_e: Object) => {})
          .finally(() => {
            if (gen === this.usageGen) {
              setTimeout(tick, 20000);
            }
          });
      } else if (gen === this.usageGen) {
        setTimeout(tick, 20000);
      }
    };
    tick();
  }

  /// Pull the authoritative pending snapshot and replace the list, preserving
  /// each card's original arrival stamp so a refresh doesn't reshuffle order.
  private refreshPending(): void {
    const client = this.client;
    if (!client) {
      return;
    }
    client.request<PendingSnapshot>('pending_snapshot')
      .then((snap: PendingSnapshot) => {
        const prevArrived = new Map<string, number>();
        for (const d of this.decisions) {
          prevArrived.set(d.id, d.arrivedAt);
        }
        const now = Date.now();
        const fresh: PendingDecision[] = [];
        this.collectKind('guard', (snap.guard ?? []) as DecisionRequest[], fresh, prevArrived, now);
        this.collectKind('elicitation', (snap.elicitation ?? []) as DecisionRequest[], fresh, prevArrived, now);
        this.collectKind('fleet-ask', (snap.fleetAsk ?? []) as DecisionRequest[], fresh, prevArrived, now);
        this.collectKind('plan-approval', (snap.planApproval ?? []) as DecisionRequest[], fresh, prevArrived, now);
        this.collectKind('permission-prompt', (snap.permissionPrompt ?? []) as DecisionRequest[], fresh, prevArrived, now);
        this.collectKind('a2ui-render', (snap.a2uiRender ?? []) as DecisionRequest[], fresh, prevArrived, now);
        this.decisions = fresh;
      })
      .catch((_e: Object) => {
        // agent offline — live events will catch us up later
      });
  }

  private collectKind(kind: DecisionKind, list: DecisionRequest[],
    out: PendingDecision[], prevArrived: Map<string, number>, now: number): void {
    for (const req of list) {
      const id = (req as DecisionReqId).id;
      const arrivedAt = prevArrived.get(id) ?? now;
      out.push({ kind, id, request: req, arrivedAt });
    }
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

  private fmtTokens(n: number): string {
    if (n >= 1000000) {
      return `${(n / 1000000).toFixed(1)}M`;
    }
    if (n >= 1000) {
      return `${(n / 1000).toFixed(1)}K`;
    }
    return `${n}`;
  }

  @Builder
  header() {
    Row() {
      Text('Fleet')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.tk().text)
        .layoutWeight(1)
      if (this.todayUsage !== null) {
        Row({ space: 4 }) {
          Text(`$${this.todayUsage.costUsd.toFixed(2)}`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.tk().text)
          Text(this.fmtTokens(this.todayUsage.inputTokens + this.todayUsage.outputTokens))
            .fontSize(11)
            .fontColor(this.tk().textDim)
        }
        .margin({ right: 10 })
      }
      Row({ space: 6 }) {
        Circle({ width: 8, height: 8 }).fill(this.statusColor())
        Text(this.statusLabel()).fontSize(12).fontColor(this.tk().textSecondary)
      }
    }
    .width('100%')
    .height(HEADER_HEIGHT)
    .padding({ left: 16, right: CAPSULE_INSET_RIGHT })
    .backgroundColor(this.tk().bgGlass)
    .border({ width: { bottom: 1 }, color: this.tk().border })
  }

  @Builder
  tabItem(key: string, icon: Resource, label: string, badge: number) {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Icon({ src: icon, iconSize: 22, color: this.tab === key ? this.tk().accent : this.tk().textSecondary })
        if (badge > 0) {
          Text(badge > 99 ? '99+' : `${badge}`)
            .fontSize(9)
            .fontColor('#ffffff')
            .backgroundColor(this.tk().accent)
            .borderRadius(8)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .constraintSize({ minWidth: 14 })
            .textAlign(TextAlign.Center)
            .margin({ right: -8, top: -4 })
        }
      }
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
    // iPhone 风格凸起圆形动作按钮：圆钮浮在导航栏之上，下方带「新会话」标签。
    Stack({ alignContent: Alignment.Bottom }) {
      Text(t('新会话'))
        .fontSize(10.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.tk().accent)
        .margin({ bottom: 6 })
      Stack() {
        Icon({ src: $r('app.media.ic_plus'), iconSize: 24, color: '#ffffff' })
      }
      .width(46)
      .height(46)
      .borderRadius(23)
      .backgroundColor(this.tk().accent)
      .shadow({ radius: 10, color: 'rgba(0,0,0,0.28)', offsetX: 0, offsetY: 3 })
      .offset({ y: -18 })
    }
    .layoutWeight(1)
    .height('100%')
    .onClick(() => {
      this.showNewSession = true;
    })
  }

  @Builder
  bottomBar() {
    Row() {
      this.tabItem('decisions', $r('app.media.ic_inbox'), t('决策'), this.decisions.length)
      this.tabItem('tasks', $r('app.media.ic_list_checks'), t('任务'), 0)
      this.fab()
      this.tabItem('wiki', $r('app.media.ic_book_open'), t('知识库'), 0)
      this.tabItem('more', $r('app.media.ic_ellipsis'), t('更多'), 0)
    }
    .width('100%')
    .height(60 + this.safeBottom)
    .padding({ bottom: this.safeBottom })
    .backgroundColor(this.tk().bgGlass)
    .border({ width: { top: 1 }, color: this.tk().border })
  }

  build() {
    Stack() {
      this.shell()
      if (this.selectedSession !== null) {
        SessionDetailView({
          session: this.selectedSession,
          client: this.client,
          onBack: () => {
            this.selectedSession = null;
          },
        })
      }
      if (this.showNewSession) {
        NewSessionSheet({
          sessions: this.sessions,
          client: this.client,
          onClose: () => {
            this.showNewSession = false;
          },
        })
      }
      if (this.showUsage) {
        UsageView({
          client: this.client,
          todayUsage: this.todayUsage,
          onBack: () => {
            this.showUsage = false;
          },
        })
      }
      if (this.showRepo) {
        RepoView({
          client: this.client,
          onBack: () => {
            this.showRepo = false;
          },
          onOpenRepo: (repo: RepoSummary) => {
            this.repoDetail = repo;
          },
        })
      }
      if (this.repoDetail !== null) {
        RepoDetailView({
          repo: this.repoDetail,
          client: this.client,
          onBack: () => {
            this.repoDetail = null;
          },
        })
      }
      if (this.wikiDoc !== null) {
        WikiDocView({
          doc: this.wikiDoc,
          client: this.client,
          onBack: () => {
            this.wikiDoc = null;
          },
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  shell() {
    Column() {
      this.header()
      Stack() {
        if (this.tab === 'decisions') {
          DecisionsView({
            decisions: this.decisions,
            agentOnline: this.agentOnline,
            sessions: this.sessions,
            client: this.client,
            onAnswered: (id: string) => {
              this.removeDecision(id);
            },
            onOpenSession: (s: SessionInfo) => {
              this.selectedSession = s;
            },
          })
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
              onOpenSession: (s: SessionInfo) => {
                this.selectedSession = s;
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
          WikiView({
            client: this.client,
            onOpenDoc: (doc: WikiDoc) => {
              this.wikiDoc = doc;
            },
          })
        } else {
          MoreView({
            onRepair: this.onRepair,
            connected: this.connected,
            agentOnline: this.agentOnline,
            onOpenUsage: () => {
              this.showUsage = true;
            },
            onOpenRepo: () => {
              this.showRepo = true;
            },
          })
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
