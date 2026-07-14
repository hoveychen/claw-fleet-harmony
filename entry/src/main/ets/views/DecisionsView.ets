import { t } from '../common/I18n';
import { ColorTokens, themeTokens } from '../common/Theme';
import { RelayClient } from '../common/Relay';
import { PendingDecision } from '../models/Types';
import { EmptyState } from './EmptyState';

/// Every DecisionRequest variant carries these display fields; used to render a
/// scaffold row without discriminating the union.
interface DecisionMeta {
  workspaceName: string;
  aiTitle?: string | null;
}

/// Human label per decision kind (matches the desktop / mobile-web copy).
function kindLabel(kind: string): string {
  if (kind === 'guard') {
    return t('命令确认');
  }
  if (kind === 'elicitation') {
    return t('提问');
  }
  if (kind === 'fleet-ask') {
    return t('决策卡');
  }
  if (kind === 'plan-approval') {
    return t('计划审批');
  }
  if (kind === 'permission-prompt') {
    return t('权限请求');
  }
  if (kind === 'a2ui-render') {
    return t('富交互卡');
  }
  return kind;
}

/// The 决策 tab. MainShell feeds it the live pending-decision list (fed by the
/// relay's decision_created / decision_resolved events + pending_snapshot), the
/// relay client for answer round-tripping, and an onAnswered callback.
///
/// P4-groundwork: the plumbing + prop contract are in place and the pending list
/// renders a summary row per card, proving the MainShell → view data flow. The
/// six real card bodies (guard command view / elicitation / fleet-ask forms +
/// html + images / plan-approval / permission-prompt / a2ui) and answer UIs are
/// the remaining P4 view work — port from mobile-web/src/views/DecisionsView.tsx.
@Component
export struct DecisionsView {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @StorageProp('lang') lang: string = 'zh';

  @Prop decisions: PendingDecision[] = [];
  client: RelayClient | null = null;
  onAnswered: (id: string) => void = () => {};

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  private meta(d: PendingDecision): DecisionMeta {
    return d.request as DecisionMeta;
  }

  @Builder
  row(d: PendingDecision) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(kindLabel(d.kind))
          .fontSize(12)
          .fontColor(this.tk().accent)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor(this.tk().accentSoft)
        Text(this.meta(d).workspaceName)
          .fontSize(12)
          .fontColor(this.tk().textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      Text(t('此卡完整渲染与作答将在 P4 视图层补全'))
        .fontSize(11)
        .fontColor(this.tk().textDim)
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor(this.tk().bgCard)
    .border({ width: 1, color: this.tk().border })
  }

  build() {
    Column() {
      if (this.decisions.length === 0) {
        EmptyState({
          icon: '📥',
          title: t('没有待处理的决策'),
          subtitle: t('暂时收不到新决策，等桌面端重新上线就会同步过来。'),
        })
      } else {
        List({ space: 8 }) {
          ForEach(this.decisions, (d: PendingDecision) => {
            ListItem() {
              this.row(d)
            }
          }, (d: PendingDecision) => d.id)
        }
        .width('100%')
        .height('100%')
        .padding(12)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.tk().bg)
  }
}
