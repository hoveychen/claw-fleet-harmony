import { ColorTokens, themeTokens } from '../common/Theme';

/// Centered icon + title + subtitle, the shared empty/placeholder state. Mirrors
/// mobile-web's <EmptyState>. Subscribes to the resolved theme for its colors.
@Component
export struct EmptyState {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @Prop icon: string = '';
  @Prop title: string = '';
  @Prop subtitle: string = '';

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  build() {
    Column({ space: 12 }) {
      if (this.icon.length > 0) {
        Text(this.icon).fontSize(46)
      }
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.tk().text)
        .textAlign(TextAlign.Center)
      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .fontSize(14)
          .fontColor(this.tk().textSecondary)
          .textAlign(TextAlign.Center)
          .lineHeight(21)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 32, right: 32 })
    .justifyContent(FlexAlign.Center)
  }
}
