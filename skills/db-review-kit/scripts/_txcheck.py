#!/usr/bin/env python3
"""Exit 1 if the SQL on stdin contains transaction control at the start of a statement or any psql meta-command.

Removed first (so they never count): comments, string literals (incl. E'' backslash escapes), quoted identifiers,
dollar-quoted bodies ($$…$$, $tag$…$tag$) and SQL-standard bodies (BEGIN ATOMIC … END, CASE … END nested).
Any backslash left outside those is a psql meta-command (\\g, \\c, \\gexec …) and is refused.
Usage: _txcheck.py            (check stdin)
       _txcheck.py --connect  (psql scripts: a backslash only as one allowed meta-command at line start, or a trailing
                               \\gset; refuse \\c \\! \\o \\copy \\i …, backticks, and backslashes in SQL text)
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
        m = re.match(r"\$([A-Za-z_\u0080-\U0010ffff][A-Za-z0-9_\u0080-\U0010ffff]*)?\$", sql[i:])   # psql allows high-bit tag chars
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
        depth, k, paren = 1, None, 0
        pos2 = m.end()
        for t in re.finditer(r"[()]|[A-Za-z_][A-Za-z0-9_]*", text[m.end():]):
            tok = t.group(0)
            if tok == "(":
                paren += 1; continue
            if tok == ")":
                paren -= 1; continue
            start = m.end() + t.start()
            if paren != 0 or (start > 0 and text[start - 1] == "."):
                continue          # psql counts CASE / END only at paren depth 0; t.case is a column
            u = tok.upper()
            if u == "CASE":
                depth += 1
            elif u == "END":
                depth -= 1
                if depth == 0:
                    k = m.end() + t.end()
                    break
        if k is None:
            return None           # no matching END: fail closed
        out.append(text[pos:m.start()] + " atomic_body ")
        pos = k
    out.append(text[pos:])
    return "".join(out)


def main():
    raw = sys.stdin.read()
    if re.search(r"\bU&['\"]", raw, re.I):
        print("U& escapes are not allowed (they hide identifiers and literals from this check)")
        return 1
    # an actual change of these GUCs (SET / RESET / ALTER … SET / set_config with that name), not every set_config call
    if re.search(r"(standard_conforming_strings|escape_string_warning)", raw, re.I) or \
            re.search(r"set_config\s*\(\s*(?!'(?!standard_conforming_strings|escape_string_warning)[A-Za-z0-9_.]+'\s*,)", raw, re.I):
        # with it off, backslashes inside '…' escape quotes and the literal boundaries below would be wrong
        print("changing standard_conforming_strings is not allowed")
        return 1
    if "--connect" in sys.argv[1:]:
        allowed = {"if", "elif", "else", "endif", "set", "unset", "echo", "qecho", "warn", "pset", "gset", "timing",
                   "x", "a", "t", "f", "q", "quit", "getenv", "conninfo", "encoding"}
        # psql re-lexes a bare :name value as if typed (so a value holding "\\c host=…" would run). In SQL lines only
        # :'name' / :"name" (quoted, safe) or a bare :name set by a validated -v (--vars) or a plain \\set are allowed.
        vars_ok = set(v for v in (sys.argv[sys.argv.index("--vars") + 1].split(",") if "--vars" in sys.argv else []) if v)
        # Untrusted names: anything a \gset may set (every identifier of that statement, or everything if it selects *),
        # a \set with a non-plain value (e.g. "\set y :x" copies another variable), and \getenv targets.
        untrusted, untrusted_all, stmt = set(), False, []
        for line in raw.splitlines():
            st = line.lstrip()
            m = re.match(r"\\set\s+([A-Za-z_][A-Za-z0-9_]*)(\s+(.*))?$", st)
            if m:
                if re.fullmatch(r"[A-Za-z0-9_.+-]*", (m.group(3) or "").strip()):
                    vars_ok.add(m.group(1))
                else:
                    untrusted.add(m.group(1))
                continue
            m = re.match(r"\\getenv\s+([A-Za-z_][A-Za-z0-9_]*)", st)
            if m:
                untrusted.add(m.group(1))
                continue
            if st.startswith("\\"):
                continue
            stmt.append(line)
            if re.search(r"\\gset", line):
                text_g = "\n".join(stmt)
                text_g = text_g[text_g.rfind(";") + 1:]
                quoted = re.findall(r'"([^"]*)"', text_g)
                bare = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", strip(text_g))
                untrusted.update(quoted); untrusted.update(b.lower() for b in bare); untrusted.update(bare)
                if "*" in strip(text_g):
                    untrusted_all = True
                stmt = []
            elif ";" in strip(line):
                stmt = []
        sql_only = strip("\n".join(l for l in raw.splitlines() if not l.lstrip().startswith("\\")))
        for vm in re.finditer(r"(?<![:A-Za-z0-9_]):([A-Za-z_][A-Za-z0-9_]*)", sql_only):
            if vm.group(1) not in vars_ok or vm.group(1) in untrusted or untrusted_all:
                print("bare :%s in SQL (re-lexed by psql); use :'%s' or pass it with -v" % (vm.group(1), vm.group(1)))
                return 1
        # psql's own lexer decides where a meta-command starts, and emulating it has proven fragile. So in script mode a
        # backslash is only accepted in two exact shapes, checked per raw line (no SQL lexing involved):
        #   - a line that starts with an allowed meta-command and has exactly one backslash and no backtick;
        #   - an SQL line ending in "\\gset [prefix]" with exactly one backslash.
        # Any other backslash (in SQL text, literals, comments) is refused: write chr(92) instead.
        for line in raw.splitlines():
            st = line.lstrip()
            if "\\" not in line:
                continue
            if "`" in line or line.count("\\") != 1:
                print("backslash / backtick not allowed here: " + st[:60])
                return 1
            if st.startswith("\\"):
                cmd = re.match(r"\\([A-Za-z!?]*)", st).group(1)
                if cmd not in allowed:
                    print("psql meta-command not allowed: " + st[:60])
                    return 1
            elif not re.search(r"\\gset(\s+[A-Za-z_][A-Za-z0-9_]*)?\s*$", line):
                print("backslash in an SQL line is only allowed as a trailing \\gset: " + st[:60])
                return 1
        return 0
    text = strip(raw)
    if "\\" in text:
        line = next(l for l in text.splitlines() if "\\" in l)
        print("psql meta-command: " + line.strip()[:80])
        return 1
    dropped = drop_atomic(text)
    if dropped is None:
        print("BEGIN ATOMIC without a matching END")
        return 1
    for stmt in dropped.split(";"):
        s = stmt.strip()
        if TX.match(s):
            print(s.splitlines()[0][:80])
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
