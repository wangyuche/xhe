import { Container, Text } from 'pixi.js';
import { Button } from '../../components/Button';
import type { Fit } from '../../core/layout';
import type { Scene, SceneContext } from '../../core/scene-manager';
import { DESIGN } from '../../config/design';
import { t } from '../../i18n';

class TitleScene implements Scene {
  readonly root = new Container();
  private readonly world = new Container();
  private readonly start: Button;
  private readonly tick = (): void => this.start.update();

  constructor(private readonly ctx: SceneContext) {
    const heading = new Text({ text: t('title.heading'), style: { fill: 0xffffff, fontSize: 96, fontWeight: '800', fontFamily: 'system-ui, sans-serif' } });
    heading.anchor.set(0.5);
    heading.position.set(DESIGN.width / 2, DESIGN.height * 0.35);
    this.start = new Button({ label: t('title.start'), width: 400, height: 140, onActivate: () => void ctx.go('play') });
    this.start.position.set(DESIGN.width / 2, DESIGN.height * 0.65);
    this.world.addChild(heading, this.start);
    this.root.addChild(this.world);
    ctx.app.ticker.add(this.tick);
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
    this.root.destroy({ children: true });
  }
}

export default (ctx: SceneContext): Scene => new TitleScene(ctx);
