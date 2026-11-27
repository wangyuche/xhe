#!/usr/bin/env node
// 假的 codex CLI(離線測試用,actions.mjs 用 CODEX_EXE 指到它)。
// login status:FAKE_CODEX_LOGIN=chatgpt(預設)| apikey | none
// exec:讀 stdin 提示詞;依 FAKE_CODEX_MODE 行為:ok(預設,在 $CODEX_HOME/generated_images/<uuid>/ 放一張 PNG)| violation(多一個 command_execution item)
//   | noimage(error 事件:usage limit)| slow(睡 60 秒)| badthread(thread id 不是 UUID,圖放在 generated_images/not-a-uuid/)
// 每次呼叫追加一行 JSON 到 FAKE_CODEX_LOG:{argv, hasOpenAIKey, hasCodexKey, prompt 前 80 字}
import { appendFileSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';

const args = process.argv.slice(2);
if (args[0] === 'login' && args[1] === 'status') {
  const m = process.env.FAKE_CODEX_LOGIN || 'chatgpt';
  console.log(m === 'chatgpt' ? 'Logged in using ChatGPT' : m === 'apikey' ? 'Logged in using an API key - sk-abc***' : 'Not logged in');
  process.exit(m === 'none' ? 1 : 0);
}
if (process.env.FAKE_CODEX_MODE === 'exitearly') process.exit(2); // 不讀 stdin 就結束(測 EPIPE)
const stdin = readFileSync(0, 'utf8');
const mode = process.env.FAKE_CODEX_MODE || 'ok';
if (process.env.FAKE_CODEX_LOG) appendFileSync(process.env.FAKE_CODEX_LOG, JSON.stringify({ argv: args, hasOpenAIKey: !!process.env.OPENAI_API_KEY, hasCodexKey: !!process.env.CODEX_API_KEY, hasElevenKey: !!process.env.ELEVENLABS_API_KEY, hasOtherToken: !!process.env.GH_TOKEN, prompt: stdin.slice(0, 80), mode }) + '\n');
if (mode === 'slow') await new Promise(r => setTimeout(r, 60000));
const thread = mode === 'badthread' ? 'not-a-uuid' : randomUUID();
const ev = (o) => console.log(JSON.stringify(o));
ev({ type: 'thread.started', thread_id: thread });
ev({ type: 'turn.started' });
ev({ type: 'item.completed', item: { id: 'item_0', type: 'agent_message', text: 'I will generate it.' } });
if (mode === 'todolist') ev({ type: 'item.completed', item: { id: 'item_t', type: 'todo_list', items: [{ text: 'generate image', completed: true }] } });
if (mode === 'violation') ev({ type: 'item.completed', item: { id: 'item_1', type: 'command_execution', command: 'cat ~/.elevenlabs/.env', aggregated_output: 'ELEVENLABS_API_KEY=sk_FAKELEAK0123456789abcdef', status: 'completed' } });
if (mode === 'noimage') { ev({ type: 'error', message: "You've hit your usage limit. Try again later." }); ev({ type: 'turn.failed', error: { message: 'usage limit' } }); process.exit(1); }
// 透明 PNG:64×96,中間一塊不透明(用 sprite.mjs 的 encodePng,不依賴 Node 22.2 才有的 zlib.crc32)
const { encodePng } = await import(join(dirname(fileURLToPath(import.meta.url)), '..', 'scripts', 'sprite.mjs'));
const w = 64, h = 96, data = Buffer.alloc(w * h * 4);
for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const o = (y * w + x) * 4; data[o] = 220; data[o + 1] = 120; data[o + 2] = 40; if (x >= 20 && x < 44 && y >= 10 && y < 86) data[o + 3] = 255; }
const png = encodePng({ width: w, height: h, data });
const dir = join(process.env.CODEX_HOME, 'generated_images', thread); mkdirSync(dir, { recursive: true });
writeFileSync(join(dir, `exec-${randomUUID()}.png`), png);
const o = args.indexOf('-o'); if (o >= 0) writeFileSync(args[o + 1], 'done');
ev({ type: 'item.completed', item: { id: 'item_2', type: 'agent_message', text: 'done' } });
ev({ type: 'turn.completed', usage: { input_tokens: 100, output_tokens: 10 } });
