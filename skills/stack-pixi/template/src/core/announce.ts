/** 讀屏公告(PX-A11Y-03):先清空再寫(50 ms 後),同樣的訊息也會重新唸。 */
const timers = new Map<string, ReturnType<typeof setTimeout>>();

function say(id: string, text: string): void {
  const el = document.getElementById(id);
  if (!el) return;
  clearTimeout(timers.get(id));
  el.textContent = '';
  timers.set(id, setTimeout(() => {
    timers.delete(id);
    el.textContent = text;
  }, 50));
}

export const announceStatus = (text: string): void => say('sr-status', text);
export const announceAlert = (text: string): void => say('sr-alert', text);
