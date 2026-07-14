import { buffer } from '@kit.ArkTS';
import { t, dateLocale } from '../common/I18n';
import { ColorTokens, themeTokens } from '../common/Theme';
import { RelayClient } from '../common/Relay';
import { MarkdownView } from '../common/Markdown';
import { WikiDoc, WikiVersion, WikiFilePayload } from '../models/Types';

/// 全屏 wiki 阅读页 — the native port of mobile-web/src/views/WikiDocView.tsx.
/// Markdown docs render inline via the native MarkdownView. HTML / htmlDir docs
/// need a full ArkWeb browser surface, which the atomic-service (元服务) sandbox
/// restricts (see Markdown.ets) — they show a "view on desktop" notice instead.
/// A version selector switches between published versions.
///
/// Deferred vs. web (P8 device validation): full-fidelity HTML rendering (needs
/// ArkWeb availability verified in 元服务 + the data-URI asset-inlining port),
/// export / share (needs the on-device file + share kits), and `[[slug]]` tap
/// navigation (MarkdownView has no link callback).
///
/// ArkTS shape notes: relay params are declared interfaces; base64 → utf8 decode
/// goes through `buffer`.

interface FileParams {
  slug: string;
  version: string;
  relpath: string;
}

/// `[[slug]]` / `[[slug|label]]` → the display text (MarkdownView can't navigate,
/// so we drop the link and keep the label rather than leaving raw brackets).
function expandWikiMentions(md: string): string {
  return md.replace(/\[\[([^\]|]+?)(?:\|([^\]]+?))?\]\]/g, (_m: string, slug: string, label: string) => {
    const s = (slug ?? '').trim();
    const text = (label !== undefined && label.length > 0 ? label : s).trim();
    return text;
  });
}

function fmtVersion(ms: number): string {
  return new Date(ms).toLocaleString(dateLocale(), {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}

@Component
export struct WikiDocView {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @StorageProp('lang') lang: string = 'zh';

  doc: WikiDoc = {} as WikiDoc;
  client: RelayClient | null = null;
  onBack: () => void = () => {};

  @State private version: string = '';
  @State private markdown: string | null = null;
  @State private error: string = '';

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  aboutToAppear(): void {
    this.version = this.doc.currentVersion;
    if (this.doc.kind === 'markdown') {
      this.loadMarkdown();
    }
  }

  private loadMarkdown(): void {
    const client = this.client;
    if (!client) {
      return;
    }
    this.markdown = null;
    this.error = '';
    const params: FileParams = { slug: this.doc.slug, version: this.version, relpath: this.doc.entry };
    client.request<WikiFilePayload>('wiki_file', params)
      .then((f: WikiFilePayload) => {
        this.markdown = buffer.from(f.base64, 'base64').toString('utf-8');
      })
      .catch((e: Object) => {
        this.error = e instanceof Error ? (e as Error).message : `${e}`;
      });
  }

  @Builder
  header() {
    Row({ space: 8 }) {
      Row({ space: 2 }) {
        Text('‹').fontSize(22).fontColor(this.tk().accent)
        Text(t('返回')).fontSize(15).fontColor(this.tk().accent)
      }
      .onClick(() => this.onBack())
      Column() {
        Text(this.doc.title.length > 0 ? this.doc.title : this.doc.slug)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.tk().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${this.doc.slug} · ${this.doc.workspaceName}`)
          .fontSize(11)
          .fontColor(this.tk().textDim)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.doc.versions !== undefined && this.doc.versions.length > 1) {
        Select(this.versionOptions())
          .selected(this.versionIdx())
          .value(this.versionLabel())
          .font({ size: 12 })
          .fontColor(this.tk().text)
          .backgroundColor(this.tk().bgInput)
          .borderRadius(6)
          .onSelect((i: number) => {
            this.version = this.doc.versions[i].id;
            if (this.doc.kind === 'markdown') {
              this.loadMarkdown();
            }
          })
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.tk().bgGlass)
    .border({ width: { bottom: 1 }, color: this.tk().border })
  }

  private versionOptions(): SelectOption[] {
    const vers = this.doc.versions ?? [];
    return vers.map((v: WikiVersion, i: number) => {
      const o: SelectOption = { value: i === 0 ? t('最新') : fmtVersion(v.publishedMs) };
      return o;
    });
  }

  private versionIdx(): number {
    const vers = this.doc.versions ?? [];
    for (let i = 0; i < vers.length; i++) {
      if (vers[i].id === this.version) {
        return i;
      }
    }
    return 0;
  }

  private versionLabel(): string {
    const vers = this.doc.versions ?? [];
    const idx = this.versionIdx();
    if (vers.length === 0) {
      return '';
    }
    return idx === 0 ? t('最新') : fmtVersion(vers[idx].publishedMs);
  }

  build() {
    Column() {
      this.header()
      Scroll() {
        Column() {
          if (this.doc.kind === 'markdown') {
            if (this.error.length > 0) {
              Text(t('加载失败：{0}', this.error)).fontSize(13).fontColor(this.tk().error).width('100%')
            } else if (this.markdown === null) {
              Text(t('加载中…')).fontSize(13).fontColor(this.tk().textDim).width('100%').margin({ top: 20 })
            } else {
              MarkdownView({ content: expandWikiMentions(this.markdown), mdFontSize: 15 })
            }
          } else {
            // HTML / htmlDir: full-fidelity render needs an ArkWeb surface the
            // 元服务 sandbox restricts. Point the user to the desktop.
            Column({ space: 10 }) {
              Text('🖥️').fontSize(40)
              Text(t('这是一个 HTML 页面'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.tk().text)
              Text(t('元服务暂不支持内联渲染 HTML 文档，请在桌面端 Fleet 的知识库中查看。'))
                .fontSize(13)
                .fontColor(this.tk().textSecondary)
                .textAlign(TextAlign.Center)
                .lineHeight(20)
            }
            .width('100%')
            .padding({ top: 60, left: 32, right: 32 })
            .justifyContent(FlexAlign.Center)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 12, bottom: 32 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.tk().bg)
  }
}
