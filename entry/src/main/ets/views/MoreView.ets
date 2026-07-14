import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { t, setLang } from '../common/I18n';
import { ColorTokens, themeTokens, setThemeMode, ThemeMode } from '../common/Theme';
import { registerForPush } from '../common/PushRegister';
import { Icon } from '../common/Icon';

/// The "更多" tab: language + theme switchers (wired end-to-end), a re-pair entry,
/// and an about block. Connection/notification rows fill in once the P2 relay
/// client exists. Mirrors mobile-web's MoreView (minus the live status rows).
@Component
export struct MoreView {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @StorageProp('lang') lang: string = 'zh';
  @StorageProp('themeMode') themeMode: string = 'system';
  @Prop connected: boolean = false;
  @Prop agentOnline: boolean = false;
  @StorageProp('pushSubscribed') pushSubscribed: boolean = false;
  @State private enablingPush: boolean = false;
  onRepair: () => void = () => {};
  onOpenUsage: () => void = () => {};
  onOpenRepo: () => void = () => {};

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private enablePush(): void {
    if (this.enablingPush) {
      return;
    }
    this.enablingPush = true;
    registerForPush(this.ctx())
      .then((state: string) => {
        AppStorage.setOrCreate('pushSubscribed', state === 'subscribed');
        if (state !== 'subscribed') {
          promptAction.showToast({ message: t('尚未配对。请先扫码配对。') });
        }
      })
      .catch((e: Object) => {
        const msg = e instanceof Error ? (e as Error).message : `${e}`;
        promptAction.showToast({ message: t('订阅失败：{0}', msg) });
      })
      .finally(() => {
        this.enablingPush = false;
      });
  }

  private connLabel(): string {
    if (!this.connected) {
      return t('连接中…');
    }
    return this.agentOnline ? t('桌面端在线') : t('桌面端离线');
  }

  private connColor(): string {
    if (!this.connected) {
      return this.tk().textDim;
    }
    return this.agentOnline ? this.tk().success : this.tk().warning;
  }

  @Builder
  navRow(icon: Resource, label: string, sub: string, onTap: () => void) {
    Row({ space: 12 }) {
      Icon({ src: icon, iconSize: 18, color: this.tk().textSecondary })
      Column({ space: 2 }) {
        Text(label).fontSize(15).fontColor(this.tk().text)
        Text(sub).fontSize(12).fontColor(this.tk().textDim).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›').fontSize(20).fontColor(this.tk().textDim)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.tk().bgCard)
    .borderRadius(10)
    .onClick(onTap)
  }

  @Builder
  segButton(label: string, active: boolean, onTap: () => void) {
    Text(label)
      .fontSize(14)
      .fontColor(active ? '#ffffff' : this.tk().text)
      .backgroundColor(active ? this.tk().accent : this.tk().bgInput)
      .padding({ top: 9, bottom: 9, left: 16, right: 16 })
      .borderRadius(8)
      .onClick(onTap)
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(this.tk().textDim)
      .width('100%')
      .margin({ top: 22, bottom: 8 })
  }

  build() {
    Scroll() {
      Column() {
        Text(t('更多'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.tk().text)
          .width('100%')

        this.sectionTitle(t('工具'))
        Column({ space: 8 }) {
          this.navRow($r('app.media.ic_folder_git_2'), t('仓库'), t('查看未合并 worktree 与未推提交'), () => this.onOpenRepo())
          this.navRow($r('app.media.ic_gauge'), t('账号与用量'), t('今日花费、账号档案与限流占用'), () => this.onOpenUsage())
        }
        .width('100%')

        this.sectionTitle(t('连接与通知'))
        Column() {
          Row() {
            Text(t('桌面端')).fontSize(15).fontColor(this.tk().text).layoutWeight(1)
            Row({ space: 6 }) {
              Circle({ width: 8, height: 8 }).fill(this.connColor())
              Text(this.connLabel()).fontSize(13).fontColor(this.tk().textSecondary)
            }
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })
          Divider().color(this.tk().border).margin({ top: 10, bottom: 10 })
          Row() {
            Text(t('通知')).fontSize(15).fontColor(this.tk().text).layoutWeight(1)
            if (this.pushSubscribed) {
              Text(t('已开启')).fontSize(13).fontColor(this.tk().success)
            } else {
              Text(this.enablingPush ? t('订阅中…') : t('开启'))
                .fontSize(13)
                .fontColor('#ffffff')
                .backgroundColor(this.tk().accent)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(6)
                .onClick(() => this.enablePush())
            }
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })
        }
        .width('100%')
        .padding(14)
        .backgroundColor(this.tk().bgCard)
        .borderRadius(10)

        this.sectionTitle(t('语言'))
        Row({ space: 8 }) {
          this.segButton('中文', this.lang !== 'en', () => setLang('zh'))
          this.segButton('English', this.lang === 'en', () => setLang('en'))
        }
        .width('100%')

        this.sectionTitle(t('主题'))
        Row({ space: 8 }) {
          this.segButton(t('跟随系统'), this.themeMode === 'system', () => setThemeMode('system' as ThemeMode))
          this.segButton(t('亮色'), this.themeMode === 'light', () => setThemeMode('light' as ThemeMode))
          this.segButton(t('暗色'), this.themeMode === 'dark', () => setThemeMode('dark' as ThemeMode))
        }
        .width('100%')

        this.sectionTitle(t('配对'))
        Row() {
          Text(t('重新配对 / 清除密钥'))
            .fontSize(15)
            .fontColor(this.tk().text)
            .layoutWeight(1)
          Text('›').fontSize(20).fontColor(this.tk().textDim)
        }
        .width('100%')
        .padding(14)
        .backgroundColor(this.tk().bgCard)
        .borderRadius(10)
        .onClick(() => this.onRepair())

        this.sectionTitle(t('关于'))
        Column({ space: 4 }) {
          Text('Claw Fleet').fontSize(15).fontColor(this.tk().text)
          Text('HarmonyOS 元服务 · v0.1').fontSize(12).fontColor(this.tk().textDim)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(14)
        .backgroundColor(this.tk().bgCard)
        .borderRadius(10)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 16, bottom: 28 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor(this.tk().bg)
  }
}
