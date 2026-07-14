import { t } from '../common/I18n';
import { EmptyState } from './EmptyState';

/// P1 placeholder for the decisions tab. The live pending-decision list, the six
/// card kinds and answer round-tripping land in P2 (relay) + P4 (cards).
@Component
export struct DecisionsView {
  @StorageProp('lang') lang: string = 'zh';

  build() {
    Column() {
      EmptyState({
        icon: '📥',
        title: t('没有待处理的决策'),
        subtitle: t('暂时收不到新决策，等桌面端重新上线就会同步过来。'),
      })
    }
    .width('100%')
    .height('100%')
  }
}
