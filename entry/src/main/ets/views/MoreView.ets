import { t, setLang } from '../common/I18n';
import { ColorTokens, themeTokens, setThemeMode, ThemeMode } from '../common/Theme';

/// The "更多" tab: language + theme switchers (wired end-to-end), a re-pair entry,
/// and an about block. Connection/notification rows fill in once the P2 relay
/// client exists. Mirrors mobile-web's MoreView (minus the live status rows).
@Component
export struct MoreView {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @StorageProp('lang') lang: string = 'zh';
  @StorageProp('themeMode') themeMode: string = 'system';
  onRepair: () => void = () => {};

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
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
