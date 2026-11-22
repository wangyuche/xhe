import { en, type MessageKey } from './en';

export type { MessageKey };
type Messages = Record<MessageKey, string>;

const locales: Record<string, Messages> = { en };
let current: Messages = en;

export function setLocale(locale: string): void {
  current = locales[locale] ?? en;
}

/** `{name}` 參數替換;沒給的參數保留原樣。 */
export function format(msg: string, params?: Record<string, string | number>): string {
  if (!params) return msg;
  return msg.replace(/\{(\w+)\}/g, (m, k: string) => (Object.hasOwn(params, k) ? String(params[k]) : m));
}

/** 取文案(PX-I18N-01),例如 t('result.body', { score: 3 })。 */
export const t = (key: MessageKey, params?: Record<string, string | number>): string => format(current[key], params);
