#!/usr/bin/env python3
"""Exit 4 (psql meta-command / backslash / backtick / unsafe variable: could leave the container) or 2 (other content
rules: transaction control, U&, standard_conforming_strings) if the SQL on stdin contains transaction control at the start of a statement or any psql meta-command.

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
        return 2
    # an actual change of these GUCs (SET / RESET / ALTER … SET / set_config with that name), not every set_config call
    if re.search(r"(standard_conforming_strings|escape_string_warning)", raw, re.I) or \
            re.search(r"set_config\s*\(\s*(?!'(?!standard_conforming_strings|escape_string_warning)[A-Za-z0-9_.]+'\s*,)", raw, re.I):
        # with it off, backslashes inside '…' escape quotes and the literal boundaries below would be wrong
        print("changing standard_conforming_strings is not allowed")
        return 2
    if "--connect" in sys.argv[1:]:
        allowed = {"if", "elif", "else", "endif", "set", "unset", "echo", "qecho", "warn", "pset", "gset", "timing",
                   "x", "a", "t", "f", "q", "quit", "getenv", "conninfo", "encoding"}
        # psql re-lexes a bare :name value as if typed (so a value holding "\\c host=…" would run). In SQL lines only
        # :'name' / :"name" (quoted, safe) or a bare :name set by a validated -v (--vars) or a plain \\set are allowed.
        # Order-independent and strict: a bare :name in SQL is allowed only when ALL hold
        #   - the name came in through a validated -v (--vars: values are only [A-Za-z0-9_.+-]) or a plain \\set,
        #   - it is not one of psql's own variables (psql overwrites those, e.g. LAST_ERROR_MESSAGE),
        #   - the script never assigns it: no \\set / \\unset / \\getenv of it, and if the script has any \\gset,
        #     no identifier anywhere in the script (alone or after a \\gset prefix) that could produce it, and no
        #     \\gset over a SELECT *.
        PSQL_VARS = {"AUTOCOMMIT", "COMP_KEYWORD_CASE", "DBNAME", "ECHO", "ECHO_HIDDEN", "ENCODING", "ERROR",
                     "FETCH_COUNT", "HIDE_TABLEAM", "HIDE_TOAST_COMPRESSION", "HISTCONTROL", "HISTFILE", "HISTSIZE",
                     "HOST", "IGNOREEOF", "LASTOID", "LAST_ERROR_MESSAGE", "LAST_ERROR_SQLSTATE", "ON_ERROR_ROLLBACK",
                     "ON_ERROR_STOP", "PORT", "PROMPT1", "PROMPT2", "PROMPT3", "QUIET", "ROW_COUNT", "SERVER_VERSION_NAME",
                     "SERVER_VERSION_NUM", "SHELL_ERROR", "SHELL_EXIT_CODE", "SHOW_ALL_RESULTS", "SHOW_CONTEXT",
                     "SINGLELINE", "SINGLESTEP", "SQLSTATE", "USER", "VERBOSITY", "VERSION", "VERSION_NAME", "VERSION_NUM",
                     "WATCH_INTERVAL"}
        vars_ok = set(v for v in (sys.argv[sys.argv.index("--vars") + 1].split(",") if "--vars" in sys.argv else []) if v)
        assigned, prefixes, has_gset, star = set(), set(), False, False
        lines = raw.splitlines()
        CONTROL = {"ON_ERROR_STOP", "ON_ERROR_ROLLBACK", "AUTOCOMMIT", "VERBOSITY", "SINGLELINE", "SINGLESTEP"}
        for line in lines:
            cm = re.match(r"\s*\\(set|unset)\s+([A-Za-z_][A-Za-z0-9_]*)", line)
            if cm and cm.group(2).upper() in CONTROL:
                print("changing psql control variable %s is not allowed (the kit relies on it)" % cm.group(2))
                return 2
        for line in lines:
            st = line.lstrip()
            m = re.match(r"\\(set|getenv)\s+([A-Za-z_][A-Za-z0-9_]*)(\s+(.*))?$", st)
            # a \\set to a plain value (e.g. the "\\if :{?n} \\else \\set n 1000 \\endif" default) is safe;
            # \\set from another variable (:x, backticks …) and \\getenv are not
            if m and (m.group(1) == "getenv" or not re.fullmatch(r"[A-Za-z0-9_.+-]*", (m.group(4) or "").strip())):
                assigned.add(m.group(2))
            elif m:
                vars_ok.add(m.group(2))   # plain \\set value: as safe as a validated -v
            gm = re.search(r"\\gset(\s+([A-Za-z_][A-Za-z0-9_]*))?", line)
            if gm:
                has_gset = True
                if gm.group(2):
                    prefixes.add(gm.group(2))
        if has_gset:
            body = "\n".join(l for l in lines if not l.lstrip().startswith("\\"))
            idents = set(re.findall(r'"([^"]*)"', body))
            stripped = strip(body)
            idents |= {w for w in re.findall(r"(?<![:A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*", stripped)}
            idents |= {w.lower() for w in idents}
            star = "*" in stripped
            assigned |= idents | {p + w for p in prefixes for w in idents}
        sql_only = strip("\n".join(l for l in lines if not l.lstrip().startswith("\\")))
        for vm in re.finditer(r"(?<![:A-Za-z0-9_]):([A-Za-z_][A-Za-z0-9_]*)", sql_only):
            n = vm.group(1)
            if n not in vars_ok or n in PSQL_VARS or n in assigned or star:
                print("bare :%s in SQL is not provably safe (psql re-reads its value as input); use :'%s', or pass it "
                      "with -v and do not assign it in the script" % (n, n))
                return 4
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
                return 4
            if st.startswith("\\"):
                cmd = re.match(r"\\([A-Za-z!?]*)", st).group(1)
                if cmd not in allowed:
                    print("psql meta-command not allowed: " + st[:60])
                    return 4
            elif not re.search(r"\\gset(\s+[A-Za-z_][A-Za-z0-9_]*)?\s*$", line):
                print("backslash in an SQL line is only allowed as a trailing \\gset: " + st[:60])
                return 4
        return 0
    text = strip(raw)
    # a bare :name is re-read by psql as input (e.g. :LAST_ERROR_MESSAGE after a crafted error): never allowed here
    vm = re.search(r"(?<![:A-Za-z0-9_]):([A-Za-z_][A-Za-z0-9_]*)", text)
    if vm:
        print("bare psql variable :%s is not allowed" % vm.group(1))
        return 4
    if "\\" in text:
        line = next(l for l in text.splitlines() if "\\" in l)
        print("psql meta-command: " + line.strip()[:80])
        return 4
    dropped = drop_atomic(text)
    if dropped is None:
        print("BEGIN ATOMIC without a matching END")
        return 2
    for stmt in dropped.split(";"):
        s = stmt.strip()
        if TX.match(s):
            print(s.splitlines()[0][:80])
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
