/**
 * 任何原生 <dialog> 開著時通知場景關閉輸入(PX-A11Y-04):Pixi 的 pointermove 掛在 document 上,
 * showModal() 擋不到,底下的物件仍會被 hover / 點到。只用 DOM 介面,不 import pixi。
 */
export const anyModalOpen = (root: ParentNode = document): boolean => root.querySelector('dialog[open]') !== null;

export function watchModalDialogs(onChange: (open: boolean) => void, root: ParentNode = document): () => void {
  let last = anyModalOpen(root);
  const mo = new MutationObserver(() => {
    const now = anyModalOpen(root);
    if (now !== last) {
      last = now;
      onChange(now);
    }
  });
  mo.observe(root as Node, { subtree: true, childList: true, attributes: true, attributeFilter: ['open'] });
  return () => mo.disconnect();
}
