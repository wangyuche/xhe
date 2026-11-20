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
lines = (["第三季營收 56.67 億"] + ["對"] * 30 + ["毛利率 25.4%"] + ["我們要看這家客戶"] * 150
         + ["謝謝謝謝"] + ["請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目"] + ["所以方法法法法法法法法法吗"] + ["展望明年 10-15% 成長"])
open(src, "w", encoding="utf-8").write("\n".join(lines) + "\n")
r = subprocess.run([sys.executable, "-I", os.path.join(S, "clean.py"), src, dst], capture_output=True, text=True, check=True)
out = open(dst, encoding="utf-8").read().splitlines()
check("填充字刪掉", "對" not in out and "謝謝謝謝" not in out)
check("連續重複壓成一行", out.count("我們要看這家客戶") == 1)
check("幻覺句刪掉", not any("點贊" in l for l in out))
check("單字重複壓成 3 個", "所以方法法法吗" in out)
check("內容保留且順序不變", out[0] == "第三季營收 56.67 億" and out[-1] == "展望明年 10-15% 成長" and "毛利率 25.4%" in out)
check("迴圈警告", "LOOP 150x" in r.stdout and "WARN" in r.stdout)
for p in (src, dst): os.remove(p)

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
