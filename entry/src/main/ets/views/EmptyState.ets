import { ColorTokens, themeTokens } from '../common/Theme';

/// Centered icon + title + subtitle, the shared empty/placeholder state. Mirrors
/// mobile-web's <EmptyState>. Subscribes to the resolved theme for its colors.
///
///   - `spin`: swap the emoji icon for an animated LoadingProgress spinner (the
///     "connecting…" / "loading tasks…" states).
///   - `compact`: tighter vertical padding + smaller type, for an inline
///     "no matches" state that sits inside a list rather than filling the page.
@Component
export struct EmptyState {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @Prop icon: string = '';
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop spin: boolean = false;
  @Prop compact: boolean = false;

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  private pad(): Padding {
    if (this.compact) {
      return { top: 32, bottom: 32, left: 24, right: 24 };
    }
    return { left: 32, right: 32 };
  }

  build() {
    Column({ space: this.compact ? 8 : 12 }) {
      if (this.spin) {
        LoadingProgress()
          .width(this.compact ? 30 : 40)
          .height(this.compact ? 30 : 40)
          .color(this.tk().accent)
      } else if (this.icon.length > 0) {
        Text(this.icon).fontSize(this.compact ? 34 : 46)
      }
      Text(this.title)
        .fontSize(this.compact ? 15 : 17)
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
    .height(this.compact ? 'auto' : '100%')
    .padding(this.pad())
    .justifyContent(FlexAlign.Center)
  }
}
