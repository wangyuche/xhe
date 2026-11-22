import { Container, Graphics, Text, type FederatedPointerEvent } from 'pixi.js';
import { syncA11y } from './a11y';

export interface ButtonOptions {
  /** 看得到的文字與 a11y 名稱,來自 i18n(PX-I18N-01) */
  label: string;
  width: number;
  height: number;
  color?: number;
  onActivate: () => void;
}

/**
 * 共用按鈕(PX-INPUT-01):滑鼠、觸控、鍵盤 Tab + Enter 都能觸發。
 * a11y(Tab + Enter、讀屏)送來的事件沒有 button 欄位,所以只擋 `button > 0`(右鍵 / 中鍵),不要寫 `button !== 0`。
 * 原點在中心;觸控目標在最小縮放下要 ≥ 44 CSS px(由版面保證,E2E 檢查)。
 */
export class Button extends Container {
  private readonly bg = new Graphics();
  private disabled = false;

  constructor(private readonly opts: ButtonOptions) {
    super();
    this.eventMode = 'static';
    this.cursor = 'pointer';
    this.accessible = true;
    this.accessibleType = 'button';
    this.accessibleTitle = opts.label;
    const label = new Text({ text: opts.label, style: { fill: 0xffffff, fontSize: Math.round(opts.height * 0.4), fontWeight: '700', fontFamily: 'system-ui, sans-serif' } });
    label.anchor.set(0.5);
    // 文字放不下就等比縮小(不同語言長度不同;最多佔按鈕寬 85%)
    const maxW = opts.width * 0.85;
    if (label.width > maxW) label.scale.set(maxW / label.width);
    this.draw();
    this.addChild(this.bg, label);
    this.on('pointertap', (e: FederatedPointerEvent) => {
      if (this.disabled || e.button > 0) return;
      opts.onActivate();
    });
  }

  setDisabled(d: boolean): void {
    this.disabled = d;
    this.alpha = d ? 0.5 : 1;
    this.eventMode = d ? 'none' : 'static';
  }

  update(): void {
    syncA11y(this);
  }

  private draw(): void {
    const { width: w, height: h, color = 0x2f7df6 } = this.opts;
    this.bg.clear().roundRect(-w / 2, -h / 2, w, h, Math.round(h * 0.25)).fill(color);
  }
}
