import { t } from '../common/I18n';
import { EmptyState } from './EmptyState';

/// P1 placeholder for the wiki tab. Doc list / search / full-fidelity rendering
/// land in P6.
@Component
export struct WikiView {
  @StorageProp('lang') lang: string = 'zh';

  build() {
    Column() {
      EmptyState({
        icon: '📚',
        title: t('还没有归档的文档'),
        subtitle: t('桌面端 agent 用 fleet wiki publish 发布后，文档会出现在这里。'),
      })
    }
    .width('100%')
    .height('100%')
  }
}
