#!/usr/bin/env python3
"""Exit 1 if the SQL on stdin contains transaction control at the start of a statement or any psql meta-command.

Removed first (so they never count): comments, string literals (incl. E'' backslash escapes), quoted identifiers,
dollar-quoted bodies ($$…$$, $tag$…$tag$) and SQL-standard bodies (BEGIN ATOMIC … END, CASE … END nested).
Any backslash left outside those is a psql meta-command (\\g, \\c, \\gexec …) and is refused.
Usage: _txcheck.py            (check stdin)
       _txcheck.py --connect  (only refuse \\c / \\connect / \\!, for psql scripts that use \\if, \\set, \\echo …)
"""
import re
import sys

TX = re.compile(r"^(COMMIT|END|ROLLBACK|ABORT|BEGIN|START\s+TRANSACTION|SAVEPOINT|RELEASE|PREPARE\s+TRANSACTION)\b", re.I)
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def strip(sql):
    out, i, n = [], 0, len(sql)
    while i < n:
        c = sql[i]
        if sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j
            continue
        if sql.startswith("/*", i):
            j = sql.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
            continue
        m = re.match(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$", sql[i:])
        if m and not (i > 0 and (sql[i - 1].isalnum() or sql[i - 1] == "_")):
            tag = m.group(0)
            j = sql.find(tag, i + len(tag))
            i = n if j < 0 else j + len(tag)
            out.append(" '' ")
            continue
        if c in ("'", '"'):
            esc = c == "'" and i > 0 and sql[i - 1] in "eE" and (i < 2 or not (sql[i - 2].isalnum() or sql[i - 2] == "_"))
            j = i + 1
            while j < n:
                if esc and sql[j] == "\\":
                    j += 2
                    continue
                if sql[j] == c and j + 1 < n and sql[j + 1] == c:
                    j += 2
                    continue
                if sql[j] == c:
                    break
                j += 1
            i = j + 1
            out.append(" x ")
            continue
        out.append(c)
        i += 1
    return "".join(out)


def drop_atomic(text):
    # Replace BEGIN ATOMIC … END (CASE … END nested inside) with a placeholder.
    out, pos = [], 0
    for m in re.finditer(r"\bBEGIN\s+ATOMIC\b", text, re.I):
        if m.start() < pos:
            continue
        depth, k = 1, m.end()
        for w in WORD.finditer(text, m.end()):
            u = w.group(0).upper()
            if u == "CASE":
                depth += 1
            elif u == "END":
                depth -= 1
                if depth == 0:
                    k = w.end()
                    break
        else:
            k = len(text)
        out.append(text[pos:m.start()] + " atomic_body ")
        pos = k
    out.append(text[pos:])
    return "".join(out)


def main():
    raw = sys.stdin.read()
    text = strip(raw)
    if "--connect" in sys.argv[1:]:
        for line in text.splitlines():
            if re.search(r"\\(c|connect|!)(\s|$)", line):
                print("psql reconnect / shell: " + line.strip()[:80])
                return 1
        return 0
    if "\\" in text:
        line = next(l for l in text.splitlines() if "\\" in l)
        print("psql meta-command: " + line.strip()[:80])
        return 1
    for stmt in drop_atomic(text).split(";"):
        s = stmt.strip()
        if TX.match(s):
            print(s.splitlines()[0][:80])
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
