import { BitmapText, Container, Graphics } from 'pixi.js';
import { Button } from '../../components/Button';
import { focusA11y, setA11yAttr, syncA11y } from '../../components/a11y';
import { announceStatus } from '../../core/announce';
import type { Fit } from '../../core/layout';
import type { Scene, SceneContext } from '../../core/scene-manager';
import { DESIGN } from '../../config/design';
import { mulberry32 } from '../../game/rng';
import { hit, newRound, type Round } from '../../game/round';
import { t } from '../../i18n';
import { prefersReducedMotion } from '../../services/motion';

const GOAL = 3;
const TARGET_R = 90;

class PlayScene implements Scene {
  readonly root = new Container();
  private readonly world = new Container();
  private readonly target = new Container();
  private readonly score: BitmapText;
  private readonly back: Button;
  private readonly rng = mulberry32(Number(new URLSearchParams(location.search).get('seed')) || 1);
  private round: Round = newRound(GOAL, this.rng);
  private pulse = 0;
  private readonly reduced = prefersReducedMotion();
  private readonly dialog = document.getElementById('result-dialog') as HTMLDialogElement;
  private readonly tick = (): void => this.update();
  private readonly onCancel = (e: Event): void => {
    e.preventDefault(); // Esc:回標題(PX-A11Y-04,cancel 事件)
    this.dialog.close();
    void this.ctx.go('title');
  };

  constructor(private readonly ctx: SceneContext) {
    // 範例沒有美術素材:用 Graphics 畫(正式專案改用 assets 的 texture(id),缺的列進 assets.needs.json)
    const disc = new Graphics().circle(0, 0, TARGET_R).fill(0xf6b22f).circle(0, 0, TARGET_R * 0.55).fill(0xe0442f);
    this.target.addChild(disc);
    this.target.eventMode = 'static';
    this.target.cursor = 'pointer';
    this.target.accessible = true;
    this.target.accessibleType = 'button';
    this.target.accessibleTitle = t('play.target');
    this.target.on('pointertap', (e) => { if (e.button > 0) return; this.onHit(); });
    // PX-FMT-06:頻繁變動的數字用 BitmapText
    this.score = new BitmapText({ text: '', style: { fill: 0xffffff, fontSize: 64, fontFamily: 'system-ui, sans-serif' } });
    this.score.position.set(48, 40);
    this.back = new Button({ label: t('play.back'), width: 260, height: 130, color: 0x4a5563, onActivate: () => void ctx.go('title') });
    this.back.position.set(DESIGN.width - 170, 105);
    this.world.addChild(this.target, this.score, this.back);
    this.root.addChild(this.world);
    this.render();
    this.dialog.addEventListener('cancel', this.onCancel);
    ctx.app.ticker.add(this.tick);
  }

  private onHit(): void {
    this.round = hit(this.round, this.rng);
    this.render();
    announceStatus(t('play.score', { score: this.round.score, goal: this.round.goal }));
    if (this.round.done) this.showResult();
  }

  private render(): void {
    this.target.position.set(this.round.target.x * DESIGN.width, this.round.target.y * DESIGN.height);
    this.score.text = `${this.round.score} / ${this.round.goal}`;
    setA11yAttr(this.target, 'aria-description', t('play.score', { score: this.round.score, goal: this.round.goal }));
  }

  private showResult(): void {
    document.getElementById('result-title')!.textContent = t('result.title');
    document.getElementById('result-body')!.textContent = t('result.body', { score: this.round.score });
    const again = document.getElementById('result-again') as HTMLButtonElement;
    const close = document.getElementById('result-close') as HTMLButtonElement;
    again.textContent = t('result.again');
    close.textContent = t('result.close');
    again.onclick = () => {
      this.dialog.close();
      this.round = newRound(GOAL, this.rng);
      this.render();
      focusA11y(this.target);
    };
    close.onclick = () => {
      this.dialog.close();
      void this.ctx.go('title');
    };
    this.dialog.showModal();
    again.focus(); // 安全的預設按鈕
  }

  private update(): void {
    if (!this.reduced) {
      this.pulse += this.ctx.app.ticker.deltaMS / 1000;
      this.target.scale.set(1 + Math.sin(this.pulse * 4) * 0.04);
    }
    syncA11y(this.target);
    this.back.update();
  }

  layout(fit: Fit): void {
    this.world.scale.set(fit.scale);
    this.world.position.set(fit.x, fit.y);
  }

  setInputEnabled(enabled: boolean): void {
    this.root.interactiveChildren = enabled;
  }

  destroy(): void {
    this.ctx.app.ticker.remove(this.tick);
    this.dialog.removeEventListener('cancel', this.onCancel);
    if (this.dialog.open) this.dialog.close();
    this.root.destroy({ children: true });
  }
}

export default (ctx: SceneContext): Scene => new PlayScene(ctx);
