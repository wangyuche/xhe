import { expect, test } from '@playwright/test';
import { PORTRAIT, SIZES, a11y, cycleLeak, drawsDuring, expectNoErrors, gotoReady, openContext, press, shot, waitMark } from '../fixtures/base';

// 骨架範例情境(DEMO-S1、DEMO-S3、DEMO-S4)。換成真正的遊戲時,依驗收情境改寫;測試名稱以情境編號開頭。
for (const size of SIZES) {
  test(`DEMO-S1 start, hit the target three times, see the result (${size.name})`, async ({ browser }) => {
    const { context, page } = await openContext(browser, size);
    await gotoReady(page);
    await shot(page, `demo-s1-title-${size.name}`);
    await press(page, size, 'Start');
    await waitMark(page, 'play:ready');
    for (let i = 0; i < 3; i++) await press(page, size, 'Hit the target');
    const dialog = page.locator('#result-dialog');
    await expect(dialog).toHaveJSProperty('open', true);
    await expect(page.locator('#result-body')).toHaveText('You scored 3.');
    await expect(page.locator('#result-again')).toBeFocused();
    await shot(page, `demo-s1-result-${size.name}`);
    await page.keyboard.press('Escape'); // Esc → 回標題
    await expect(dialog).toHaveJSProperty('open', false);
    await waitMark(page, 'title:ready');
    expectNoErrors(page);
    await context.close();
  });
}

test('DEMO-S3 keyboard Tab + Enter starts the game', async ({ browser }) => {
  const { context, page } = await openContext(browser, SIZES[0]!);
  await gotoReady(page);
  await a11y(page, 'Start').focus();
  await page.keyboard.press('Enter');
  await waitMark(page, 'play:ready');
  await a11y(page, 'Hit the target').focus();
  await page.keyboard.press('Enter');
  await expect(page.locator('#sr-status')).toHaveText('Score 1 of 3');
  expectNoErrors(page);
  await context.close();
});

test('DEMO-S4 portrait phone shows the rotate prompt', async ({ browser }) => {
  const { context, page } = await openContext(browser, PORTRAIT);
  await page.goto('/?a11y=1');
  await expect(page.locator('#rotate')).toBeVisible();
  await expect(page.locator('#rotate')).toHaveText('Please rotate your device to landscape.');
  await shot(page, `demo-s4-${PORTRAIT.name}`);
  expectNoErrors(page);
  await context.close();
});

test('DEMO-S5 scenes release resources and pause draws nothing', async ({ browser }) => {
  const size = SIZES[0]!;
  const { context, page } = await openContext(browser, size);
  await gotoReady(page);
  await cycleLeak(page,
    async () => { await press(page, size, 'Start'); await page.waitForFunction(() => (window as any).__bounds('Hit the target')); },
    async () => { await press(page, size, 'Back'); await page.waitForFunction(() => (window as any).__bounds('Start')); });
  expect(await drawsDuring(page)).toBe(0);
  expectNoErrors(page);
  await context.close();
});
