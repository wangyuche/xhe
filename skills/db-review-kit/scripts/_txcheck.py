#!/usr/bin/env python3
"""Exit 1 if the SQL on stdin contains transaction control at the start of a statement (or a psql meta-command).

Dollar-quoted bodies ($$…$$, $tag$…$tag$), string literals, quoted identifiers and comments are removed first,
so BEGIN / END inside plpgsql functions, DO blocks and CASE … END do not count. Prints the offending statement.
"""
import re
import sys

TX = re.compile(r"^(COMMIT|END|ROLLBACK|ABORT|BEGIN|START\s+TRANSACTION|SAVEPOINT|RELEASE|PREPARE\s+TRANSACTION)\b", re.I)


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
        if m:
            tag = m.group(0)
            j = sql.find(tag, i + len(tag))
            i = n if j < 0 else j + len(tag)
            out.append(" '' ")
            continue
        if c in ("'", '"'):
            j = i + 1
            while j < n:
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


def main():
    text = strip(sys.stdin.read())
    for line in text.splitlines():
        if line.lstrip().startswith("\\"):
            print("psql meta-command: " + line.strip()[:80])
            return 1
    for stmt in text.split(";"):
        s = stmt.strip()
        if TX.match(s):
            print(s.splitlines()[0][:80])
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
