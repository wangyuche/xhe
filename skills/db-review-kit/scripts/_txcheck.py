#!/usr/bin/env python3
"""Exit 1 if the SQL on stdin contains transaction control at the start of a statement or any psql meta-command.

Removed first (so they never count): comments, string literals (incl. E'' backslash escapes), quoted identifiers,
dollar-quoted bodies ($$…$$, $tag$…$tag$) and SQL-standard bodies (BEGIN ATOMIC … END, CASE … END nested).
Any backslash left outside those is a psql meta-command (\\g, \\c, \\gexec …) and is refused.
Usage: _txcheck.py            (check stdin)
       _txcheck.py --connect  (psql scripts: allow only \\if \\set \\echo \\pset \\gset … ; refuse \\c \\! \\o \\copy \\i …)
"""
import re
import sys

TX = re.compile(r"^(COMMIT|END|ROLLBACK|ABORT|BEGIN|START\s+TRANSACTION|SAVEPOINT|RELEASE|PREPARE\s+TRANSACTION)\b", re.I)
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def strip(sql, keep_comments=False):
    out, i, n = [], 0, len(sql)
    while i < n:
        c = sql[i]
        if keep_comments and sql.startswith("--", i):
            j = sql.find("\n", i)          # copy the whole line comment verbatim (quotes in it mean nothing)
            j = n if j < 0 else j
            out.append(sql[i:j]); i = j
            continue
        if keep_comments and sql.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if sql.startswith("/*", j):
                    depth += 1; j += 2
                elif sql.startswith("*/", j):
                    depth -= 1; j += 2
                else:
                    j += 1
            out.append(sql[i:j]); i = j
            continue
        if sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j
            continue
        if sql.startswith("/*", i):
            depth, j = 1, i + 2          # PostgreSQL block comments nest
            while j < n and depth:
                if sql.startswith("/*", j):
                    depth += 1; j += 2
                elif sql.startswith("*/", j):
                    depth -= 1; j += 2
                else:
                    j += 1
            i = j
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
        stmt_start = text.rfind(";", 0, m.start()) + 1
        if not re.match(r"\s*CREATE\s+(OR\s+REPLACE\s+)?(FUNCTION|PROCEDURE)\b", text[stmt_start:m.start()], re.I):
            continue          # "begin atomic" outside a function definition is just words (e.g. column + alias)
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
    if "--connect" in sys.argv[1:]:
        allowed = {"if", "elif", "else", "endif", "set", "unset", "echo", "qecho", "warn", "pset", "gset", "timing",
                   "x", "a", "t", "f", "q", "quit", "getenv", "conninfo", "encoding"}
        # 1) Lines starting with a backslash are psql meta-commands; psql parses their arguments up to end of line with
        #    its own rules, so validate each line on its own (exactly one backslash, allowed command, no backtick) and
        #    then remove it, so a stray quote in it cannot hide later lines from the SQL scan.
        sql_lines = []
        for line in raw.splitlines():
            st = line.lstrip()
            if not st.startswith("\\"):
                sql_lines.append(line)
                continue
            cmd = re.match(r"\\([A-Za-z!?]*)", st).group(1)
            if line.count("\\") > 1 or "`" in line or cmd not in allowed:
                print("psql meta-command not allowed: " + st[:60])
                return 1
            sql_lines.append("")
        # 2) SQL lines: psql's SQL lexer does carry quotes across lines, like strip(); comments are kept (stricter).
        text = strip("\n".join(sql_lines), keep_comments=True)
        if "`" in text:
            print("backtick not allowed: " + next(l for l in text.splitlines() if "`" in l).strip()[:60])
            return 1
        m = re.search(r"\\([A-Za-z!?]*)", text)
        if m:   # a meta-command after SQL on the same line (e.g. SELECT 1 \\g |sh): only allowed ones, still one per line
            for mm in re.finditer(r"\\([A-Za-z!?]*)", text):
                if mm.group(1) not in allowed:
                    line = text[text.rfind("\n", 0, mm.start()) + 1:].split("\n", 1)[0]
                    print("psql meta-command not allowed: \\" + mm.group(1) + " (" + line.strip()[:60] + ")")
                    return 1
        return 0
    text = strip(raw)
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
