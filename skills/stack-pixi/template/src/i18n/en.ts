/** 玩家看得到的文字一律放這裡(PX-I18N-01);key 用 `<區域>.<用途>`,`{name}` 是參數。 */
export const en = {
  'common.loading': 'Loading…',
  'common.reload': 'Reload',
  'common.rotate': 'Please rotate your device to landscape.',
  'common.rotatePortrait': 'Please rotate your device to portrait.',
  'error.boot': 'Something went wrong while starting. Please reload.',
  'error.contextLost': 'The graphics context was lost. Please reload.',
  'title.heading': '__TITLE__',
  'title.start': 'Start',
  'play.target': 'Hit the target',
  'play.score': 'Score {score} of {goal}',
  'play.back': 'Back',
  'result.title': 'Round complete',
  'result.body': 'You scored {score}.',
  'result.again': 'Play again',
  'result.close': 'Back to title',
} as const;

export type MessageKey = keyof typeof en;
