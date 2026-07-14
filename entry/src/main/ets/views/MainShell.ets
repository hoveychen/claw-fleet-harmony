import { ColorTokens, themeTokens } from '../common/Theme';
import { t } from '../common/I18n';
import { DecisionsView } from './DecisionsView';
import { TasksView } from './TasksView';
import { WikiView } from './WikiView';
import { MoreView } from './MoreView';

/// The paired-state app shell: a top header, the active tab body, and a bottom
/// bar of 4 tabs split around a center "新会话" FAB. Mirrors mobile-web's App
/// shell (App.tsx). Full-screen overlays (session detail, wiki doc, repo, usage)
/// arrive with their respective P-tasks; for now each tab body is its own view.
@Component
export struct MainShell {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @StorageProp('lang') lang: string = 'zh';
  @State tab: string = 'decisions';
  onRepair: () => void = () => {};
  onNewSession: () => void = () => {};

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
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
        Circle({ width: 8, height: 8 }).fill(this.tk().textDim)
        Text(t('连接中…')).fontSize(12).fontColor(this.tk().textSecondary)
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
          TasksView()
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
