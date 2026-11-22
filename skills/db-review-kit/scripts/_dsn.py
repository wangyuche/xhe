#!/usr/bin/env python3
"""DSN helper for db-review-kit (stdlib only; run with python3 -I).

Commands:
  guard <port> <dsn>...      every DSN must be postgres://…@127.0.0.1:<port>/… with no host overrides
  internal <dsn>             rewrite host:port to 127.0.0.1:5432 (address inside the container)
  opts <dsn> <options>       prepend libpq options (kit defaults first, so options already in the DSN win)
  mask <dsn>                 replace the password with ***
  field <dsn> user|db|port   print one component
  build <user> <pw> <port> <db> [<options>]   build a DSN
Exit codes: 0 ok, 2 usage, 4 guard failure.
"""
import sys
import urllib.parse as up

FORBIDDEN_PARAMS = {"host", "hostaddr", "port", "service", "servicefile", "passfile", "dbname", "user"}


class DsnError(Exception):
    pass


def split_query(q):
    # libpq URIs only percent-decode; '+' stays literal, so parse_qsl (which maps '+' to ' ') is not used.
    out = []
    for part in q.split("&") if q else []:
        if part == "":
            continue
        k, _, v = part.partition("=")
        out.append((up.unquote(k), up.unquote(v)))
    return out


def join_query(pairs):
    return "&".join(up.quote(k, safe="") + "=" + up.quote(v, safe="") for k, v in pairs)


def parse(dsn):
    p = up.urlsplit(dsn)
    if p.scheme not in ("postgres", "postgresql"):
        raise DsnError("not a postgres:// URL")
    hostport = p.netloc.rsplit("@", 1)[-1]
    if "," in hostport:
        raise DsnError("multiple hosts are not allowed")
    try:
        port = p.port
    except ValueError:
        raise DsnError("invalid port")
    return p, p.hostname or "", port, split_query(p.query)


def guard_one(expected_port, dsn):
    p, host, port, q = parse(dsn)
    bad = sorted({k for k, _ in q if k.lower() in FORBIDDEN_PARAMS})
    if bad:
        raise DsnError("query parameter overrides connection target: " + ",".join(bad))
    if host != "127.0.0.1":
        raise DsnError("host is %r, must be 127.0.0.1" % host)
    if port != expected_port:
        raise DsnError("port is %s, must be this container's port %s" % (port, expected_port))
    db = p.path.lstrip("/")
    if not db:
        raise DsnError("database name missing")
    return "host=%s port=%s user=%s db=%s" % (host, port, up.unquote(p.username or ""), up.unquote(db))


def with_netloc(p, hostport):
    userinfo = p.netloc.rsplit("@", 1)[0] + "@" if "@" in p.netloc else ""
    return p._replace(netloc=userinfo + hostport)


def mask(dsn):
    try:
        p = up.urlsplit(dsn)
        if p.password is not None:
            userinfo, _, hostport = p.netloc.rpartition("@")
            user = userinfo.split(":", 1)[0]
            p = p._replace(netloc=user + ":***@" + hostport)
        if p.query:
            q = [(k, "***" if k.lower() == "password" else v) for k, v in split_query(p.query)]
            p = p._replace(query="&".join(up.quote(k, safe="") + "=" + (v if v == "***" else up.quote(v, safe="")) for k, v in q))
        return up.urlunsplit(p)
    except Exception:
        return "<unparsable dsn>"


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[1], argv[2:]
    try:
        if cmd == "guard":
            if len(args) < 2:
                print("usage: guard <port> <dsn>...", file=sys.stderr)
                return 2
            expected = int(args[0])
            rc = 0
            for i, d in enumerate(args[1:], 1):
                try:
                    print("guard ok #%d %s" % (i, guard_one(expected, d)))
                except DsnError as e:
                    print("guard FAIL #%d %s: %s" % (i, mask(d), e))
                    rc = 4
            return rc
        if cmd == "internal":
            p, _, _, _ = parse(args[0])
            print(up.urlunsplit(with_netloc(p, "127.0.0.1:5432")))
            return 0
        if cmd == "opts":
            p, _, _, q = parse(args[0])
            extra = args[1]
            existing = [v for k, v in q if k == "options"]
            rest = [(k, v) for k, v in q if k != "options"]
            merged = " ".join([extra] + existing).strip()
            print(up.urlunsplit(p._replace(query=join_query(rest + [("options", merged)]))))
            return 0
        if cmd == "nopass":
            p, _, _, q = parse(args[0])
            userinfo, _, hostport = p.netloc.rpartition("@")
            user = userinfo.split(":", 1)[0]
            rest = [(k, v) for k, v in q if k.lower() != "password"]
            print(up.urlunsplit(p._replace(netloc=(user + "@" if user else "") + hostport, query=join_query(rest))))
            return 0
        if cmd == "mask":
            print(mask(args[0]))
            return 0
        if cmd == "field":
            p, host, port, q = parse(args[0])
            f = args[1]
            val = {"user": up.unquote(p.username or ""), "db": up.unquote(p.path.lstrip("/")),
                   "password": up.unquote(p.password or "") or next((v for k, v in q if k.lower() == "password"), ""),
                   "port": str(port or ""), "host": host}.get(f)
            if val is None:
                print("unknown field " + f, file=sys.stderr)
                return 2
            print(val)
            return 0
        if cmd == "build":
            user, pw, port, db = args[:4]
            q = [("sslmode", "disable")]
            if len(args) > 4 and args[4]:
                q.append(("options", args[4]))
            print("postgres://%s:%s@127.0.0.1:%s/%s?%s" % (
                up.quote(user, safe=""), up.quote(pw, safe=""), int(port), up.quote(db, safe=""), join_query(q)))
            return 0
    except DsnError as e:
        print("dsn error: %s" % e, file=sys.stderr)
        return 4
    except (IndexError, ValueError) as e:
        print("usage error: %s" % e, file=sys.stderr)
        return 2
    print("unknown command " + cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
