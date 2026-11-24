// 混音共用模組(compose.mjs 與 motion-video-kit 的 mix.mjs 共用,不要複製)。只用 Node 內建模組 + ffmpeg。
//   narrationVoice(list, total)         → 旁白排程:list = [{path, at}](at = 開始秒數),輸出 filter 標籤 [voice]
//   mixWav({voice, total, music, sfx, out, run})
//                                        → voice(旁白或原聲)+ 配樂(說話時 sidechain 壓低、結尾 1.5 秒淡出)+ 音效 → 48 kHz 立體聲 WAV
//   measureLoudness(file, run)          → loudnorm 第一階段量測結果(太安靜 / 無聲時 null)
//   loudnormFilter(ln, inLabel, outLabel) → 第二階段濾鏡(−14 LUFS、TP −1.5、linear);ln 為 null 時原樣通過
// voice = { inputs: [ffmpeg 輸入參數…], filters: [濾鏡…] },輸入編號從 0 開始,最後要產生 [voice](長度 = total)。
// music = { path, volume };sfx = [{ path, volume, at }]。run(cmd, argv, label) 由呼叫端提供(失敗時結束程式)。

const countInputs = (args) => args.filter(x => x === '-i').length;

export function narrationVoice(list, total) {
  const inputs = []; const filters = [];
  list.forEach((n, i) => {
    inputs.push('-i', n.path);
    filters.push(`[${i}:a]aresample=48000,aformat=channel_layouts=stereo,adelay=${Math.round(n.at * 1000)}:all=1[n${i}]`);
  });
  if (list.length) filters.push(`${list.map((_, i) => `[n${i}]`).join('')}amix=inputs=${list.length}:normalize=0:duration=longest,apad,atrim=0:${total}[voice]`);
  else filters.push(`anullsrc=r=48000:cl=stereo,atrim=0:${total}[voice]`);
  return { inputs, filters };
}

export function mixWav({ voice, total, music, sfx = [], out, run }) {
  const ai = [...voice.inputs]; const af = [...voice.filters]; let cur = '[voice]';
  if (music) {
    const mi = countInputs(ai);
    ai.push('-stream_loop', '-1', '-i', music.path);
    af.push(`[${mi}:a]aresample=48000,aformat=channel_layouts=stereo,volume=${music.volume},atrim=0:${total},afade=t=out:st=${Math.max(0, total - 1.5)}:d=1.5[mus]`);
    af.push(`[voice]asplit[v1][v2];[mus][v2]sidechaincompress=threshold=0.02:ratio=10:attack=20:release=500[duck];[v1][duck]amix=inputs=2:normalize=0:duration=first[mix]`);
    cur = '[mix]';
  }
  if (sfx.length) {
    sfx.forEach((x, k) => {
      const si = countInputs(ai);
      ai.push('-i', x.path);
      af.push(`[${si}:a]aresample=48000,aformat=channel_layouts=stereo,volume=${x.volume},adelay=${Math.round(x.at * 1000)}:all=1[fx${k}]`);
    });
    af.push(`${cur}${sfx.map((_, k) => `[fx${k}]`).join('')}amix=inputs=${sfx.length + 1}:normalize=0:duration=first[withfx]`);
    cur = '[withfx]';
  }
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...ai, '-filter_complex', af.join(';'), '-map', cur, '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s16le', '-t', String(total), out], '混音');
}

export function measureLoudness(file, run) {
  const r = run('ffmpeg', ['-hide_banner', '-nostats', '-i', file, '-af', 'loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json', '-f', 'null', '-'], '響度量測');
  const m = r.stderr.match(/\{[\s\S]*?\}/g);
  const j = m ? JSON.parse(m[m.length - 1]) : null;
  return { raw: j, ln: j && Number.isFinite(Number(j.input_i)) && Number(j.input_i) > -70 ? j : null };
}

export function loudnormFilter(ln, inLabel, outLabel) {
  return ln
    ? `${inLabel}loudnorm=I=-14:TP=-1.5:LRA=11:measured_I=${ln.input_i}:measured_TP=${ln.input_tp}:measured_LRA=${ln.input_lra}:measured_thresh=${ln.input_thresh}:offset=${ln.target_offset}:linear=true,aresample=48000${outLabel}`
    : `${inLabel}anull${outLabel}`;
}
