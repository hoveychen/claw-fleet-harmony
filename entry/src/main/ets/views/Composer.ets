import { util } from '@kit.ArkTS';
import { promptAction } from '@kit.ArkUI';
import { t } from '../common/I18n';
import { ColorTokens, themeTokens } from '../common/Theme';
import { RelayClient, RelayRequestError } from '../common/Relay';
import { SessionInfo } from '../models/Types';
import { canResumeSession } from '../models/Types';
import { DirPicker } from './DirPicker';

/// New-session sheet + resume composer — the native port of
/// mobile-web/src/views/Composer.tsx. NewSessionSheet spawns a fresh headless
/// session (`spawn_session`, with a phone-preallocated id so a dropped reply is
/// still recoverable via the next snapshot); ResumeComposer continues an existing
/// Fleet-owned session (`resume_session`, empty prompt = "continue").
///
/// Deferred vs. web (device-only, land in P8 device validation): file attachments
/// (needs the on-device file picker → `upload_attachment`), and localStorage-style
/// draft persistence across sheet close. The essential workspace + prompt +
/// model/effort/permission → spawn flow is fully wired here.
///
/// ArkTS shape notes: relay params are declared interfaces (never Record
/// literals); @Builder bodies hold only UI syntax; Select options are
/// SelectOption[]; private member names avoid CustomComponent-reserved attr names.

const CUSTOM_KEY = '__custom__';

interface Choice {
  value: string;
  label: string;
}

const MODEL_CHOICES: Choice[] = [
  { value: '', label: '默认模型' },
  { value: 'claude-fable-5', label: 'Fable 5' },
  { value: 'claude-opus-4-8', label: 'Opus 4.8' },
  { value: 'claude-sonnet-5', label: 'Sonnet 5' },
  { value: 'claude-sonnet-4-6', label: 'Sonnet 4.6' },
  { value: 'claude-haiku-4-5-20251001', label: 'Haiku 4.5' },
];

const EFFORT_CHOICES: Choice[] = [
  { value: '', label: '默认努力度' },
  { value: 'low', label: 'low' },
  { value: 'medium', label: 'medium' },
  { value: 'high', label: 'high' },
  { value: 'xhigh', label: 'xhigh' },
  { value: 'max', label: 'max' },
];

/// Permission choices; the leading entry's label differs for new vs. resume
/// (默认权限 / 沿用权限), passed in by the caller.
function permissionChoices(defaultLabel: string): Choice[] {
  return [
    { value: '', label: defaultLabel },
    { value: 'acceptEdits', label: '自动接受编辑' },
    { value: 'plan', label: '计划模式' },
    { value: 'bypassPermissions', label: '跳过权限' },
  ];
}

interface SpawnParams {
  workspacePath: string;
  prompt: string;
  sessionId: string;
  model?: string;
  effort?: string;
  permissionMode?: string;
}

interface ResumeParams {
  sessionId: string;
  workspacePath: string;
  prompt?: string;
  model?: string;
  effort?: string;
  permissionMode?: string;
}

interface ChatWorkspaceResp {
  path: string;
}

interface WorkspaceRef {
  path: string;
  name: string;
}

/// Map a Choice[] to ArkUI SelectOption[] (translated labels).
function selectOptions(choices: Choice[]): SelectOption[] {
  return choices.map((c: Choice) => {
    const opt: SelectOption = { value: t(c.label) };
    return opt;
  });
}

function selectedIdx(choices: Choice[], value: string): number {
  for (let i = 0; i < choices.length; i++) {
    if (choices[i].value === value) {
      return i;
    }
  }
  return 0;
}

// ── Shared model/effort/permission select row ────────────────────────────────

@Component
struct OptionSelects {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @StorageProp('lang') lang: string = 'zh';

  @Prop model: string = '';
  @Prop effort: string = '';
  @Prop permissionMode: string = '';
  permissionDefaultLabel: string = '默认权限';
  onModel: (v: string) => void = () => {};
  onEffort: (v: string) => void = () => {};
  onPermission: (v: string) => void = () => {};

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  build() {
    Row({ space: 6 }) {
      Select(selectOptions(MODEL_CHOICES))
        .selected(selectedIdx(MODEL_CHOICES, this.model))
        .value(t(MODEL_CHOICES[selectedIdx(MODEL_CHOICES, this.model)].label))
        .font({ size: 12 })
        .fontColor(this.tk().text)
        .backgroundColor(this.tk().bgInput)
        .borderRadius(8)
        .layoutWeight(1)
        .onSelect((i: number) => this.onModel(MODEL_CHOICES[i].value))
      Select(selectOptions(EFFORT_CHOICES))
        .selected(selectedIdx(EFFORT_CHOICES, this.effort))
        .value(t(EFFORT_CHOICES[selectedIdx(EFFORT_CHOICES, this.effort)].label))
        .font({ size: 12 })
        .fontColor(this.tk().text)
        .backgroundColor(this.tk().bgInput)
        .borderRadius(8)
        .layoutWeight(1)
        .onSelect((i: number) => this.onEffort(EFFORT_CHOICES[i].value))
      Select(selectOptions(permissionChoices(this.permissionDefaultLabel)))
        .selected(selectedIdx(permissionChoices(this.permissionDefaultLabel), this.permissionMode))
        .value(t(permissionChoices(this.permissionDefaultLabel)[
          selectedIdx(permissionChoices(this.permissionDefaultLabel), this.permissionMode)].label))
        .font({ size: 12 })
        .fontColor(this.tk().text)
        .backgroundColor(this.tk().bgInput)
        .borderRadius(8)
        .layoutWeight(1)
        .onSelect((i: number) => this.onPermission(permissionChoices(this.permissionDefaultLabel)[i].value))
    }
    .width('100%')
  }
}

// ── 新会话 sheet ─────────────────────────────────────────────────────────────

@Component
export struct NewSessionSheet {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @StorageProp('lang') lang: string = 'zh';

  @Prop sessions: SessionInfo[] = [];
  client: RelayClient | null = null;
  onClose: () => void = () => {};

  @State private workspaceKey: string = '';
  @State private customWorkspace: string = '';
  @State private prompt: string = '';
  @State private model: string = '';
  @State private effort: string = '';
  @State private permissionMode: string = 'acceptEdits';
  @State private busy: boolean = false;
  @State private picking: boolean = false;
  @State private chatPath: string | null = null;

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  aboutToAppear(): void {
    const client = this.client;
    if (client) {
      client.request<ChatWorkspaceResp>('chat_workspace')
        .then((r: ChatWorkspaceResp) => {
          this.chatPath = r.path;
        })
        .catch((_e: Object) => {
          this.chatPath = null;
        });
    }
  }

  /// Recent workspaces from the sessions snapshot, excluding the pure-chat one
  /// (pinned separately), sorted by name.
  private recents(): WorkspaceRef[] {
    const names = new Map<string, string>();
    for (const s of this.sessions) {
      if (this.chatPath !== null && s.workspacePath === this.chatPath) {
        continue;
      }
      names.set(s.workspacePath, s.workspaceName);
    }
    const refs: WorkspaceRef[] = [];
    names.forEach((name: string, path: string) => refs.push({ path, name }));
    refs.sort((a: WorkspaceRef, b: WorkspaceRef) => a.name.localeCompare(b.name));
    return refs;
  }

  /// The ordered workspace choices: chat (if any), recents, then custom.
  private workspaceChoices(): Choice[] {
    const out: Choice[] = [];
    if (this.chatPath !== null) {
      out.push({ value: this.chatPath, label: t('💬 纯聊天 — 不绑定任何项目目录') });
    }
    for (const r of this.recents()) {
      out.push({ value: r.path, label: `${r.name} — ${r.path}` });
    }
    out.push({ value: CUSTOM_KEY, label: t('自定义路径…') });
    return out;
  }

  /// Effective selected key, falling back to the first real option when the
  /// persisted/last key is no longer valid.
  private effectiveKey(): string {
    const choices = this.workspaceChoices();
    for (const c of choices) {
      if (c.value === this.workspaceKey) {
        return this.workspaceKey;
      }
    }
    // fall back to first non-custom, else custom
    return choices.length > 0 ? choices[0].value : CUSTOM_KEY;
  }

  private effectiveWorkspace(): string {
    const key = this.effectiveKey();
    return key === CUSTOM_KEY ? this.customWorkspace.trim() : key;
  }

  private canSubmit(): boolean {
    return this.client !== null
      && this.effectiveWorkspace().length > 0
      && this.prompt.trim().length > 0
      && !this.busy;
  }

  private wsSelectIdx(): number {
    const choices = this.workspaceChoices();
    const key = this.effectiveKey();
    for (let i = 0; i < choices.length; i++) {
      if (choices[i].value === key) {
        return i;
      }
    }
    return 0;
  }

  private wsSelectLabel(): string {
    const choices = this.workspaceChoices();
    return choices.length > 0 ? choices[this.wsSelectIdx()].label : '';
  }

  private submit(): void {
    const client = this.client;
    if (!client || !this.canSubmit()) {
      return;
    }
    // Phone-preallocated id: the desktop uses it as `claude --session-id`, so
    // even a dropped reply frame is recoverable — the session surfaces in the
    // next snapshot carrying this exact id.
    const sessionId = util.generateRandomUUID(true);
    this.busy = true;
    const params: SpawnParams = {
      workspacePath: this.effectiveWorkspace(),
      prompt: this.prompt.trim(),
      sessionId,
    };
    if (this.model.length > 0) {
      params.model = this.model;
    }
    if (this.effort.length > 0) {
      params.effort = this.effort;
    }
    if (this.permissionMode.length > 0) {
      params.permissionMode = this.permissionMode;
    }
    client.request<Object>('spawn_session', params)
      .then(() => {
        this.busy = false;
        this.onClose();
      })
      .catch((e: Object) => {
        this.busy = false;
        // A desktop rejection (bad path, empty prompt…) is authoritative — the
        // session can't exist. A timeout may still have spawned; say so softly.
        const remote = e instanceof RelayRequestError && (e as RelayRequestError).remote;
        const msg = e instanceof Error ? (e as Error).message : t('创建会话失败');
        promptAction.showToast({
          message: remote ? msg : t('创建会话失败'),
          duration: 2500,
        });
      });
  }

  build() {
    Stack() {
    Column() {
      // Backdrop
      Column()
        .layoutWeight(1)
        .width('100%')
        .onClick(() => this.onClose())

      Column({ space: 10 }) {
        Row() {
          Text(t('新会话'))
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.tk().text)
            .layoutWeight(1)
          Text('✕')
            .fontSize(16)
            .fontColor(this.tk().textDim)
            .onClick(() => this.onClose())
        }
        .width('100%')

        // Workspace select
        Select(this.workspaceChoices().map((c: Choice) => {
          const o: SelectOption = { value: c.label };
          return o;
        }))
          .selected(this.wsSelectIdx())
          .value(this.wsSelectLabel())
          .font({ size: 13 })
          .fontColor(this.tk().text)
          .backgroundColor(this.tk().bgInput)
          .borderRadius(8)
          .width('100%')
          .onSelect((i: number) => {
            this.workspaceKey = this.workspaceChoices()[i].value;
          })

        // Custom path row
        if (this.effectiveKey() === CUSTOM_KEY) {
          Row({ space: 8 }) {
            TextInput({ text: this.customWorkspace, placeholder: t('~/workspace/项目 或点右侧浏览') })
              .layoutWeight(1)
              .fontSize(13)
              .fontColor(this.tk().text)
              .placeholderColor(this.tk().textDim)
              .backgroundColor(this.tk().bgInput)
              .borderRadius(8)
              .onChange((v: string) => {
                this.customWorkspace = v;
              })
            Button(t('浏览…'))
              .fontSize(13)
              .fontColor(this.tk().text)
              .backgroundColor(this.tk().bgInput)
              .enabled(this.client !== null)
              .onClick(() => {
                this.picking = true;
              })
          }
          .width('100%')
        }

        // Prompt
        TextArea({ text: this.prompt, placeholder: t('要让 agent 做什么？') })
          .width('100%')
          .height(120)
          .fontSize(14)
          .fontColor(this.tk().text)
          .placeholderColor(this.tk().textDim)
          .backgroundColor(this.tk().bgInput)
          .borderRadius(8)
          .onChange((v: string) => {
            this.prompt = v;
          })

        OptionSelects({
          model: this.model,
          effort: this.effort,
          permissionMode: this.permissionMode,
          permissionDefaultLabel: '默认权限',
          onModel: (v: string) => {
            this.model = v;
          },
          onEffort: (v: string) => {
            this.effort = v;
          },
          onPermission: (v: string) => {
            this.permissionMode = v;
          },
        })

        Button(this.busy ? t('创建中…') : t('创建会话'))
          .width('100%')
          .fontSize(15)
          .fontColor('#ffffff')
          .backgroundColor(this.tk().accent)
          .enabled(this.canSubmit())
          .onClick(() => this.submit())
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.tk().bgCard)
      .borderRadius({ topLeft: 16, topRight: 16 })
      .border({ width: { top: 1 }, color: this.tk().border })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')

    if (this.picking) {
      DirPicker({
        client: this.client,
        initialPath: this.customWorkspace.trim(),
        onPick: (path: string) => {
          this.customWorkspace = path;
          this.picking = false;
        },
        onClose: () => {
          this.picking = false;
        },
      })
    }
    }
    .width('100%')
    .height('100%')
  }
}

// ── 继续会话 composer (inline, mounted in SessionDetailView) ──────────────────

@Component
export struct ResumeComposer {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @StorageProp('lang') lang: string = 'zh';

  session: SessionInfo = {} as SessionInfo;
  client: RelayClient | null = null;

  @State private prompt: string = '';
  @State private model: string = '';
  @State private effort: string = '';
  @State private permissionMode: string = '';
  @State private busy: boolean = false;
  @State private sent: boolean = false;

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  private submit(): void {
    const client = this.client;
    if (!client || this.busy) {
      return;
    }
    this.busy = true;
    const trimmed = this.prompt.trim();
    const params: ResumeParams = {
      sessionId: this.session.id,
      workspacePath: this.session.workspacePath,
    };
    // Empty prompt = "continue" (the relay side supplies the fallback).
    if (trimmed.length > 0) {
      params.prompt = trimmed;
    }
    if (this.model.length > 0) {
      params.model = this.model;
    }
    if (this.effort.length > 0) {
      params.effort = this.effort;
    }
    if (this.permissionMode.length > 0) {
      params.permissionMode = this.permissionMode;
    }
    client.request<Object>('resume_session', params)
      .then(() => {
        this.busy = false;
        this.prompt = '';
        this.sent = true;
        setTimeout(() => {
          this.sent = false;
        }, 3000);
      })
      .catch((e: Object) => {
        this.busy = false;
        const msg = e instanceof Error ? (e as Error).message : t('恢复会话失败');
        promptAction.showToast({ message: msg, duration: 2500 });
      });
  }

  build() {
    if (canResumeSession(this.session)) {
      Column({ space: 8 }) {
        TextArea({ text: this.prompt, placeholder: t('继续这个会话（留空 = continue）…') })
          .width('100%')
          .height(64)
          .fontSize(14)
          .fontColor(this.tk().text)
          .placeholderColor(this.tk().textDim)
          .backgroundColor(this.tk().bgInput)
          .borderRadius(8)
          .onChange((v: string) => {
            this.prompt = v;
          })
        Row({ space: 8 }) {
          Column() {
            OptionSelects({
              model: this.model,
              effort: this.effort,
              permissionMode: this.permissionMode,
              permissionDefaultLabel: '沿用权限',
              onModel: (v: string) => {
                this.model = v;
              },
              onEffort: (v: string) => {
                this.effort = v;
              },
              onPermission: (v: string) => {
                this.permissionMode = v;
              },
            })
          }
          .layoutWeight(1)
          Button(this.busy ? t('发送中…') : (this.sent ? t('已发送') : t('继续会话')))
            .fontSize(14)
            .fontColor('#ffffff')
            .backgroundColor(this.tk().accent)
            .enabled(!this.busy && this.client !== null)
            .onClick(() => this.submit())
        }
        .width('100%')
      }
      .width('100%')
      .padding(12)
      .backgroundColor(this.tk().bgCard)
      .border({ width: { top: 1 }, color: this.tk().border })
    }
  }
}
