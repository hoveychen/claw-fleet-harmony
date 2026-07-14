import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { t, getLang } from '../common/I18n';
import { ColorTokens, themeTokens } from '../common/Theme';
import { RelayClient } from '../common/Relay';
import { MarkdownView } from '../common/Markdown';
import {
  PendingDecision,
  GuardRequest, PlanApprovalRequest, PermissionPromptRequest, A2uiRenderRequest, FleetAskRequest,
  FleetAskQuestion, ElicitationOption, FleetAskFormField, FleetAskImage, CommandView, CommandLeaf,
} from '../models/Types';
import { EmptyState } from './EmptyState';

/// The 决策 tab — native port of mobile-web/src/views/DecisionsView.tsx. Renders
/// one focused card at a time with a queue bar (the desktop panel's active-card
/// model) and round-trips answers via `client.answer(...)`, whose payload shapes
/// mirror claw-fleet-core/src/mobile_relay.rs `handle_answer`.
///
/// Native degradations vs. the web original (atomic-service constraints): the
/// fleet-ask HTML preview can't render (ArkWeb `Web` is unavailable in an
/// atomic service) so it shows a "view on desktop" note; markdown renders via the
/// hand-rolled MarkdownView; images / preceding-narration / guard AI-analysis
/// land in a follow-up pass. Answers are fully functional for all six kinds.

const KIND_LABELS: Record<string, string> = {
  'guard': '命令审批',
  'elicitation': '问题请示',
  'fleet-ask': '决策卡',
  'plan-approval': '计划审批',
  'permission-prompt': '权限请求',
  'a2ui-render': 'Agent 界面',
};

function kindLabel(kind: string): string {
  const zh = KIND_LABELS[kind];
  return zh ? t(zh) : kind;
}

/// Every DecisionRequest variant carries these; read them off the union without
/// discriminating it (ArkTS needs an `as` cast to reach shared union fields).
interface DecisionMeta {
  id: string;
  sessionId: string;
  workspaceName: string;
  aiTitle?: string | null;
}

/// Guard and permission prompts have no `parked` (their timeout is a deny, not a
/// pause); the others may. Read it defensively off the union.
interface HasParked {
  parked?: boolean;
}

// ── Answer payload shapes (typed literals — ArkTS bans dynamic object/Record
//    literals, so each answer is a declared interface instance). ──────────────

interface GuardAllowRule {
  prefix: string;
  sourceTag?: string | null;
}
interface GuardAnswer {
  event: string;
  kind: string;
  id: string;
  allow: boolean;
  reason?: string;
  alwaysAllow?: GuardAllowRule;
}
interface PermissionAnswer {
  event: string;
  kind: string;
  id: string;
  allow: boolean;
  reason?: string;
}
interface PlanAnswer {
  event: string;
  kind: string;
  id: string;
  decision: string;
  editedPlan?: string;
  feedback?: string;
}
interface A2uiAnswer {
  event: string;
  kind: string;
  id: string;
  cancelled: boolean;
  actionName?: string;
  actionContext: Record<string, string>;
}
interface QuestionsAnswer {
  event: string;
  kind: string;
  id: string;
  declined?: boolean;
  cancelled?: boolean;
  answers: Record<string, string>;
}

/// A fresh dynamic string map. ArkTS bans empty object literals typed as Record,
/// so seed from JSON.parse and index-assign (Record supports index writes).
function emptyStrRecord(): Record<string, string> {
  return JSON.parse('{}') as Record<string, string>;
}

// Relay request/response shapes for the guard AI risk analysis (guard_analyze).
interface GuardAnalyzeParams {
  command: string;
  context: string;
  lang: string;
}
interface GuardAnalyzeResp {
  analysis: string;
}

// Relay request/response shapes for a decision-card image asset (decision_asset).
interface AssetParams {
  id: string;
  qidx: string;
  rel: string;
}
interface AssetResp {
  mime: string;
  base64: string;
}

// ── Guard "always allow" prefix computation (port of the web heuristic) ────────

function looksLikeSubcommand(tok: string): boolean {
  if (tok.length === 0) {
    return false;
  }
  const first = tok.charAt(0);
  if (first < 'a' || first > 'z') {
    return false;
  }
  for (let i = 1; i < tok.length; i++) {
    const c = tok.charAt(i);
    const ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c === '_' || c === '-';
    if (!ok) {
      return false;
    }
  }
  return true;
}

/// `argv[0]` plus the first bare-word subcommand (git push / npm test).
function computeLeafAllowPrefix(argv: string[]): string {
  const head = argv.length > 0 ? argv[0] : '';
  if (head.length === 0) {
    return '';
  }
  for (let i = 1; i < argv.length; i++) {
    if (looksLikeSubcommand(argv[i])) {
      return `${head} ${argv[i]}`;
    }
  }
  return head;
}

/// One prefix per triggering AST leaf not already covered; legacy payloads fall
/// back to every leaf, a missing AST to the raw command's first line.
function computeGuardAllowPrefixes(command: string, view?: CommandView | null): string[] {
  if (view && view.leaves.length > 0) {
    const anyTriggering = view.leaves.some((leaf: CommandLeaf) => leaf.triggering === true);
    const eligible = anyTriggering
      ? view.leaves.filter((leaf: CommandLeaf) => leaf.triggering === true && leaf.already_allowed !== true)
      : view.leaves;
    const out: string[] = [];
    const seen = new Set<string>();
    for (const leaf of eligible) {
      const p = computeLeafAllowPrefix(leaf.argv);
      if (p.length > 0 && !seen.has(p)) {
        seen.add(p);
        out.push(p);
      }
    }
    if (out.length > 0) {
      return out;
    }
    if (anyTriggering) {
      return [];
    }
  }
  const firstLine = command.split('\n')[0].trim();
  if (firstLine.length === 0) {
    return [];
  }
  const fallback = computeLeafAllowPrefix(firstLine.split(' ').filter((x: string) => x.length > 0));
  return fallback.length > 0 ? [fallback] : [];
}

/// Drop the Fleet TTS divider (a lone `---` line splits summary / body).
function stripTtsDivider(text: string): string {
  const lines = text.split('\n');
  const idx = lines.findIndex((l: string) => l.trim() === '---');
  if (idx === -1) {
    return text;
  }
  const kept: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (i !== idx) {
      kept.push(lines[i]);
    }
  }
  return kept.join('\n');
}

// ── Main view ─────────────────────────────────────────────────────────────────

@Component
export struct DecisionsView {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @StorageProp('lang') lang: string = 'zh';

  @Prop decisions: PendingDecision[] = [];
  @Prop agentOnline: boolean = false;
  client: RelayClient | null = null;
  onAnswered: (id: string) => void = () => {};

  @State private activeId: string = '';

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  private sorted(): PendingDecision[] {
    return [...this.decisions].sort((a: PendingDecision, b: PendingDecision) => a.arrivedAt - b.arrivedAt);
  }

  private activeIndex(): number {
    const list = this.sorted();
    const found = list.findIndex((d: PendingDecision) => d.id === this.activeId);
    if (found >= 0) {
      return found;
    }
    return 0;
  }

  private activeList(): PendingDecision[] {
    const list = this.sorted();
    if (list.length === 0) {
      return [];
    }
    const idx = Math.min(this.activeIndex(), list.length - 1);
    return [list[idx]];
  }

  private meta(d: PendingDecision): DecisionMeta {
    return d.request as DecisionMeta;
  }

  @Builder
  queueBar() {
    Scroll() {
      Row({ space: 6 }) {
        ForEach(this.sorted(), (d: PendingDecision, i: number) => {
          Column({ space: 1 }) {
            Text(kindLabel(d.kind))
              .fontSize(11)
              .fontColor(i === this.activeIndex() ? this.tk().accent : this.tk().textSecondary)
              .fontWeight(i === this.activeIndex() ? FontWeight.Medium : FontWeight.Normal)
            Text(this.meta(d).workspaceName)
              .fontSize(10)
              .fontColor(this.tk().textDim)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 110 })
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor(i === this.activeIndex() ? this.tk().accentSoft : this.tk().bgInput)
          .border({ width: 1, color: i === this.activeIndex() ? this.tk().accent : this.tk().border })
          .onClick(() => {
            this.activeId = d.id;
          })
        }, (d: PendingDecision) => d.id)
      }
      .padding({ left: 12, right: 12 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ top: 10, bottom: 4 })
  }

  @Builder
  cardHeader(d: PendingDecision) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(kindLabel(d.kind))
          .fontSize(12)
          .fontColor(this.tk().accent)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor(this.tk().accentSoft)
        Text(this.meta(d).workspaceName)
          .fontSize(12)
          .fontColor(this.tk().textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      if (this.meta(d).aiTitle && (this.meta(d).aiTitle as string).length > 0) {
        Text(this.meta(d).aiTitle)
          .fontSize(13)
          .fontColor(this.tk().text)
          .fontWeight(FontWeight.Medium)
          .width('100%')
      }
      if ((d.request as HasParked).parked === true) {
        Column({ space: 3 }) {
          Text(t('已超时 · 会话已暂停'))
            .fontSize(11)
            .fontColor(this.tk().warning)
            .fontWeight(FontWeight.Medium)
          Text(t('等待超时，Fleet 已经掐掉那一轮并把问题留了下来。回复后会带着你的答复唤醒会话继续。'))
            .fontSize(11)
            .fontColor(this.tk().textSecondary)
            .lineHeight(16)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(8)
        .borderRadius(8)
        .backgroundColor(this.tk().bgInput)
        .border({ width: 1, color: this.tk().warning })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  activeCard(d: PendingDecision) {
    Scroll() {
      Column({ space: 12 }) {
        this.cardHeader(d)
        if (d.kind === 'guard') {
          GuardCard({
            request: d.request as GuardRequest,
            client: this.client,
            onAnswered: this.onAnswered,
          })
        } else if (d.kind === 'permission-prompt') {
          PermissionCard({
            request: d.request as PermissionPromptRequest,
            client: this.client,
            onAnswered: this.onAnswered,
          })
        } else if (d.kind === 'plan-approval') {
          PlanCard({
            request: d.request as PlanApprovalRequest,
            client: this.client,
            onAnswered: this.onAnswered,
          })
        } else if (d.kind === 'a2ui-render') {
          A2uiCard({
            request: d.request as A2uiRenderRequest,
            client: this.client,
            onAnswered: this.onAnswered,
          })
        } else {
          QuestionsCard({
            request: d.request as FleetAskRequest,
            isFleetAsk: d.kind === 'fleet-ask',
            client: this.client,
            onAnswered: this.onAnswered,
          })
        }
      }
      .width('100%')
      .padding(14)
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.TopStart)
  }

  build() {
    Column() {
      if (this.decisions.length === 0) {
        if (this.agentOnline) {
          EmptyState({
            icon: '✅',
            title: t('没有待处理的决策'),
            subtitle: t('所有决策卡都已作答，收工。有新决策时会自动出现在这里。'),
          })
        } else {
          EmptyState({
            icon: '📴',
            title: t('桌面端离线'),
            subtitle: t('暂时收不到新决策，等桌面端重新上线就会同步过来。'),
          })
        }
      } else {
        if (this.sorted().length > 1) {
          this.queueBar()
        }
        // Keyed ForEach over the single active card so a change of active id
        // remounts the card struct (fresh @State) — the ArkUI equivalent of the
        // web panel's `key={active.id}`.
        ForEach(this.activeList(), (d: PendingDecision) => {
          this.activeCard(d)
        }, (d: PendingDecision) => d.id)
        if (this.sorted().length > 1) {
          Text(t('第 {0} / {1} 张 · 处理完自动跳到下一张',
            Math.min(this.activeIndex(), this.sorted().length - 1) + 1, this.sorted().length))
            .fontSize(11)
            .fontColor(this.tk().textDim)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 4, bottom: 8 })
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.tk().bg)
  }
}

// ── guard ─────────────────────────────────────────────────────────────────────

@Component
struct GuardCard {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  request: GuardRequest = {} as GuardRequest;
  client: RelayClient | null = null;
  onAnswered: (id: string) => void = () => {};

  @State private reason: string = '';
  @State private showReason: boolean = false;
  @State private prefixMenuOpen: boolean = false;
  // Auto-fired LLM risk analysis: 'loading' | 'unavailable' | markdown text.
  @State private analysis: string = 'loading';

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  aboutToAppear(): void {
    const client = this.client;
    if (!client) {
      this.analysis = 'unavailable';
      return;
    }
    // Context is best-effort; the mobile client hasn't loaded the transcript
    // tail here, so we send the command alone (the desktop still classifies it).
    const params: GuardAnalyzeParams = { command: this.request.command, context: '', lang: getLang() };
    client.request<GuardAnalyzeResp>('guard_analyze', params, 40000)
      .then((r: GuardAnalyzeResp) => {
        this.analysis = r.analysis.length > 0 ? r.analysis : 'unavailable';
      })
      .catch((_e: Object) => {
        this.analysis = 'unavailable';
      });
  }

  private prefixes(): string[] {
    return computeGuardAllowPrefixes(this.request.command, this.request.structuredCommand);
  }

  private sourceTag(): string | null {
    return this.request.riskTags.length > 0 ? this.request.riskTags[0] : null;
  }

  private allow(): void {
    const a: GuardAnswer = { event: 'answer', kind: 'guard', id: this.request.id, allow: true };
    this.client?.answer(a);
    this.onAnswered(this.request.id);
  }

  private deny(): void {
    if (!this.showReason) {
      this.showReason = true;
      return;
    }
    const a: GuardAnswer = {
      event: 'answer', kind: 'guard', id: this.request.id, allow: false, reason: this.reason,
    };
    this.client?.answer(a);
    this.onAnswered(this.request.id);
  }

  private alwaysAllow(prefix: string): void {
    const rule: GuardAllowRule = { prefix, sourceTag: this.sourceTag() };
    const a: GuardAnswer = {
      event: 'answer', kind: 'guard', id: this.request.id, allow: true, alwaysAllow: rule,
    };
    this.client?.answer(a);
    this.onAnswered(this.request.id);
  }

  private onAlwaysAllowTap(): void {
    const p = this.prefixes();
    if (p.length === 1) {
      this.alwaysAllow(p[0]);
    } else {
      this.prefixMenuOpen = !this.prefixMenuOpen;
    }
  }

  @Builder
  analysisBlock() {
    // 'unavailable' hides the block entirely (LLM off / offline), matching web.
    if (this.analysis !== 'unavailable') {
      Column({ space: 4 }) {
        Text(t('AI 风险分析')).fontSize(12).fontColor(this.tk().textDim).fontWeight(FontWeight.Medium)
        if (this.analysis === 'loading') {
          Row({ space: 6 }) {
            LoadingProgress().width(16).height(16).color(this.tk().accent)
            Text(t('分析中…')).fontSize(12).fontColor(this.tk().textSecondary)
          }
        } else {
          MarkdownView({ content: this.analysis, mdFontSize: 13 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(10)
      .borderRadius(8)
      .backgroundColor(this.tk().bgInput)
    }
  }

  build() {
    Column({ space: 10 }) {
      Text(this.request.command)
        .fontSize(13)
        .fontColor(this.tk().text)
        .fontFamily('monospace')
        .width('100%')
        .padding(10)
        .borderRadius(8)
        .backgroundColor(this.tk().bgInput)
      if (this.request.riskTags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.request.riskTags, (tag: string) => {
            Text(tag)
              .fontSize(11)
              .fontColor(this.tk().error)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .margin({ right: 6, bottom: 4 })
              .borderRadius(6)
              .border({ width: 1, color: this.tk().error })
          })
        }
        .width('100%')
      }
      this.analysisBlock()
      if (this.showReason) {
        TextArea({ text: this.reason, placeholder: t('拒绝理由（可选，会转告给 AI）') })
          .fontSize(13)
          .fontColor(this.tk().text)
          .placeholderColor(this.tk().textDim)
          .backgroundColor(this.tk().bgInput)
          .borderRadius(8)
          .width('100%')
          .onChange((v: string) => {
            this.reason = v;
          })
      }
      if (this.prefixMenuOpen && this.prefixes().length > 1) {
        Column({ space: 4 }) {
          ForEach(this.prefixes(), (p: string) => {
            Text(`${t('总是允许')}  ${p}`)
              .fontSize(12)
              .fontColor(this.tk().text)
              .width('100%')
              .padding(8)
              .borderRadius(6)
              .backgroundColor(this.tk().bgInput)
              .onClick(() => this.alwaysAllow(p))
          })
        }
        .width('100%')
      }
      Row({ space: 8 }) {
        Button(this.showReason ? t('确认拒绝') : t('拒绝'))
          .fontSize(14)
          .fontColor(this.tk().error)
          .backgroundColor(Color.Transparent)
          .borderRadius(8)
          .border({ width: 1, color: this.tk().error })
          .layoutWeight(1)
          .onClick(() => this.deny())
        if (this.prefixes().length > 0) {
          Button(this.prefixes().length === 1 ? t('总是允许 {0}', this.prefixes()[0]) : t('总是允许…'))
            .fontSize(14)
            .fontColor(this.tk().textSecondary)
            .backgroundColor(this.tk().bgInput)
            .borderRadius(8)
            .layoutWeight(1)
            .onClick(() => this.onAlwaysAllowTap())
        }
        Button(t('允许'))
          .fontSize(14)
          .fontColor('#ffffff')
          .backgroundColor(this.tk().accent)
          .borderRadius(8)
          .layoutWeight(1)
          .onClick(() => this.allow())
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// ── permission-prompt ─────────────────────────────────────────────────────────

@Component
struct PermissionCard {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  request: PermissionPromptRequest = {} as PermissionPromptRequest;
  client: RelayClient | null = null;
  onAnswered: (id: string) => void = () => {};

  @State private reason: string = '';
  @State private showReason: boolean = false;

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  private inputJson(): string {
    try {
      return JSON.stringify(this.request.toolInput, null, 2);
    } catch (e) {
      return '';
    }
  }

  private allow(): void {
    const a: PermissionAnswer = { event: 'answer', kind: 'permission-prompt', id: this.request.id, allow: true };
    this.client?.answer(a);
    this.onAnswered(this.request.id);
  }

  private deny(): void {
    if (!this.showReason) {
      this.showReason = true;
      return;
    }
    const a: PermissionAnswer = {
      event: 'answer', kind: 'permission-prompt', id: this.request.id, allow: false, reason: this.reason,
    };
    this.client?.answer(a);
    this.onAnswered(this.request.id);
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 4 }) {
        Text(t('工具：')).fontSize(13).fontColor(this.tk().textSecondary)
        Text(this.request.toolName)
          .fontSize(13)
          .fontColor(this.tk().text)
          .fontFamily('monospace')
      }
      .width('100%')
      if (this.inputJson().length > 0 && this.inputJson() !== 'null') {
        Text(this.inputJson())
          .fontSize(12)
          .fontColor(this.tk().text)
          .fontFamily('monospace')
          .width('100%')
          .padding(10)
          .borderRadius(8)
          .backgroundColor(this.tk().bgInput)
      }
      if (this.showReason) {
        TextArea({ text: this.reason, placeholder: t('拒绝理由（可选）') })
          .fontSize(13)
          .fontColor(this.tk().text)
          .placeholderColor(this.tk().textDim)
          .backgroundColor(this.tk().bgInput)
          .borderRadius(8)
          .width('100%')
          .onChange((v: string) => {
            this.reason = v;
          })
      }
      Row({ space: 8 }) {
        Button(this.showReason ? t('确认拒绝') : t('拒绝'))
          .fontSize(14)
          .fontColor(this.tk().error)
          .backgroundColor(Color.Transparent)
          .borderRadius(8)
          .border({ width: 1, color: this.tk().error })
          .layoutWeight(1)
          .onClick(() => this.deny())
        Button(t('允许'))
          .fontSize(14)
          .fontColor('#ffffff')
          .backgroundColor(this.tk().accent)
          .borderRadius(8)
          .layoutWeight(1)
          .onClick(() => this.allow())
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// ── plan-approval ─────────────────────────────────────────────────────────────

@Component
struct PlanCard {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  request: PlanApprovalRequest = {} as PlanApprovalRequest;
  client: RelayClient | null = null;
  onAnswered: (id: string) => void = () => {};

  @State private expanded: boolean = false;
  @State private rejecting: boolean = false;
  @State private feedback: string = '';
  @State private editing: boolean = false;
  @State private editedPlan: string = '';

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  aboutToAppear(): void {
    this.editedPlan = this.request.planContent;
  }

  private isLong(): boolean {
    return this.request.planContent.length > 600;
  }

  private shownContent(): string {
    if (this.expanded || !this.isLong()) {
      return this.request.planContent;
    }
    return this.request.planContent.substring(0, 600);
  }

  private isEdited(): boolean {
    return this.editing && this.editedPlan.trim() !== this.request.planContent.trim();
  }

  private approve(): void {
    if (this.isEdited()) {
      const a: PlanAnswer = {
        event: 'answer', kind: 'plan-approval', id: this.request.id, decision: 'approve', editedPlan: this.editedPlan,
      };
      this.client?.answer(a);
    } else {
      const a: PlanAnswer = { event: 'answer', kind: 'plan-approval', id: this.request.id, decision: 'approve' };
      this.client?.answer(a);
    }
    this.onAnswered(this.request.id);
  }

  private reject(): void {
    if (!this.rejecting) {
      this.rejecting = true;
      return;
    }
    const a: PlanAnswer = {
      event: 'answer', kind: 'plan-approval', id: this.request.id, decision: 'reject', feedback: this.feedback,
    };
    this.client?.answer(a);
    this.onAnswered(this.request.id);
  }

  private toggleEditing(): void {
    if (this.editing) {
      // Leaving edit mode discards the draft (desktop "Cancel edit" semantics).
      this.editedPlan = this.request.planContent;
    }
    this.editing = !this.editing;
  }

  build() {
    Column({ space: 10 }) {
      if (this.request.planFilePath && (this.request.planFilePath as string).length > 0) {
        Text(this.request.planFilePath)
          .fontSize(11)
          .fontColor(this.tk().textDim)
          .fontFamily('monospace')
          .width('100%')
      }
      if (this.editing) {
        TextArea({ text: this.editedPlan })
          .fontSize(13)
          .fontColor(this.tk().text)
          .fontFamily('monospace')
          .backgroundColor(this.tk().bgInput)
          .borderRadius(8)
          .width('100%')
          .height(280)
          .onChange((v: string) => {
            this.editedPlan = v;
          })
      } else {
        MarkdownView({ content: this.shownContent(), color: this.tk().text })
        if (this.isLong()) {
          Text(this.expanded ? t('收起') : t('展开完整计划'))
            .fontSize(12)
            .fontColor(this.tk().accent)
            .onClick(() => {
              this.expanded = !this.expanded;
            })
        }
      }
      Text(this.editing ? t('放弃编辑') : t('编辑计划'))
        .fontSize(12)
        .fontColor(this.tk().textSecondary)
        .padding({ top: 4, bottom: 4 })
        .onClick(() => this.toggleEditing())
      if (this.rejecting) {
        TextArea({ text: this.feedback, placeholder: t('驳回意见（会转告给 AI 修改计划）') })
          .fontSize(13)
          .fontColor(this.tk().text)
          .placeholderColor(this.tk().textDim)
          .backgroundColor(this.tk().bgInput)
          .borderRadius(8)
          .width('100%')
          .onChange((v: string) => {
            this.feedback = v;
          })
      }
      Row({ space: 8 }) {
        Button(this.rejecting ? t('确认驳回') : t('驳回'))
          .fontSize(14)
          .fontColor(this.tk().error)
          .backgroundColor(Color.Transparent)
          .borderRadius(8)
          .border({ width: 1, color: this.tk().error })
          .layoutWeight(1)
          .onClick(() => this.reject())
        Button(this.isEdited() ? t('批准已编辑版') : t('批准'))
          .fontSize(14)
          .fontColor('#ffffff')
          .backgroundColor(this.tk().accent)
          .borderRadius(8)
          .layoutWeight(1)
          .onClick(() => this.approve())
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// ── a2ui-render ───────────────────────────────────────────────────────────────

@Component
struct A2uiCard {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  request: A2uiRenderRequest = {} as A2uiRenderRequest;
  client: RelayClient | null = null;
  onAnswered: (id: string) => void = () => {};

  @State private cancelling: boolean = false;

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  private cancel(): void {
    if (!this.cancelling) {
      this.cancelling = true;
      return;
    }
    const a: A2uiAnswer = {
      event: 'answer', kind: 'a2ui-render', id: this.request.id, cancelled: true, actionContext: emptyStrRecord(),
    };
    this.client?.answer(a);
    this.onAnswered(this.request.id);
  }

  build() {
    Column({ space: 12 }) {
      Text(t('Agent 发来一张自定义界面（A2UI）。移动端暂不支持渲染，请在桌面端处理这张卡。'))
        .fontSize(13)
        .fontColor(this.tk().textSecondary)
        .lineHeight(19)
        .width('100%')
      Row() {
        Button(this.cancelling ? t('确认取消这张卡') : t('取消（告知 agent）'))
          .fontSize(14)
          .fontColor(this.tk().error)
          .backgroundColor(Color.Transparent)
          .borderRadius(8)
          .border({ width: 1, color: this.tk().error })
          .layoutWeight(1)
          .onClick(() => this.cancel())
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// ── elicitation / fleet-ask ───────────────────────────────────────────────────

@Component
struct QuestionsCard {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  request: FleetAskRequest = {} as FleetAskRequest;
  isFleetAsk: boolean = false;
  client: RelayClient | null = null;
  onAnswered: (id: string) => void = () => {};

  // question text → selected option labels
  @State private selections: Map<string, string[]> = new Map<string, string[]>();
  // question text → free-form "other" text
  @State private custom: Map<string, string> = new Map<string, string>();
  // question text → user flipped single-select into multi-select
  @State private multiOverride: Map<string, boolean> = new Map<string, boolean>();
  // form field name → value
  @State private form: Map<string, string> = new Map<string, string>();
  @State private step: number = 0;
  @State private error: string = '';

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  aboutToAppear(): void {
    // Seed form defaults, mirroring the web initializer.
    const f = new Map<string, string>();
    for (const q of this.request.questions) {
      for (const field of q.formFields ?? []) {
        if (field.default !== undefined && field.default !== null) {
          f.set(field.name, `${field.default}`);
        } else if (field.kind === 'checkbox') {
          f.set(field.name, 'false');
        } else if (field.kind === 'range') {
          f.set(field.name, `${field.min ?? 0}`);
        }
      }
    }
    this.form = f;
  }

  private total(): number {
    return this.request.questions.length;
  }

  private qi(): number {
    return Math.min(this.step, this.total() - 1);
  }

  private effectiveMulti(q: FleetAskQuestion): boolean {
    return q.multiSelect || this.multiOverride.get(q.question) === true;
  }

  private picked(q: FleetAskQuestion): string[] {
    return this.selections.get(q.question) ?? [];
  }

  private isSelected(q: FleetAskQuestion, label: string): boolean {
    return this.picked(q).includes(label);
  }

  private toggle(q: FleetAskQuestion, label: string): void {
    const cur = this.picked(q);
    const next = new Map<string, string[]>(this.selections);
    if (this.effectiveMulti(q)) {
      next.set(q.question, cur.includes(label) ? cur.filter((l: string) => l !== label) : [...cur, label]);
    } else {
      next.set(q.question, cur.includes(label) ? [] : [label]);
    }
    this.selections = next;
  }

  private setCustom(q: FleetAskQuestion, v: string): void {
    const next = new Map<string, string>(this.custom);
    next.set(q.question, v);
    this.custom = next;
  }

  private editToOther(q: FleetAskQuestion, o: ElicitationOption): void {
    this.setCustom(q, o.description && o.description.length > 0 ? `${o.label} — ${o.description}` : o.label);
  }

  private flipMulti(q: FleetAskQuestion): void {
    const on = this.multiOverride.get(q.question) === true;
    const nextOv = new Map<string, boolean>(this.multiOverride);
    nextOv.set(q.question, !on);
    this.multiOverride = nextOv;
    if (on) {
      // back to single-select: trim to at most one
      const cur = this.picked(q);
      if (cur.length > 1) {
        const nextSel = new Map<string, string[]>(this.selections);
        nextSel.set(q.question, [cur[0]]);
        this.selections = nextSel;
      }
    }
  }

  private setForm(name: string, v: string): void {
    const next = new Map<string, string>(this.form);
    next.set(name, v);
    this.form = next;
  }

  private answeredQuestion(q: FleetAskQuestion): boolean {
    const picked = this.picked(q);
    const customText = (this.custom.get(q.question) ?? '').trim();
    const fields = q.formFields ?? [];
    let requiredOk = true;
    for (const field of fields) {
      if (field.required === true && (this.form.get(field.name) ?? '').trim().length === 0) {
        requiredOk = false;
      }
    }
    const answered = picked.length > 0 || customText.length > 0 || fields.length > 0;
    return answered && requiredOk;
  }

  private allAnswered(): boolean {
    for (const q of this.request.questions) {
      if (!this.answeredQuestion(q)) {
        return false;
      }
    }
    return true;
  }

  private decline(): void {
    const a: QuestionsAnswer = this.isFleetAsk
      ? { event: 'answer', kind: 'fleet-ask', id: this.request.id, cancelled: true, answers: emptyStrRecord() }
      : { event: 'answer', kind: 'elicitation', id: this.request.id, declined: true, answers: emptyStrRecord() };
    this.client?.answer(a);
    this.onAnswered(this.request.id);
  }

  private submit(): void {
    const answers = emptyStrRecord();
    for (const q of this.request.questions) {
      const parts = [...this.picked(q)];
      const customText = (this.custom.get(q.question) ?? '').trim();
      if (customText.length > 0) {
        parts.push(customText);
      }
      const hasForm = (q.formFields?.length ?? 0) > 0;
      if (parts.length === 0 && !hasForm) {
        this.error = t('「{0}」还没有作答', q.header && q.header.length > 0 ? q.header : truncate(q.question, 20));
        return;
      }
      let answer = parts.join(', ');
      if (answer.length > 0 && this.multiOverride.get(q.question) === true && !q.multiSelect) {
        answer = `${answer} [用户将此题从单选改为多选 / user switched this question from single-select to multi-select]`;
      }
      if (answer.length > 0) {
        answers[q.question] = answer;
      }
    }
    for (const q of this.request.questions) {
      for (const field of q.formFields ?? []) {
        const v = this.form.get(field.name) ?? '';
        if (field.required === true && v.trim().length === 0) {
          this.error = t('「{0}」是必填项', field.label);
          return;
        }
        answers[field.name] = v;
      }
    }
    const a: QuestionsAnswer = this.isFleetAsk
      ? { event: 'answer', kind: 'fleet-ask', id: this.request.id, cancelled: false, answers }
      : { event: 'answer', kind: 'elicitation', id: this.request.id, declined: false, answers };
    this.client?.answer(a);
    this.onAnswered(this.request.id);
  }

  @Builder
  optionRow(q: FleetAskQuestion, o: ElicitationOption) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(o.label)
          .fontSize(14)
          .fontColor(this.tk().text)
          .width('100%')
        if (o.description && o.description.length > 0) {
          Text(o.description)
            .fontSize(12)
            .fontColor(this.tk().textSecondary)
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('✎')
        .fontSize(14)
        .fontColor(this.tk().textDim)
        .onClick(() => this.editToOther(q, o))
    }
    .width('100%')
    .padding(10)
    .borderRadius(8)
    .backgroundColor(this.isSelected(q, o.label) ? this.tk().accentSoft : this.tk().bgInput)
    .border({ width: 1, color: this.isSelected(q, o.label) ? this.tk().accent : this.tk().border })
    .onClick(() => this.toggle(q, o.label))
  }

  @Builder
  formField(field: FleetAskFormField) {
    Column({ space: 4 }) {
      Row({ space: 2 }) {
        Text(field.label).fontSize(13).fontColor(this.tk().textSecondary)
        if (field.required === true) {
          Text('*').fontSize(13).fontColor(this.tk().error)
        }
      }
      if (field.kind === 'textarea') {
        TextArea({ text: this.form.get(field.name) ?? '', placeholder: field.placeholder ?? '' })
          .fontSize(13).fontColor(this.tk().text).placeholderColor(this.tk().textDim)
          .backgroundColor(this.tk().bgInput).borderRadius(8).width('100%')
          .onChange((v: string) => this.setForm(field.name, v))
      } else if (field.kind === 'select') {
        Select((field.options ?? []).map((o: string) => {
          const opt: SelectOption = { value: o };
          return opt;
        }))
          .value((this.form.get(field.name) ?? '').length > 0 ? (this.form.get(field.name) as string) : t('请选择…'))
          .font({ size: 13 }).fontColor(this.tk().text)
          .backgroundColor(this.tk().bgInput).borderRadius(8).width('100%')
          .onSelect((_i: number, value: string) => this.setForm(field.name, value))
      } else if (field.kind === 'radio') {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(field.options ?? [], (o: string) => {
            Text(o)
              .fontSize(13)
              .fontColor((this.form.get(field.name) ?? '') === o ? this.tk().accent : this.tk().textSecondary)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .margin({ right: 6, bottom: 6 })
              .borderRadius(6)
              .backgroundColor((this.form.get(field.name) ?? '') === o ? this.tk().accentSoft : this.tk().bgInput)
              .border({ width: 1, color: (this.form.get(field.name) ?? '') === o ? this.tk().accent : this.tk().border })
              .onClick(() => this.setForm(field.name, o))
          })
        }
        .width('100%')
      } else if (field.kind === 'checkbox') {
        Row({ space: 8 }) {
          Text((this.form.get(field.name) ?? 'false') === 'true' ? '☑' : '☐')
            .fontSize(18)
            .fontColor((this.form.get(field.name) ?? 'false') === 'true' ? this.tk().accent : this.tk().textDim)
          Text(field.label).fontSize(13).fontColor(this.tk().text)
        }
        .width('100%')
        .onClick(() => this.setForm(field.name, (this.form.get(field.name) ?? 'false') === 'true' ? 'false' : 'true'))
      } else if (field.kind === 'range') {
        Row({ space: 8 }) {
          Slider({
            value: Number.parseFloat(this.form.get(field.name) ?? `${field.min ?? 0}`),
            min: field.min ?? 0,
            max: field.max ?? 100,
            step: field.step ?? 1,
          })
            .layoutWeight(1)
            .selectedColor(this.tk().accent)
            .onChange((v: number) => this.setForm(field.name, `${v}`))
          Text(this.form.get(field.name) ?? `${field.min ?? 0}`)
            .fontSize(13).fontColor(this.tk().text).width(44).textAlign(TextAlign.End)
        }
        .width('100%')
      } else {
        TextInput({ text: this.form.get(field.name) ?? '', placeholder: field.placeholder ?? this.kindHint(field.kind) })
          .type(field.kind === 'number' ? InputType.Number : InputType.Normal)
          .fontSize(13).fontColor(this.tk().text).placeholderColor(this.tk().textDim)
          .backgroundColor(this.tk().bgInput).borderRadius(8).width('100%')
          .onChange((v: string) => this.setForm(field.name, v))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 6 })
  }

  private kindHint(kind: string): string {
    if (kind === 'date') {
      return 'YYYY-MM-DD';
    }
    if (kind === 'time') {
      return 'HH:MM';
    }
    if (kind === 'datetime') {
      return 'YYYY-MM-DDTHH:MM';
    }
    return '';
  }

  @Builder
  questionBody(q: FleetAskQuestion) {
    Column({ space: 8 }) {
      if (q.header && q.header.length > 0) {
        Text(q.header).fontSize(12).fontColor(this.tk().accent).fontWeight(FontWeight.Medium).width('100%')
      }
      MarkdownView({ content: stripTtsDivider(q.question), color: this.tk().text })
      if (this.isFleetAsk && q.html && (q.html as string).length > 0) {
        Text(t('完整预览请在桌面端查看'))
          .fontSize(12).fontColor(this.tk().textDim).width('100%')
          .padding(8).borderRadius(6).backgroundColor(this.tk().bgInput)
      }
      // fleet-ask images: render the gallery whenever present so no image is
      // lost (html, if any, is degraded to the note above rather than rendered).
      ForEach(q.images ?? [], (img: FleetAskImage) => {
        DecisionImage({
          requestId: this.request.id,
          qidx: this.qi(),
          name: img.name,
          caption: img.caption ?? '',
          client: this.client,
        })
      }, (img: FleetAskImage) => img.name)
      ForEach(q.options ?? [], (o: ElicitationOption) => {
        this.optionRow(q, o)
      })
      // Always-visible "Other" free-form composer.
      TextArea({
        text: this.custom.get(q.question) ?? '',
        placeholder: (q.options?.length ?? 0) > 0 ? t('自定义回答') : t('自由回答…'),
      })
        .fontSize(13).fontColor(this.tk().text).placeholderColor(this.tk().textDim)
        .backgroundColor(this.tk().bgInput).borderRadius(8).width('100%')
        .onChange((v: string) => this.setCustom(q, v))
      if ((q.options?.length ?? 0) > 0 && !q.multiSelect) {
        Text(this.multiOverride.get(q.question) === true ? t('已改为多选') : t('改为多选'))
          .fontSize(12)
          .fontColor(this.multiOverride.get(q.question) === true ? this.tk().accent : this.tk().textSecondary)
          .onClick(() => this.flipMulti(q))
      }
      ForEach(q.formFields ?? [], (field: FleetAskFormField) => {
        this.formField(field)
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 10 }) {
      if (this.total() > 1) {
        Text(t('第 {0} / {1} 题', this.qi() + 1, this.total()))
          .fontSize(11).fontColor(this.tk().textDim).width('100%')
      }
      ForEach([this.request.questions[this.qi()]], (q: FleetAskQuestion) => {
        this.questionBody(q)
      }, (q: FleetAskQuestion) => `${this.qi()}`)
      if (this.error.length > 0) {
        Text(this.error).fontSize(12).fontColor(this.tk().error).width('100%')
      }
      Row({ space: 8 }) {
        Button(this.isFleetAsk ? t('取消') : t('拒绝回答'))
          .fontSize(14).fontColor(this.tk().textSecondary).backgroundColor(this.tk().bgInput)
          .borderRadius(8).layoutWeight(1)
          .onClick(() => this.decline())
        if (this.total() > 1 && this.qi() > 0) {
          Button(t('上一题'))
            .fontSize(14).fontColor(this.tk().textSecondary).backgroundColor(this.tk().bgInput)
            .borderRadius(8).layoutWeight(1)
            .onClick(() => {
              this.step = this.qi() - 1;
            })
        }
        if (this.total() > 1 && this.qi() < this.total() - 1) {
          Button(t('下一题'))
            .fontSize(14).fontColor('#ffffff')
            .backgroundColor(this.answeredQuestion(this.request.questions[this.qi()]) ? this.tk().accent : this.tk().textDim)
            .borderRadius(8).layoutWeight(1)
            .enabled(this.answeredQuestion(this.request.questions[this.qi()]))
            .onClick(() => {
              this.error = '';
              this.step = this.qi() + 1;
            })
        } else {
          Button(t('提交'))
            .fontSize(14).fontColor('#ffffff')
            .backgroundColor(this.allAnswered() ? this.tk().accent : this.tk().textDim)
            .borderRadius(8).layoutWeight(1)
            .enabled(this.allAnswered())
            .onClick(() => this.submit())
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

function truncate(s: string, n: number): string {
  return s.length > n ? `${s.substring(0, n)}…` : s;
}

// ── fleet-ask image asset ─────────────────────────────────────────────────────

/// One fleet-ask image: fetched base64 over the relay's `decision_asset` method
/// and decoded to a PixelMap (ArkUI Image can't take a data: URI directly).
@Component
struct DecisionImage {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  requestId: string = '';
  qidx: number = 0;
  name: string = '';
  caption: string = '';
  client: RelayClient | null = null;

  @State private pm: image.PixelMap | null = null;
  // 'loading' | 'ok' | 'error'
  @State private status: string = 'loading';

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const client = this.client;
    if (!client) {
      this.status = 'error';
      return;
    }
    this.status = 'loading';
    try {
      const params: AssetParams = { id: this.requestId, qidx: `q${this.qidx}`, rel: this.name };
      // Asset bytes are MB-scale over a phone link; use a generous timeout.
      const a = await client.request<AssetResp>('decision_asset', params, 60000);
      const bytes = new util.Base64Helper().decodeSync(a.base64);
      const src = image.createImageSource(bytes.buffer);
      this.pm = await src.createPixelMap();
      this.status = 'ok';
    } catch (e) {
      this.status = 'error';
    }
  }

  build() {
    Column({ space: 4 }) {
      if (this.status === 'ok' && this.pm) {
        Image(this.pm)
          .width('100%')
          .objectFit(ImageFit.Contain)
          .borderRadius(8)
      } else if (this.status === 'error') {
        Text(t('图片加载失败，点按重试'))
          .fontSize(12)
          .fontColor(this.tk().textDim)
          .width('100%')
          .padding(12)
          .borderRadius(8)
          .backgroundColor(this.tk().bgInput)
          .textAlign(TextAlign.Center)
          .onClick(() => this.load())
      } else {
        Row({ space: 6 }) {
          LoadingProgress().width(16).height(16).color(this.tk().accent)
          Text(t('加载图片…')).fontSize(12).fontColor(this.tk().textDim)
        }
        .width('100%')
        .padding(12)
        .justifyContent(FlexAlign.Center)
      }
      if (this.caption.length > 0) {
        Text(this.caption).fontSize(11).fontColor(this.tk().textSecondary).width('100%')
      }
    }
    .width('100%')
    .margin({ top: 6 })
  }
}
