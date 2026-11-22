import type { Application, Container } from 'pixi.js';
import { acquireGroup, releaseGroup } from '../assets';
import { computeFit, type Fit } from './layout';
import { watchModalDialogs } from './modal-guard';
import { readSafeArea } from './safe-area';

/** 場景介面:每個場景一個資料夾、動態 import、各自一個 chunk(PX-LOAD-01)。 */
export interface Scene {
  readonly root: Container;
  /** 唯一的版面入口(PX-RES-03):由 SceneManager 在 renderer resize 時呼叫。 */
  layout(fit: Fit): void;
  setInputEnabled(enabled: boolean): void;
  /** PX-LIFE-01:destroy({children:true}),移除監聽、ticker 回呼、dialog 綁定。 */
  destroy(): void;
}

export interface SceneContext {
  app: Application;
  go: (name: SceneName) => Promise<void>;
}

/** 場景表:新增場景時在這裡加一行;只能從這裡動態 import 場景(首屏不靜態 import 其他場景)。 */
const SCENES = {
  title: { group: 'title', load: () => import('../scenes/title/TitleScene') },
  play: { group: 'play', load: () => import('../scenes/play/PlayScene') },
} as const;
export type SceneName = keyof typeof SCENES;

export class SceneManager {
  private current?: { name: SceneName; scene: Scene };
  private queue: Promise<void> = Promise.resolve();
  private modalOpen = false;

  constructor(private readonly app: Application) {
    app.renderer.on('resize', () => this.layout());
    watchModalDialogs((open) => {
      this.modalOpen = open;
      this.current?.scene.setInputEnabled(!open);
    });
  }

  get currentName(): SceneName | undefined {
    return this.current?.name;
  }

  go(name: SceneName): Promise<void> {
    this.queue = this.queue.then(() => this.swap(name));
    return this.queue;
  }

  private async swap(name: SceneName): Promise<void> {
    const def = SCENES[name];
    const [mod] = await Promise.all([def.load(), acquireGroup(def.group)]);
    const scene: Scene = mod.default({ app: this.app, go: (n) => this.go(n) });
    const prev = this.current;
    this.app.stage.addChild(scene.root);
    this.current = { name, scene };
    scene.setInputEnabled(!this.modalOpen);
    this.layout();
    if (prev) {
      prev.scene.destroy();
      releaseGroup(SCENES[prev.name].group);
    }
    performance.mark(`${name}:ready`);
  }

  layout(): void {
    const { width, height } = this.app.screen;
    this.current?.scene.layout(computeFit(width, height, readSafeArea()));
  }
}
