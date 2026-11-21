#!/usr/bin/env python3
"""audio-transcribe 測試(只用標準函式庫 + ffmpeg)。
執行: python3 -I tests/test_audio_transcribe.py
whisper 本身不在這裡測(需要模型與真實語音);這裡測 prep.sh 轉檔與 clean.py 清理。"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
S = os.path.join(HERE, "..", "scripts")
TMP = tempfile.gettempdir() if os.access(tempfile.gettempdir(), os.W_OK) else HERE
fails = 0
def check(name, cond):
    global fails
    print(("PASS " if cond else "FAIL ") + name); fails += 0 if cond else 1

# 1. clean.py:填充字、連續重複、幻覺句、單字重複
src = os.path.join(TMP, "at_in.txt"); dst = os.path.join(TMP, "at_out.txt")
lines = (["第三季營收 56.67 億"] + ["對"] * 30 + ["嗯～"] + ["毛利率 25.4%"] + ["我們要看這家客戶"] * 150
         + ["謝謝謝謝"] + ["請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目"] + ["所以方法法法法法法法法法吗"] * 3 + ["展望明年 10-15% 成長"])
open(src, "w", encoding="utf-8").write("\n".join(lines) + "\n")
r = subprocess.run([sys.executable, "-I", os.path.join(S, "clean.py"), src, dst], capture_output=True, text=True, check=True)
out = open(dst, encoding="utf-8").read().splitlines()
check("填充字刪掉", "對" not in out and "謝謝謝謝" not in out and "嗯～" not in out)
check("連續重複壓成一行", out.count("我們要看這家客戶") == 1)
check("幻覺句刪掉", not any("點贊" in l for l in out))
check("單字重複壓成 3 個(壓完再合併連續重複)", out.count("所以方法法法吗") == 1)
check("內容保留且順序不變", out[0] == "第三季營收 56.67 億" and out[-1] == "展望明年 10-15% 成長" and "毛利率 25.4%" in out)
check("迴圈警告", "LOOP 150x" in r.stdout and "WARN" in r.stdout)
for p in (src, dst): os.remove(p)

# 1b. 幻覺句只刪整句頻道宣傳;只提到訂閱 / 轉發 / 分享 / 打賞的正常內容要保留
keep = ["訂閱制營收年增 30%", "我們的轉發服務明年擴大到東南亞", "直播打賞收入占比 12%", "分享一下第四季的展望",
        "直播打賞與訂閱收入占比 20%", "分享訂閱制成長", "訂閱與打賞收入都成長", "謝謝大家的分享", "歡迎大家關注",
        "分享會", "還請各位不吝指教，請不吝提問", "訂閱數", "訂閱頻道數成長三成", "加訂閱", "我們的平台字幕由AI即時提供，明年擴大到東南亞", "訂閱頻道", "轉發頻道",
        "頻道訂閱", "我們的訂閱", "訂閱和轉發", "支持訂閱", "訂閱轉發"]
drop = ["請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目", "字幕由Amara.org社區提供", "歡迎訂閱我的頻道",
        "記得按讚訂閱", "點贊、分享、開啟小鈴鐺", "歡迎訂閱我的頻道 一起分享", "订阅我的频道", "轉發訂閱我的頻道", "請不吝點讚 訂閱 轉發", "點贊 訂閱 轉發 打賞支持",
        "請訂閱我的頻道 感謝觀看", "字幕由Amara.org社區提供 謝謝觀看", "字幕：張三", "記得訂閱點贊哦 謝謝大家", "請訂閱", "點贊", "感謝打賞", "謝謝大家的支持 請訂閱"]
open(src, "w", encoding="utf-8").write("\n".join(keep + drop) + "\n")
r = subprocess.run([sys.executable, "-I", os.path.join(S, "clean.py"), src, dst], capture_output=True, text=True, check=True)
out = open(dst, encoding="utf-8").read().splitlines()
check("提到訂閱 / 轉發的正常內容保留", out == keep)
check("頻道宣傳句刪掉", f"hallu={len(drop)}" in r.stdout)
for p in (src, dst): os.remove(p)

# 1c. model.sh:WHISPER_MODEL > ~/.config/audio-transcribe/config > ~/.cache/whisper 預設;找不到時結束碼 3
import shutil
home = tempfile.mkdtemp(prefix="at_home_", dir=TMP)
try:
    m1 = os.path.join(home, "m1.bin"); m2 = os.path.join(home, "m 2.bin")
    for m in (m1, m2): open(m, "w").write("x")
    env = {"HOME": home, "PATH": os.environ["PATH"]}
    ms = os.path.join(S, "model.sh")
    r = subprocess.run(["bash", ms], capture_output=True, text=True, env=env)
    check("model.sh 沒有模型 → 結束碼 3 附下載指令", r.returncode == 3 and "huggingface.co" in r.stderr)
    os.makedirs(os.path.join(home, ".config", "audio-transcribe"))
    open(os.path.join(home, ".config", "audio-transcribe", "config"), "w").write(f"# 本機\nexport WHISPER_MODEL=\"{m2}\"\n")
    r = subprocess.run(["bash", ms], capture_output=True, text=True, env=env)
    check("model.sh 讀設定檔(含 export、引號、註解)", r.returncode == 0 and r.stdout.strip() == m2)
    open(os.path.join(home, ".config", "audio-transcribe", "config"), "w").write("WHISPER_MODEL=$HOME/m1.bin  \r\n")
    r = subprocess.run(["bash", ms], capture_output=True, text=True, env=env)
    check("model.sh 設定檔 $HOME 開頭、CRLF", r.returncode == 0 and r.stdout.strip() == m1)
    m3 = os.path.join(home, "models #2", "g.bin"); os.makedirs(os.path.dirname(m3)); open(m3, "w").write("x")
    open(os.path.join(home, ".config", "audio-transcribe", "config"), "w").write(f'WHISPER_MODEL="{m3}" # 註解\n')
    r = subprocess.run(["bash", ms], capture_output=True, text=True, env=env)
    check("model.sh 引號內的 # 不當註解", r.returncode == 0 and r.stdout.strip() == m3)
    r = subprocess.run(["bash", ms], capture_output=True, text=True, env=dict(env, WHISPER_MODEL=home + "/Bob's.bin"))
    check("model.sh 路徑含單引號 → 結束碼 2", r.returncode == 2)
    r = subprocess.run(["bash", ms], capture_output=True, text=True, env=dict(env, WHISPER_MODEL=m1))
    check("model.sh 環境變數優先", r.returncode == 0 and r.stdout.strip() == m1)
    r = subprocess.run(["bash", ms], capture_output=True, text=True, env=dict(env, WHISPER_MODEL=m1 + ".no"))
    check("model.sh 指定的檔案不存在 → 結束碼 3", r.returncode == 3 and "找不到" in r.stderr)
finally:
    shutil.rmtree(home, ignore_errors=True)

# 2. prep.sh:任意音檔 → 16kHz 單聲道 wav
tone = os.path.join(TMP, "at_tone.m4a"); wav = os.path.join(TMP, "at_tone.wav")
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", tone], check=True)
r = subprocess.run(["bash", os.path.join(S, "prep.sh"), tone, wav], capture_output=True, text=True)
info = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=sample_rate,channels", "-of", "csv=p=0", wav],
                      capture_output=True, text=True).stdout.strip()
check("prep 輸出 16kHz 單聲道", r.returncode == 0 and info == "16000,1" and "duration_sec=2" in r.stdout)
r = subprocess.run(["bash", os.path.join(S, "prep.sh"), os.path.join(TMP, "no_such.m4a"), wav], capture_output=True, text=True)
check("prep 找不到檔案要報錯", r.returncode != 0 and "找不到輸入檔" in r.stdout)
for p in (tone, wav):
    if os.path.exists(p): os.remove(p)

sys.exit(1 if fails else 0)
