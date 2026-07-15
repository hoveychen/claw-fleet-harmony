/// Renders the fleet__ask `html` preview field with the ArkWeb `Web` component.
/// Despite the long-standing "atomic services can't use Web" lore, an on-device
/// spike (HarmonyOS 6.1.1, real device) proved the ArkWeb runtime loads and
/// paints inside this atomic service with no restriction — so we render the
/// agent-provided HTML for real instead of degrading to a "view on desktop" note.
///
/// Contract match with mobile-web: the desktop shows this html in an
/// `<iframe sandbox="">` (no scripts, no same-origin). We mirror that by loading
/// JavaScript-disabled, with our own theme-coloured wrapper stylesheet injected
/// so tables / code / quotes read consistently in light and dark. The Web sizes
/// to its content via `WebLayoutMode.FIT_CONTENT` (ArkWeb's auto-height mode) so
/// it never traps card scroll gestures behind an inner scroller — a manual
/// getPageHeight() + fixed initial height deadlocks (a 1px-tall Web never paints,
/// so onPageEnd never fires to grow it), which an on-device spike confirmed.

import webview from '@ohos.web.webview';
import { ColorTokens, themeTokens } from './Theme';

@Component
export struct HtmlView {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @Prop html: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  /// Wrap the raw html in a full document with a viewport tag and a theme-aware
  /// stylesheet. Only solid 6-digit theme tokens are used in CSS — the 8-digit
  /// `border`/`borderStrong` tokens are ArkUI #AARRGGBB, which CSS would read as
  /// #RRGGBBAA and mis-colour, so borders use the solid `textDim` instead.
  private wrap(): string {
    const tk = this.tk();
    const style = `<style>`
      + `html,body{margin:0;padding:0;background:transparent;color:${tk.text};`
      + `font-family:-apple-system,system-ui,sans-serif;font-size:14px;line-height:1.5;`
      + `word-break:break-word;overflow-wrap:break-word;}`
      + `table{border-collapse:collapse;width:100%;margin:4px 0;}`
      + `th,td{border:1px solid ${tk.textDim};padding:4px 8px;text-align:left;}`
      + `th{background:${tk.bgInput};}`
      + `a{color:${tk.accent};}`
      + `img{max-width:100%;height:auto;}`
      + `pre{background:${tk.bgInput};border-radius:4px;padding:8px;overflow-x:auto;}`
      + `code{background:${tk.bgInput};border-radius:4px;padding:1px 4px;}`
      + `pre code{background:transparent;padding:0;}`
      + `blockquote{border-left:3px solid ${tk.accent};margin:6px 0;padding-left:10px;color:${tk.textSecondary};}`
      + `h1,h2,h3{margin:6px 0;}`
      + `</style>`;
    const meta = `<meta name="viewport" content="width=device-width,initial-scale=1">`;
    return `<!DOCTYPE html><html><head>${meta}${style}</head><body>${this.html}</body></html>`;
  }

  private dataUrl(): string {
    return 'data:text/html,' + encodeURIComponent(this.wrap());
  }

  build() {
    Web({ src: this.dataUrl(), controller: this.controller })
      .javaScriptAccess(false)
      .domStorageAccess(false)
      .onlineImageAccess(false)
      .backgroundColor(Color.Transparent)
      .overScrollMode(OverScrollMode.NEVER)
      .layoutMode(WebLayoutMode.FIT_CONTENT)
      .width('100%')
  }
}
