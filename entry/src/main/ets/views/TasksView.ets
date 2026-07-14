import { t } from '../common/I18n';
import { EmptyState } from './EmptyState';

/// P1 placeholder for the tasks tab. The live sessions snapshot + realtime
/// updates land in P3 (after the P2 relay client).
@Component
export struct TasksView {
  @StorageProp('lang') lang: string = 'zh';

  build() {
    Column() {
      EmptyState({
        icon: '📋',
        title: t('还没有会话'),
        subtitle: t('等待桌面端推送快照。桌面端各会话上线后会出现在这里。'),
      })
    }
    .width('100%')
    .height('100%')
  }
}
