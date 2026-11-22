// .tsx:結束標籤 </b> 不是 regex 的開頭,後面的註解要照常去掉(不能把註解裡的 sink 當違規)
export const Hint = () => <p><b>{label}</b> {count}</p>; // el.textContent = 'Hello';
export const Bold = () => <b>{name}</b>; /* btn.accessibleTitle = 'Start'; */
