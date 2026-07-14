/// Lightweight markdown → ArkUI renderer — the native stand-in for mobile-web's
/// react-markdown. ArkTS has no markdown engine and the atomic-service ArkWeb
/// `Web` component is restricted, so we hand-parse a practical subset and render
/// it with native Text/Span/Column. Supported: headings (#/##/###), paragraphs,
/// fenced code blocks (```), unordered (- / *) and ordered (1.) lists, and the
/// inline runs **bold**, *italic* / _italic_, `code`, and [text](url) (shown as
/// accent-coloured text — link navigation is out of scope on mobile).
///
/// ArkTS shape notes: all parsing lives in plain module functions (a @Builder
/// body may hold only UI syntax — no `const`/loops); the renderer @Builder walks
/// the parsed block list with ForEach and inlines Spans exactly like TasksView's
/// splitSnippet pattern.

import { ColorTokens, themeTokens } from './Theme';

export interface MdSpan {
  text: string;
  bold: boolean;
  italic: boolean;
  code: boolean;
  link: boolean;
}

export type MdBlockKind = 'p' | 'h1' | 'h2' | 'h3' | 'code' | 'li-ul' | 'li-ol';

export interface MdBlock {
  kind: MdBlockKind;
  spans: MdSpan[];
  code: string;
  ordinal: number;
}

function mkSpan(text: string, bold: boolean, italic: boolean, code: boolean, link: boolean): MdSpan {
  const s: MdSpan = { text, bold, italic, code, link };
  return s;
}

function plainSpan(text: string): MdSpan {
  return mkSpan(text, false, false, false, false);
}

/// Leading `N. ` ordered-list marker → index of the item text (after the marker),
/// or -1 when the line isn't an ordered-list item.
function orderedMarker(line: string): number {
  let i = 0;
  while (i < line.length && line.charAt(i) >= '0' && line.charAt(i) <= '9') {
    i++;
  }
  if (i === 0) {
    return -1;
  }
  if (i + 1 < line.length && line.charAt(i) === '.' && line.charAt(i + 1) === ' ') {
    return i + 2;
  }
  return -1;
}

function isBlockStart(trimmed: string): boolean {
  return trimmed.length === 0
    || trimmed.startsWith('```')
    || trimmed.startsWith('#')
    || trimmed.startsWith('- ')
    || trimmed.startsWith('* ')
    || orderedMarker(trimmed) >= 0;
}

/// Inline scanner: split a line into styled runs. Non-nested (a bold run's
/// interior isn't re-scanned), which covers the shapes these cards actually use.
export function parseInline(text: string): MdSpan[] {
  const spans: MdSpan[] = [];
  let plain = '';
  let i = 0;
  const n = text.length;
  while (i < n) {
    const c = text.charAt(i);
    const two = i + 1 < n ? text.substring(i, i + 2) : '';
    if (two === '**') {
      const close = text.indexOf('**', i + 2);
      if (close > i + 1) {
        if (plain.length > 0) {
          spans.push(plainSpan(plain));
          plain = '';
        }
        spans.push(mkSpan(text.substring(i + 2, close), true, false, false, false));
        i = close + 2;
        continue;
      }
    } else if (c === '`') {
      const close = text.indexOf('`', i + 1);
      if (close > i) {
        if (plain.length > 0) {
          spans.push(plainSpan(plain));
          plain = '';
        }
        spans.push(mkSpan(text.substring(i + 1, close), false, false, true, false));
        i = close + 1;
        continue;
      }
    } else if (c === '[') {
      const rb = text.indexOf('](', i + 1);
      if (rb > i) {
        const rp = text.indexOf(')', rb + 2);
        if (rp > rb) {
          if (plain.length > 0) {
            spans.push(plainSpan(plain));
            plain = '';
          }
          spans.push(mkSpan(text.substring(i + 1, rb), false, false, false, true));
          i = rp + 1;
          continue;
        }
      }
    } else if (c === '*' || c === '_') {
      const close = text.indexOf(c, i + 1);
      if (close > i + 1) {
        if (plain.length > 0) {
          spans.push(plainSpan(plain));
          plain = '';
        }
        spans.push(mkSpan(text.substring(i + 1, close), false, true, false, false));
        i = close + 1;
        continue;
      }
    }
    plain += c;
    i++;
  }
  if (plain.length > 0) {
    spans.push(plainSpan(plain));
  }
  if (spans.length === 0) {
    spans.push(plainSpan(''));
  }
  return spans;
}

export function parseBlocks(md: string): MdBlock[] {
  const out: MdBlock[] = [];
  const lines = md.split('\r\n').join('\n').split('\n');
  let i = 0;
  let olCounter = 0;
  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();

    if (trimmed.startsWith('```')) {
      const buf: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        buf.push(lines[i]);
        i++;
      }
      if (i < lines.length) {
        i++;
      }
      out.push({ kind: 'code', spans: [], code: buf.join('\n'), ordinal: 0 });
      olCounter = 0;
      continue;
    }
    if (trimmed.length === 0) {
      i++;
      olCounter = 0;
      continue;
    }
    if (trimmed.startsWith('### ')) {
      out.push({ kind: 'h3', spans: parseInline(trimmed.substring(4)), code: '', ordinal: 0 });
      i++;
      olCounter = 0;
      continue;
    }
    if (trimmed.startsWith('## ')) {
      out.push({ kind: 'h2', spans: parseInline(trimmed.substring(3)), code: '', ordinal: 0 });
      i++;
      olCounter = 0;
      continue;
    }
    if (trimmed.startsWith('# ')) {
      out.push({ kind: 'h1', spans: parseInline(trimmed.substring(2)), code: '', ordinal: 0 });
      i++;
      olCounter = 0;
      continue;
    }
    if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
      out.push({ kind: 'li-ul', spans: parseInline(trimmed.substring(2)), code: '', ordinal: 0 });
      i++;
      olCounter = 0;
      continue;
    }
    const om = orderedMarker(trimmed);
    if (om >= 0) {
      olCounter++;
      out.push({ kind: 'li-ol', spans: parseInline(trimmed.substring(om)), code: '', ordinal: olCounter });
      i++;
      continue;
    }
    olCounter = 0;
    // paragraph: fold consecutive plain lines into one soft-wrapped block
    const buf: string[] = [line];
    i++;
    while (i < lines.length && !isBlockStart(lines[i].trim())) {
      buf.push(lines[i]);
      i++;
    }
    out.push({ kind: 'p', spans: parseInline(buf.join(' ')), code: '', ordinal: 0 });
  }
  return out;
}

/// Renders parsed markdown. `color` overrides the base text colour (defaults to
/// the theme's secondary text); code blocks and inline code always use accent /
/// primary tones so they read as code regardless of the base colour.
@Component
export struct MarkdownView {
  @StorageProp('resolvedTheme') resolvedTheme: string = 'dark';
  @Prop content: string = '';
  @Prop mdFontSize: number = 14;
  @Prop color: string = '';

  private tk(): ColorTokens {
    return themeTokens(this.resolvedTheme);
  }

  private baseColor(): string {
    return this.color.length > 0 ? this.color : this.tk().textSecondary;
  }

  private headingSize(kind: MdBlockKind): number {
    if (kind === 'h1') {
      return this.mdFontSize + 5;
    }
    if (kind === 'h2') {
      return this.mdFontSize + 3;
    }
    return this.mdFontSize + 1;
  }

  private spanColor(s: MdSpan): string {
    return s.link || s.code ? this.tk().accent : this.baseColor();
  }

  @Builder
  blockView(b: MdBlock) {
    if (b.kind === 'code') {
      Text(b.code)
        .fontSize(this.mdFontSize - 1)
        .fontColor(this.tk().text)
        .fontFamily('monospace')
        .width('100%')
        .padding(8)
        .borderRadius(6)
        .backgroundColor(this.tk().bgInput)
    } else if (b.kind === 'h1' || b.kind === 'h2' || b.kind === 'h3') {
      Text() {
        ForEach(b.spans, (s: MdSpan) => {
          Span(s.text)
            .fontStyle(s.italic ? FontStyle.Italic : FontStyle.Normal)
        })
      }
      .fontSize(this.headingSize(b.kind))
      .fontWeight(FontWeight.Bold)
      .fontColor(this.tk().text)
      .width('100%')
    } else if (b.kind === 'li-ul' || b.kind === 'li-ol') {
      Row({ space: 6 }) {
        Text(b.kind === 'li-ol' ? `${b.ordinal}.` : '•')
          .fontSize(this.mdFontSize)
          .fontColor(this.baseColor())
        Text() {
          ForEach(b.spans, (s: MdSpan) => {
            Span(s.text)
              .fontWeight(s.bold ? FontWeight.Bold : FontWeight.Normal)
              .fontStyle(s.italic ? FontStyle.Italic : FontStyle.Normal)
              .fontColor(this.spanColor(s))
          })
        }
        .fontSize(this.mdFontSize)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    } else {
      Text() {
        ForEach(b.spans, (s: MdSpan) => {
          Span(s.text)
            .fontWeight(s.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(s.italic ? FontStyle.Italic : FontStyle.Normal)
            .fontColor(this.spanColor(s))
        })
      }
      .fontSize(this.mdFontSize)
      .lineHeight(this.mdFontSize + 7)
      .width('100%')
    }
  }

  build() {
    Column({ space: 6 }) {
      ForEach(parseBlocks(this.content), (b: MdBlock) => {
        this.blockView(b)
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
