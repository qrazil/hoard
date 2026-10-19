#!/usr/bin/env bash
# End-to-end test: a real hoard server on a free port, a temporary config and
# repository root, and the real `git` client. A port of orogit's tests/e2e.oro.
#
#     HOARD_BIN=/path/to/hoard bash tests/e2e.sh
#
# Prints `ok   <name>` or `FAIL <name>` per check (and `skip <name>` for a
# check this machine cannot make, e.g. RSS without /proc), then
# `N passed, M failed` last; exits 1 if any check failed.
#
# Needs bash (3.2 is enough: no associative arrays, no mapfile), git and
# python3. HTTP-level checks go through `python3 -I`, which sends a request
# target exactly as written; clone and push use the real git client.
set -u

if [ -z "${HOARD_BIN:-}" ]; then
    echo "HOARD_BIN is not set -- point it at a built hoard binary" >&2
    exit 2
fi
case $HOARD_BIN in
    /*) ;;
    *) HOARD_BIN="$(pwd)/$HOARD_BIN" ;;
esac
if [ ! -x "$HOARD_BIN" ]; then
    echo "HOARD_BIN=$HOARD_BIN is not an executable" >&2
    exit 2
fi
for tool in git python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is required" >&2
        exit 2
    fi
done

T=$(mktemp -d "${TMPDIR:-/tmp}/hoard-e2e.XXXXXX")
T=$(cd "$T" && pwd -P)
SPID=""
cleanup() {
    if [ -n "$SPID" ]; then
        kill "$SPID" 2>/dev/null
        wait "$SPID" 2>/dev/null
    fi
    rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

SRV="$T/srv"
CFG="$SRV/hoard.json"
WORK="$T/work"
mkdir -p "$T/home" "$WORK" "$SRV"

# An isolated git: no system or user config, no credential helper, no
# prompts. Without this a credential cache on the machine running the test
# would quietly log git in as someone.
export HOME="$T/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.com
export GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.com
export LC_ALL=C
unset GIT_ASKPASS SSH_ASKPASS GIT_DIR GIT_WORK_TREE HOARD_CONFIG 2>/dev/null

RAW='<script>alert(1)</script>'
ESCAPED='&lt;script&gt;alert(1)&lt;/script&gt;'
BIG_BYTES=104857600
HAVE_PROC=0
[ -r /proc/self/status ] && HAVE_PROC=1

PASSED=0
FAILED=0
FAILED_NAMES=""

# check NAME STATUS [DETAIL]: STATUS 0 is a pass.
check() {
    if [ "$2" = 0 ]; then
        PASSED=$((PASSED + 1))
        printf 'ok   %s\n' "$1"
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES="$FAILED_NAMES
  failed: $1"
        printf 'FAIL %s\n' "$1"
        if [ -n "${3:-}" ]; then
            printf '%s\n' "$3" | sed 's/^/       /'
        fi
    fi
}
skip() { printf 'skip %s (%s)\n' "$1" "$2"; }
note() { printf '      %s\n' "$1"; }
section() { printf '\n== %s  [%s s]\n' "$1" "$SECONDS"; }

# --- python helpers ------------------------------------------------------------

cat >"$T/helper.py" <<'PYEOF'
import base64, http.client, os, socket, subprocess, sys, threading, time


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
    s.close()


def request(base, method, target, headers, body, timeout=60):
    host, port = base.rsplit(":", 1)
    c = http.client.HTTPConnection(host, int(port), timeout=timeout)
    c.putrequest(method, target, skip_accept_encoding=True)
    c.putheader("Connection", "close")
    for k, v in headers:
        c.putheader(k, v)
    if body is not None:
        c.putheader("Content-Length", str(len(body)))
    c.endheaders(body)
    r = c.getresponse()
    data = r.read()
    hs = [(k.lower(), v) for k, v in r.getheaders()]
    c.close()
    return r.status, hs, data


# req BASE METHOD TARGET HFILE BFILE [-u user:pass] [-H 'k: v'] [-d body]
def req(argv):
    base, method, target, hfile, bfile = argv[:5]
    headers, body = [], None
    rest = argv[5:]
    i = 0
    while i < len(rest):
        flag, val = rest[i], rest[i + 1]
        i += 2
        if flag == "-u":
            headers.append(("Authorization", "Basic " + base64.b64encode(val.encode()).decode()))
        elif flag == "-H":
            k, v = val.split(":", 1)
            headers.append((k.strip(), v.strip()))
        elif flag == "-d":
            body = val.encode()
    try:
        status, hs, data = request(base, method, target, headers, body)
    except Exception as e:
        status, hs, data = 0, [], ("error: %r" % e).encode()
    with open(hfile, "w") as f:
        for k, v in hs:
            f.write("%s: %s\n" % (k, v))
    with open(bfile, "wb") as f:
        f.write(data)
    print(status)


def rss_kb(pid):
    try:
        with open("/proc/%s/status" % pid) as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except (OSError, ValueError):
        pass
    return -1


def sampler(pid, stop, res):
    while not stop.is_set():
        k = rss_kb(pid)
        if k > res["rss_max"]:
            res["rss_max"] = k
        res["rss_samples"] += 1
        time.sleep(0.05)


# sampled PID OUTFILE CMD...: run CMD, sampling PID's RSS meanwhile.
def sampled(argv):
    pid, out = argv[0], argv[1]
    res = {"rss_max": -1, "rss_samples": 0}
    stop = threading.Event()
    th = threading.Thread(target=sampler, args=(pid, stop, res))
    th.start()
    t = time.monotonic()
    p = subprocess.run(argv[2:], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    secs = time.monotonic() - t
    stop.set()
    th.join()
    err = p.stderr.decode("utf-8", "replace").strip().splitlines()
    with open(out, "w") as f:
        f.write("rc %d\nsecs %.2f\nrss_max %d\nrss_samples %d\nerr %s\n" % (
            p.returncode, secs, res["rss_max"], res["rss_samples"], err[-1] if err else ""))


# Whether a `git receive-pack` serving big.git is running: the backend runs it
# with the CGI environment it inherited, so the repository is recognised by
# PATH_INFO in its environment.
def receiving():
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % name, "rb") as f:
                cmd = f.read()
            if b"receive-pack" in cmd and b"http-backend" not in cmd:
                with open("/proc/%s/environ" % name, "rb") as f:
                    if b"PATH_INFO=/big.git/git-receive-pack" in f.read():
                        return True
        except OSError:
            pass
    return False


# watch STOPFILE OUTFILE T0: record when receive-pack for big.git is alive.
def watch(argv):
    stop, out, t0 = argv[0], argv[1], float(argv[2])
    first = last = -1.0
    while not os.path.exists(stop):
        if receiving():
            now = time.time() - t0
            if first < 0:
                first = now
            last = now
        time.sleep(0.02)
    with open(out, "w") as f:
        f.write("first %.3f\nlast %.3f\n" % (first, last))


def prober(base, path, stop, rec, t0):
    while not stop.is_set():
        t = time.monotonic()
        ok = False
        try:
            status, _, _ = request(base, "GET", path, [], None, timeout=30)
            ok = status == 200
        except Exception:
            pass
        rec.append((time.time() - t0, time.monotonic() - t, ok))
        time.sleep(0.05)


def cloner(url, work, stop, rec, t0):
    n = 0
    while not stop.is_set():
        t = time.monotonic()
        d = os.path.join(work, "during%d" % n)
        p = subprocess.run(["git", "clone", "-q", url, d], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        rec.append((time.time() - t0, p.returncode, time.monotonic() - t))
        subprocess.run(["rm", "-rf", d])
        n += 1
        time.sleep(0.05)


def ms(s):
    return "%.0f ms" % (s * 1000)


# bigpush BASE PID REPO_DIR PUSH_URL CLONE_URL WORK OUTFILE HELPER
def bigpush(argv):
    base, pid, bw, push_url, clone_url, work, out, helper = argv
    have_proc = os.path.isdir("/proc") and rss_kb(pid) > 0
    res = {"rss_max": -1, "rss_samples": 0}
    baseline = rss_kb(pid)
    stop = threading.Event()
    t0 = time.time()
    stopfile = os.path.join(work, "bigpush.stop")
    watchfile = os.path.join(work, "bigpush.watch")
    watcher = None
    if have_proc:
        watcher = subprocess.Popen([sys.executable, "-I", helper, "watch", stopfile, watchfile, repr(t0)])
    ref_rec, idx_rec, clones = [], [], []
    threads = [
        threading.Thread(target=sampler, args=(pid, stop, res)),
        threading.Thread(target=prober, args=(base, "/pub.git/info/refs?service=git-upload-pack", stop, ref_rec, t0)),
        threading.Thread(target=prober, args=(base, "/", stop, idx_rec, t0)),
        threading.Thread(target=cloner, args=(clone_url, work, stop, clones, t0)),
    ]
    for th in threads:
        th.start()
    p = subprocess.run(["git", "push", push_url, "main"], cwd=bw, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    push_secs = time.time() - t0
    stop.set()
    open(stopfile, "w").close()
    for th in threads:
        th.join()
    first = last = -1.0
    if watcher is not None:
        watcher.wait()
        with open(watchfile) as f:
            vals = dict(line.split() for line in f)
        first, last = float(vals["first"]), float(vals["last"])
    seen = first >= 0
    inside = [c for c in clones if seen and first <= c[0] <= last]
    err = p.stderr.decode("utf-8", "replace").strip().splitlines()
    idx_lat = sorted(r[1] for r in idx_rec)
    ref_lat = sorted(r[1] for r in ref_rec)
    notes = []
    notes.append("push took %.1f s end to end" % push_secs)
    notes.append("server RSS: %d kB before, %d kB peak during the push (%d samples)" % (baseline, res["rss_max"], res["rss_samples"]))
    if seen:
        notes.append("receive-pack for big.git was running from %.2f s to %.2f s into the push" % (first, last))
    for label, lat in (("ref-advertisement (starts git http-backend)", ref_lat), ("index page (served inside the server)", idx_lat)):
        if lat:
            notes.append("%s: %d requests, median %s, max %s" % (label, len(lat), ms(lat[len(lat) // 2]), ms(lat[-1])))
    if inside:
        secs = sorted(c[2] for c in inside)
        notes.append("clones during the receive: %d, median %s, max %s" % (len(secs), ms(secs[len(secs) // 2]), ms(secs[-1])))
    with open(out, "w") as f:
        f.write("push_rc %d\n" % p.returncode)
        f.write("push_err %s\n" % (err[-1] if err else "-"))
        f.write("have_proc %d\n" % (1 if have_proc else 0))
        f.write("rss_max %d\n" % res["rss_max"])
        f.write("seen %d\n" % (1 if seen else 0))
        f.write("clones %d\n" % len(clones))
        f.write("clones_failed %d\n" % len([c for c in clones if c[1] != 0]))
        f.write("inside %d\n" % len(inside))
        f.write("inside_failed %d\n" % len([c for c in inside if c[1] != 0]))
        f.write("ref_n %d\n" % len(ref_rec))
        f.write("ref_err %d\n" % len([r for r in ref_rec if not r[2]]))
        f.write("idx_n %d\n" % len(idx_rec))
        f.write("idx_err %d\n" % len([r for r in idx_rec if not r[2]]))
        f.write("idx_max_ms %d\n" % (int(idx_lat[-1] * 1000) if idx_lat else -1))
        for n in notes:
            f.write("note %s\n" % n)


# config_set FILE KEY JSON: set a top-level key by hand, as an admin would.
def config_set(argv):
    import json
    path, key, value = argv
    with open(path) as f:
        cfg = json.load(f)
    cfg[key] = json.loads(value)
    with open(path, "w") as f:
        f.write(json.dumps(cfg, indent=2) + "\n")


# config_get FILE EXPR: print a value from the config (EXPR is a dotted path).
def config_get(argv):
    import json
    with open(argv[0]) as f:
        v = json.load(f)
    for part in argv[1].split(".") if argv[1] else []:
        v = v.get(part) if isinstance(v, dict) else None
    print(json.dumps(v, sort_keys=True))


def mode(argv):
    print("%o" % (os.stat(argv[0]).st_mode & 0o7777))


def half(argv):
    with open(argv[0], "rb") as f:
        data = f.read()
    with open(argv[1], "wb") as f:
        f.write(data[: len(data) // 2])


def mono(argv):
    print("%.3f" % time.time())


# download BASE TARGET OUT: stream a GET to OUT; exit 0 only on a 200.
def download(argv):
    base, target, out = argv
    host, port = base.rsplit(":", 1)
    c = http.client.HTTPConnection(host, int(port), timeout=120)
    c.request("GET", target)
    r = c.getresponse()
    with open(out, "wb") as f:
        while True:
            piece = r.read(65536)
            if not piece:
                break
            f.write(piece)
    c.close()
    sys.exit(0 if r.status == 200 else 1)


# abort BASE TARGET: read the head and about 1 MB of the body, then hang up.
def abort(argv):
    base, target = argv
    host, port = base.rsplit(":", 1)
    c = http.client.HTTPConnection(host, int(port), timeout=60)
    c.request("GET", target)
    r = c.getresponse()
    r.read(1 << 20)
    c.sock.close()
    print(r.status)


# archiving: how many `git archive` processes are running.
def archiving(argv):
    n = 0
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % name, "rb") as f:
                if b"\0archive\0--format=tar.gz" in f.read():
                    n += 1
        except OSError:
            pass
    print(n)


cmd = sys.argv[1]
globals()[cmd](sys.argv[2:]) if cmd != "free_port" else free_port()
PYEOF

py() { python3 -I "$T/helper.py" "$@"; }

# hc ARGS...: run hoard against the test config; RC, $T/cli.out, $T/cli.err.
hc() {
    "$HOARD_BIN" --config "$CFG" "$@" </dev/null >"$T/cli.out" 2>"$T/cli.err"
    RC=$?
}
# hc_in INPUT ARGS...: the same with INPUT on stdin.
hc_in() {
    local input=$1
    shift
    printf '%s\n' "$input" | "$HOARD_BIN" --config "$CFG" "$@" >"$T/cli.out" 2>"$T/cli.err"
    RC=$?
}
err1() { tr '\n' ' ' <"$T/cli.err" | sed 's/ *$//'; }

# req METHOD TARGET [-u user:pass] [-H 'k: v'] [-d body]: ST, $T/r.h, $T/r.b.
req() {
    local method=$1 target=$2
    shift 2
    ST=$(py req "$BASE" "$method" "$target" "$T/r.h" "$T/r.b" "$@")
}
get() { req GET "$@"; }
body_has() { grep -F -q -- "$1" "$T/r.b"; }
header() { sed -n "s/^$1: //p" "$T/r.h" | head -n 1; }

g() { git "$@" >/dev/null 2>"$T/git.err"; }
gerr() { tr '\n' ' ' <"$T/git.err" | sed 's/ *$//'; }
glast() { grep -v '^ *$' "$T/git.err" | tail -n 1; }

# commit_file DIR REL CONTENT MESSAGE: prints the new HEAD.
commit_file() {
    local dir=$1 rel=$2 data=$3 msg=$4
    mkdir -p "$(dirname "$dir/$rel")"
    printf '%s' "$data" >"$dir/$rel"
    git -C "$dir" add -- "$rel" >/dev/null 2>&1
    git -C "$dir" commit -q -m "$msg" >/dev/null 2>&1
    git -C "$dir" rev-parse HEAD
}
bare() { printf '%s' "$SRV/repos/$1.git"; }
refs_of() { git --git-dir "$(bare "$1")" for-each-ref 2>/dev/null; }

url() { printf 'http://%s%s' "$BASE" "$1"; }
ALICE="alice:alice-pw"
BOB_URL="bob:bob%20pw%20with%20spaces"
BOB="bob:bob pw with spaces"
CAROL="carol:carol-pw"
aurl() { printf 'http://%s@%s%s' "$1" "$BASE" "$2"; }

# --- setup ---------------------------------------------------------------------

section "setup"
hc -init --listen 127.0.0.1:8789
[ "$RC" = 0 ] && [ -f "$CFG" ]
check "init creates the config" $? "rc $RC: $(err1)"
[ -d "$SRV/repos" ] && [ -d "$SRV/pages" ]
check "init creates repos/ and pages/ beside the config" $?
HOOK="$SRV/hooks/post-receive"
[ -f "$HOOK" ] && [ -x "$HOOK" ] && [ "$(head -n 1 "$HOOK")" = "#!/bin/sh" ]
check "init writes an executable sh post-receive hook in <config dir>/hooks/" $? "$(ls -l "$HOOK" 2>&1 | head -1)"
grep -F -q -- "'$HOARD_BIN' --config '$CFG' -regen --hook" "$HOOK"
check "the hook runs this binary's -regen --hook against this config" $? "$(sed -n 5p "$HOOK")"
[ "$(py mode "$CFG")" = 600 ]
check "init's config is mode 0600" $? "mode $(py mode "$CFG")"
hc -init
[ "$RC" = 1 ] && grep -q "already exists" "$T/cli.err"
check "a second init refuses to overwrite the config (exit 1)" $? "rc $RC: $(err1)"
hc -init --oro /usr/bin/oro
[ "$RC" = 64 ]
check "there is no --oro option (usage error, exit 64)" $? "rc $RC: $(err1)"
[ "$(py config_get "$CFG" oro)" = null ]
check "the config has no oro key" $?

for pair in "alice:alice-pw" "bob:bob pw with spaces" "carol:carol-pw"; do
    user=${pair%%:*}
    pw=${pair#*:}
    hc_in "$pw" -adduser "$user"
    check "adduser $user (password on stdin)" $RC "$(err1)"
done
hc_in "alice-pw" -adduser alice
[ "$RC" = 1 ] && grep -q "already exists" "$T/cli.err"
check "adduser refuses an existing user (exit 1)" $? "rc $RC: $(err1)"
hc_in "" -adduser emptypw
[ "$RC" = 1 ]
check "adduser refuses an empty password" $? "rc $RC: $(err1)"
for spec in "pub --public" "priv" "big --public"; do
    # shellcheck disable=SC2086
    hc -addrepo $spec
    check "addrepo $spec" $RC "$(err1)"
done
for spec in "pub alice write" "priv alice write" "big alice write" "priv bob read" "pub carol read"; do
    # shellcheck disable=SC2086
    hc -grant $spec
    check "grant $spec" $RC "$(err1)"
done
hashes=$(py config_get "$CFG" users | grep -o '"\$6\$' | wc -l | tr -d ' ')
plain=0
for pw in alice-pw "bob pw with spaces" carol-pw; do
    grep -F -q -- "$pw" "$CFG" && plain=1
done
[ "$hashes" = 3 ] && [ "$plain" = 0 ]
check "config holds SHA-512-crypt hashes, no plaintext" $? "$hashes \$6\$ hashes, plaintext found: $plain"
[ "$(py mode "$CFG")" = 600 ]
check "the config stays mode 0600 after saves" $?
[ "$(git --git-dir "$(bare pub)" config core.hooksPath)" = "$SRV/hooks" ] && [ "$(git --git-dir "$(bare pub)" config hoard.repo)" = pub ]
check "addrepo points core.hooksPath at hooks/ and sets hoard.repo" $?
[ ! -e "$CFG.lock" ]
check "no admin lock is left behind after the setup commands" $?

# --- the server ------------------------------------------------------------------

PORT=$(py free_port)
BASE="127.0.0.1:$PORT"
WORKERS=8
# Every git the server (and the hook it runs) starts goes through this
# wrapper, which logs its arguments: the tarball checks look in the log to
# show that a refused tag name never reached git.
REAL_GIT=$(command -v git)
mkdir -p "$T/bin"
cat >"$T/bin/git" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >>"$T/git-calls.log"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$T/bin/git"
env -i PATH="$T/bin:$PATH" HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 \
    "$HOARD_BIN" --config "$CFG" -serve --listen "$BASE" --workers "$WORKERS" \
    >"$T/server.out" 2>"$T/server.err" </dev/null &
SPID=$!
for _ in $(seq 1 100); do
    grep -q "listening" "$T/server.err" 2>/dev/null && break
    kill -0 "$SPID" 2>/dev/null || break
    sleep 0.1
done
ANNOUNCE=$(grep "listening" "$T/server.err" | head -n 1)
[ "$ANNOUNCE" = "hoard: listening on http://$BASE/ with $WORKERS workers" ]
check "server starts and announces its address and workers on stderr" $? "got: $(head -c 300 "$T/server.err")"
if ! kill -0 "$SPID" 2>/dev/null; then
    echo "the server is not running; giving up" >&2
    printf '\n%d passed, %d failed\n' "$PASSED" "$((FAILED + 1))"
    exit 1
fi

# --- 1-4: clone and push permissions -------------------------------------------------

SECONDS_AT_START=$SECONDS
section "3. push with a writer's credentials"
W="$WORK/w1"
git init -q -b main "$W"
FIRST=$(commit_file "$W" README.md "hoard test repository
" "initial commit")
g -C "$W" push "$(aurl "$ALICE" /pub.git)" main
check "alice pushes to pub" $? "$(glast)"
SECOND=$(commit_file "$W" notes.txt "second
" "second commit")
g -C "$W" push "$(aurl "$ALICE" /pub.git)" main
check "alice pushes a second commit" $? "$(glast)"
BMAIN=$(git --git-dir "$(bare pub)" rev-parse refs/heads/main 2>/dev/null)
[ "$BMAIN" = "$SECOND" ]
check "the pushed commits are in the bare repository" $? "bare main $BMAIN, local $SECOND"
git --git-dir "$(bare pub)" cat-file -e "$FIRST^{commit}" 2>/dev/null
check "the first commit is there too" $?
g -C "$W" push "$(aurl "$ALICE" /priv.git)" main
check "alice pushes to priv" $? "$(glast)"

section "1. anonymous clone of a public repository"
g clone -q "$(url /pub.git)" "$WORK/c1"
check "anonymous clone of pub succeeds" $? "$(gerr)"
[ "$(git -C "$WORK/c1" rev-parse HEAD 2>/dev/null)" = "$SECOND" ]
check "the clone has the pushed commit" $?

section "2. private repository"
get "/priv.git/info/refs?service=git-upload-pack"
[ "$ST" = 401 ]
check "anonymous ref advertisement of priv is 401" $? "status $ST"
CH=$(header www-authenticate)
case $CH in 'Basic realm="hoard"'*) true ;; *) false ;; esac
check '401 carries WWW-Authenticate: Basic realm="hoard"' $? "$CH"
g clone -q "$(url /priv.git)" "$WORK/c2"
[ $? != 0 ]
check "anonymous git clone of priv is refused" $? "$(gerr)"
get /priv/
[ "$ST" = 401 ]
check "anonymous request for priv's pages is 401" $? "status $ST"
g clone -q "$(aurl "$BOB_URL" /priv.git)" "$WORK/c3"
check "bob (reader) clones priv" $? "$(gerr)"
[ -f "$WORK/c3/README.md" ]
check "bob's clone has the README" $?
get "/priv.git/info/refs?service=git-upload-pack" -u "$CAROL"
[ "$ST" = 404 ]
check "carol (no grant) gets 404 for priv, not a hint it exists" $? "status $ST"
get /priv/ -u "$CAROL"
[ "$ST" = 404 ]
check "carol (no grant) gets 404 for priv's pages too" $? "status $ST"
get "/nosuch.git/info/refs?service=git-upload-pack" -u "$CAROL"
[ "$ST" = 404 ]
check "a repository that does not exist is the same 404" $? "status $ST"

section "4. refused pushes leave the repository unchanged"
BEFORE_PUB=$(refs_of pub)
BEFORE_PRIV=$(refs_of priv)
commit_file "$W" evil.txt "should never arrive
" "unauthorised commit" >/dev/null
g -C "$W" push "$(url /pub.git)" main
rc=$?
[ $rc != 0 ] && grep -q "could not read Username" "$T/git.err"
check "anonymous push to public pub is refused (401 prompt)" $? "$(glast)"
g -C "$W" push "$(aurl alice:wrong /pub.git)" main
rc=$?
[ $rc != 0 ] && grep -q "Authentication failed" "$T/git.err"
check "push with a wrong password is refused (401)" $? "$(glast)"
g -C "$W" push "$(aurl "$CAROL" /pub.git)" main
rc=$?
[ $rc != 0 ] && grep -q "403" "$T/git.err"
check "push by carol (reader of pub) is refused with 403" $? "$(glast)"
g -C "$W" push "$(aurl "$BOB_URL" /priv.git)" main
rc=$?
[ $rc != 0 ] && grep -q "403" "$T/git.err"
check "push by bob (reader of priv) is refused with 403" $? "$(glast)"
# Both places a push shows up are checked on their own.
get "/priv.git/info/refs?service=git-receive-pack" -u "$BOB"
[ "$ST" = 403 ]
check "GET info/refs?service=git-receive-pack as a reader is 403" $? "status $ST"
req POST /priv.git/git-receive-pack -u "$BOB" -d 0000
[ "$ST" = 403 ]
check "POST git-receive-pack as a reader is 403" $? "status $ST"
req POST /pub.git/git-receive-pack -d 0000
[ "$ST" = 401 ]
check "anonymous POST git-receive-pack is 401" $? "status $ST"
get "/pub.git/info/refs?service=git-receive-pack&service=git-upload-pack"
[ "$ST" = 200 ] || [ "$ST" = 401 ]
check "a repeated service= parameter cannot smuggle a push past the check" $? "status $ST"
req POST /pub.git/git-receive-pack -u "$CAROL" -d 0000
[ "$ST" = 403 ]
check "POST git-receive-pack by a reader of a public repository is 403" $? "status $ST"
[ "$(refs_of pub)" = "$BEFORE_PUB" ]
check "pub's refs are unchanged" $?
[ "$(refs_of priv)" = "$BEFORE_PRIV" ]
check "priv's refs are unchanged" $?
git -C "$W" reset -q --hard HEAD~1

# --- 7-8: pages ---------------------------------------------------------------------

section "7. pages follow pushes (post-receive hook)"
SHA=$(commit_file "$W" docs/guide.txt "a guide
" "add the guide")
g -C "$W" push "$(aurl "$ALICE" /pub.git)" main
check "push for the pages test" $? "$(glast)"
get /pub/log.html
[ "$ST" = 200 ]
check "log.html is served" $? "status $ST"
body_has "$SHA"
check "log.html lists the new commit (rebuilt by the hook)" $?
get "/pub/commit/$SHA.html"
[ "$ST" = 200 ] && body_has "add the guide"
check "the new commit has its own page" $? "status $ST"
body_has "+a guide"
check "the commit page shows the diff" $?
get /pub/
SUMMARY_CSP=$(header content-security-policy)
SUMMARY_NOSNIFF=$(header x-content-type-options)
SUMMARY_CACHE=$(header cache-control)
[ "$ST" = 200 ] && body_has "hoard test repository"
check "the summary shows the README" $? "status $ST"
get /pub/file/docs.d/guide.txt.html
[ "$ST" = 200 ] && body_has "a guide"
check "a file in a subdirectory has a page" $? "status $ST"
case $SUMMARY_CSP in *"default-src 'none'"*) true ;; *) false ;; esac
check "pages are sent with a no-script CSP" $? "$SUMMARY_CSP"
[ "$SUMMARY_NOSNIFF" = nosniff ]
check "pages are sent with X-Content-Type-Options: nosniff" $? "$SUMMARY_NOSNIFF"
[ -z "$SUMMARY_CACHE" ]
check "public pages carry no private cache-control" $? "$SUMMARY_CACHE"
get /pub
[ "$ST" = 301 ] && [ "$(header location)" = "pub/" ]
check "/pub redirects to /pub/" $? "status $ST, location $(header location)"
get /priv/ -u "$BOB"
[ "$ST" = 200 ]
check "bob can read priv's pages" $? "status $ST"
case $(header cache-control) in *private*no-store*) true ;; *) false ;; esac
check "private pages are sent Cache-Control: private, no-store" $? "$(header cache-control)"
get /
! body_has 'priv/' && body_has 'pub/'
check "anonymous index lists pub, not priv" $?
get / -u "$BOB"
body_has 'priv/'
check "bob's index lists priv" $?
get "/?login"
[ "$ST" = 401 ]
check "/?login asks for credentials (401)" $? "status $ST"

section "8. HTML injection is escaped"
INJ=$(commit_file "$W" "$RAW.txt" "$RAW
" "$RAW")
# A symlink to /etc/passwd, committed without touching the work tree.
BLOB=$(printf '/etc/passwd' | git -C "$W" hash-object -w --stdin)
git -C "$W" update-index --add --cacheinfo "120000,$BLOB,leak"
git -C "$W" commit -q -m "a symlink out of the tree"
g -C "$W" push "$(aurl "$ALICE" /pub.git)" main
check "push of the injection commit" $? "$(glast)"
FHREF="/pub/file/%3Cscript%3Ealert%281%29%3C.d/script%3E.txt.html"
for path in /pub/ /pub/log.html /pub/files.html "/pub/commit/$INJ.html" "$FHREF"; do
    get "$path"
    [ "$ST" = 200 ] && ! body_has "$RAW" && body_has "$ESCAPED"
    check "$path escapes the payload" $? "status $ST"
done
get /pub/file/leak.html
[ "$ST" = 200 ] && body_has "Symbolic link to <code>/etc/passwd</code>" && ! body_has "root:"
check "a symlink's page names its target and does not follow it" $? "status $ST"
LINKS=$(find "$SRV/pages" -type l)
[ -z "$LINKS" ]
check "the generated tree contains no symlinks" $? "$LINKS"

ELAPSED=$((SECONDS - SECONDS_AT_START))
[ "$ELAPSED" -lt 20 ]
check "sections 1-4, 7 and 8 finished without a stalled request (< 20 s)" $? "$ELAPSED s"

section "8b. tag tarballs"
git -C "$W" tag -a v1.0 -m "release 1.0" "$SECOND"
git -C "$W" tag light "$FIRST"
git -C "$W" tag rel/x "$SECOND"
g -C "$W" push "$(aurl "$ALICE" /pub.git)" v1.0 light rel/x
check "alice pushes tags to pub" $? "$(glast)"
g -C "$W" push "$(aurl "$ALICE" /priv.git)" v1.0
check "alice pushes a tag to priv" $? "$(glast)"
get /pub/archive/v1.0.tar.gz
cp "$T/r.b" "$T/pub-v1.0.tar.gz"
[ "$ST" = 200 ] && [ "$(header content-type)" = application/gzip ]
check "GET /pub/archive/v1.0.tar.gz is 200 application/gzip" $? "status $ST, $(header content-type)"
[ "$(header content-disposition)" = 'attachment; filename="pub-v1.0.tar.gz"' ]
check "...named pub-v1.0.tar.gz as an attachment" $? "$(header content-disposition)"
case $(header cache-control) in *immutable*) true ;; *) false ;; esac
check "...cacheable as immutable (public repository)" $? "$(header cache-control)"
git -C "$W" archive --format=tar.gz --prefix=pub-v1.0/ v1.0 >"$T/local-v1.0.tar.gz"
tar tzf "$T/pub-v1.0.tar.gz" >"$T/served.list" 2>/dev/null && tar tzf "$T/local-v1.0.tar.gz" >"$T/local.list" && cmp -s "$T/served.list" "$T/local.list"
check "the tarball lists the same files as a local git archive" $? "$(diff "$T/served.list" "$T/local.list" 2>&1 | head -5)"
tar xzOf "$T/pub-v1.0.tar.gz" pub-v1.0/README.md 2>/dev/null | cmp -s - "$W/README.md"
check "a file in the tarball is byte-identical" $?
! grep -q '^pub-v1.0/docs/' "$T/served.list"
check "the tarball is of the tag, not of the branch tip" $? "$(head -5 "$T/served.list")"
get /pub/archive/light.tar.gz
[ "$ST" = 200 ] && tar tzf "$T/r.b" 2>/dev/null | grep -q '^pub-light/README.md$' && ! tar tzf "$T/r.b" 2>/dev/null | grep -q notes.txt
check "a lightweight tag's tarball is served too" $? "status $ST"
req HEAD /pub/archive/v1.0.tar.gz
[ "$ST" = 200 ] && [ ! -s "$T/r.b" ] && [ "$(header content-type)" = application/gzip ]
check "HEAD of a tarball: 200, the headers, no body" $? "status $ST, $(wc -c <"$T/r.b") bytes"
req POST /pub/archive/v1.0.tar.gz -d x
[ "$ST" = 405 ]
check "POST to a tarball is 405" $? "status $ST"
get /pub/archive/nosuch.tar.gz
[ "$ST" = 404 ]
check "a tag that does not exist is 404" $? "status $ST"
req HEAD /pub/archive/nosuch.tar.gz
[ "$ST" = 404 ]
check "...for HEAD too" $? "status $ST"
get /pub/archive/main.tar.gz
[ "$ST" = 404 ]
check "a branch name is not a tag (404)" $? "status $ST"
get "/pub/archive/$SECOND.tar.gz"
[ "$ST" = 404 ]
check "a commit name is not a tag (404)" $? "status $ST"
get /priv/archive/v1.0.tar.gz
[ "$ST" = 401 ] && ! tar tzf "$T/r.b" >/dev/null 2>&1
check "anonymous request for a private tarball is 401, as for its pages" $? "status $ST"
get /priv/archive/v1.0.tar.gz -u "$CAROL"
CAROL_ST=$ST
get /priv/archive/nosuch.tar.gz -u "$CAROL"
[ "$CAROL_ST" = 404 ] && [ "$ST" = 404 ]
check "carol (no grant) gets the same 404 for a real and a missing private tag" $? "status $CAROL_ST, $ST"
get /priv/archive/v1.0.tar.gz -u "$BOB"
[ "$ST" = 200 ] && tar tzf "$T/r.b" 2>/dev/null | grep -q '^priv-v1.0/README.md$'
check "bob (reader) downloads priv's tarball" $? "status $ST"
case $(header cache-control) in *private*no-store*) true ;; *) false ;; esac
check "...sent Cache-Control: private, no-store" $? "$(header cache-control)"
LONG=$(printf 'a%.0s' $(seq 1 300))
for target in \
    "/pub/archive/..tar.gz" \
    "/pub/archive/%2e%2e.tar.gz" \
    "/pub/archive/v1.0..tar.gz" \
    "/pub/archive/..%2fv1.0.tar.gz" \
    "/pub/archive/-x.tar.gz" \
    "/pub/archive/--output=x.tar.gz" \
    "/pub/archive/--output=%2ftmp%2fhoard-pwned.tar.gz" \
    "/pub/archive/v1.0%5E%7Btree%7D.tar.gz" \
    "/pub/archive/v1.0~1.tar.gz" \
    "/pub/archive/v1.0:README.md.tar.gz" \
    "/pub/archive/%40%7B-1%7D.tar.gz" \
    "/pub/archive/rel/x.tar.gz" \
    "/pub/archive/rel%2fx.tar.gz" \
    "/pub/archive/v1.0%00.tar.gz" \
    "/pub/archive/$LONG.tar.gz" \
    "/pub/archive/.tar.gz" \
    "/pub/archive/v1.0" \
    "/pub/archive/v1.0.zip" \
    "/pub/archive/v1.0.tar.gz/x" \
    "/priv/archive/..%2f..%2fpub%2farchive%2fv1.0.tar.gz"; do
    get "$target"
    [ "$ST" -ge 400 ] && [ "$ST" -lt 500 ] && ! tar tzf "$T/r.b" >/dev/null 2>&1
    check "refused: $target" $? "status $ST"
done
BAD_CALLS=$(grep -E 'refs/tags/([-.]|rel/|[^ ]*\.\.|[^ ]*[~:@]|[^ ]*\^\{tree|a{100})|--output' "$T/git-calls.log" 2>/dev/null)
[ -z "$BAD_CALLS" ] && grep -q 'rev-parse --verify --quiet refs/tags/v1.0^{commit}' "$T/git-calls.log"
check "no refused name reached git (the git log shows only valid tags)" $? "$BAD_CALLS"
[ ! -e /tmp/hoard-pwned.tar.gz ]
check "no --output file was written" $?
get /pub/
[ "$ST" = 200 ] && body_has 'href="archive/v1.0.tar.gz"' && body_has 'href="archive/light.tar.gz"'
check "the summary links each tag's tarball" $? "status $ST"
body_has 'rel/x' && ! body_has 'archive/rel/x'
check "a tag outside the tarball alphabet is listed without a link" $?
get /priv/ -u "$BOB"
body_has 'href="archive/v1.0.tar.gz"'
check "priv's summary links its tag's tarball for bob" $?

# --- 5-6: a large push, memory, and concurrency -----------------------------------------

section "5. a 100 MB binary push streams"
BW="$WORK/big"
git init -q -b main "$BW"
head -c "$BIG_BYTES" /dev/urandom >"$BW/blob.bin"
git -C "$BW" add blob.bin
git -C "$BW" commit -q -m "one hundred megabytes of noise"
note "local commit of the blob done at ${SECONDS} s"

section "6. other clients are served during the push"
py bigpush "$BASE" "$SPID" "$BW" "$(aurl "$ALICE" /big.git)" "$(url /pub.git)" "$WORK" "$T/big.out" "$T/helper.py"
kv() { sed -n "s/^$1 //p" "$T/big.out" | head -n 1; }
sed -n 's/^note //p' "$T/big.out" | while IFS= read -r line; do note "$line"; done
[ "$(kv push_rc)" = 0 ]
check "the 100 MB push succeeds" $? "$(kv push_err)"
RSS_MAX=$(kv rss_max)
if [ "$(kv have_proc)" = 1 ]; then
    [ "$RSS_MAX" -gt 0 ] && [ "$RSS_MAX" -lt 65536 ]
    check "server RSS stayed far below the pushed size (streamed)" $? "peak $RSS_MAX kB"
    [ "$(kv seen)" = 1 ]
    check "the server-side receive was observed" $?
    [ "$(kv inside)" -gt 0 ] && [ "$(kv inside_failed)" = 0 ]
    check "some of those clones ran while the server was receiving the pack" $? "$(kv inside) clones, $(kv inside_failed) failed"
else
    skip "server RSS stayed far below the pushed size (streamed)" "no /proc"
    skip "the server-side receive was observed" "no /proc"
    skip "some of those clones ran while the server was receiving the pack" "no /proc"
fi
[ "$(kv clones)" -gt 0 ] && [ "$(kv clones_failed)" = 0 ]
check "git clones of another repository succeed during the push" $? "$(kv clones) clones, $(kv clones_failed) failed"
[ "$(kv ref_n)" -ge 5 ] && [ "$(kv ref_err)" = 0 ]
check "ref-advertisement probes were all answered during the push" $? "$(kv ref_n) requests, $(kv ref_err) errors"
[ "$(kv idx_n)" -ge 5 ] && [ "$(kv idx_err)" = 0 ] && [ "$(kv idx_max_ms)" -lt 250 ]
check "the server never stalled: every index request during the push took < 250 ms" $? "$(kv idx_n) requests, $(kv idx_err) errors, max $(kv idx_max_ms) ms"

section "5. (cont.) a fresh clone is byte-identical"
FRESH="$WORK/big-clone"
py sampled "$SPID" "$T/clone.out" git clone -q "$(url /big.git)" "$FRESH"
cv() { sed -n "s/^$1 //p" "$T/clone.out" | head -n 1; }
[ "$(cv rc)" = 0 ]
check "fresh clone of big succeeds" $? "$(cv err)"
note "clone took $(cv secs) s; server RSS peak during the clone $(cv rss_max) kB"
if [ "$HAVE_PROC" = 1 ]; then
    [ "$(cv rss_max)" -gt 0 ] && [ "$(cv rss_max)" -lt 65536 ]
    check "server RSS stayed far below the cloned size" $? "peak $(cv rss_max) kB"
else
    skip "server RSS stayed far below the cloned size" "no /proc"
fi
cmp -s "$BW/blob.bin" "$FRESH/blob.bin"
check "the cloned blob is byte-identical" $?
git --git-dir "$(bare big)" fsck --strict >/dev/null 2>"$T/fsck.err"
check "git fsck of the server's repository is clean" $? "$(head -3 "$T/fsck.err")"
get /big/files.html
[ "$ST" = 200 ] && body_has blob.bin
check "big's pages list the blob without inlining it" $? "status $ST"
get /big/file/blob.bin.html
[ "$ST" = 200 ] && body_has "too large to show (104857600 bytes)"
check "the blob's page says it is too large to show" $? "status $ST"

section "5b. a large tag tarball streams"
git -C "$BW" tag v100
g -C "$BW" push "$(aurl "$ALICE" /big.git)" v100
check "push of a tag on the 100 MB commit" $? "$(glast)"
py sampled "$SPID" "$T/arch.out" python3 -I "$T/helper.py" download "$BASE" /big/archive/v100.tar.gz "$T/big.tar.gz"
av() { sed -n "s/^$1 //p" "$T/arch.out" | head -n 1; }
[ "$(av rc)" = 0 ]
check "the 100 MB tarball downloads" $? "$(av err)"
note "download took $(av secs) s ($(wc -c <"$T/big.tar.gz" | tr -d ' ') bytes); server RSS peak $(av rss_max) kB"
if [ "$HAVE_PROC" = 1 ]; then
    [ "$(av rss_max)" -gt 0 ] && [ "$(av rss_max)" -lt 65536 ]
    check "server RSS stayed far below the tarball's size (streamed)" $? "peak $(av rss_max) kB"
else
    skip "server RSS stayed far below the tarball's size (streamed)" "no /proc"
fi
tar xzOf "$T/big.tar.gz" big-v100/blob.bin 2>/dev/null | cmp -s - "$BW/blob.bin"
check "the blob in the tarball is byte-identical" $?
rm -f "$T/big.tar.gz"
if [ "$HAVE_PROC" = 1 ]; then
    py abort "$BASE" /big/archive/v100.tar.gz >/dev/null
    left=1
    for _ in $(seq 1 50); do
        left=$(py archiving)
        [ "$left" = 0 ] && break
        sleep 0.1
    done
    [ "$left" = 0 ]
    check "a client that hangs up mid-tarball leaves no git archive running" $? "$left still running"
else
    skip "a client that hangs up mid-tarball leaves no git archive running" "no /proc"
fi
get /
[ "$ST" = 200 ]
check "the server still answers after the aborted download" $? "status $ST"
rm -rf "$FRESH" "$BW"

# --- 9: path attacks --------------------------------------------------------------------

section "9. path attacks are refused"
for target in \
    "/../hoard.json" \
    "/%2e%2e/hoard.json" \
    "/pub/../priv/index.html" \
    "/pub/%2e%2e/priv/index.html" \
    "/pub/..%2fpriv/index.html" \
    "/pub/%2E%2E%2F%2E%2E%2Fhoard.json" \
    "/pub/file/..%2f..%2f..%2fhoard.json" \
    "/pub/%2e%2e%2f%2e%2e%2f%2e%2e%2fhoard.json" \
    "/pub.git/../priv.git/info/refs?service=git-upload-pack" \
    "/pub.git/%2e%2e/priv.git/info/refs?service=git-upload-pack" \
    "/priv%2f..%2fpub.git/info/refs?service=git-upload-pack" \
    "/a%2fb.git/info/refs" \
    "/pub%2fx/" \
    "/..%5c..%5choard.json" \
    "/pub/..%5c..%5choard.json" \
    "/pub%00/index.html" \
    "/pub/index.html%00" \
    "//priv/index.html" \
    "/.git/config" \
    "/pub.git/config" \
    "/pub.git/hooks/post-receive" \
    "/pub.git/objects/../config" \
    "/pub.git/%2e%2e/%2e%2e/hoard.json" \
    "/pub.git.git/info/refs" \
    "/pub/./../priv/" \
    "/pub/%2e/%2e%2e/priv/" \
    "/hooks/post-receive" \
    "/pub/../../hoard.json"; do
    get "$target"
    leaked=0
    if body_has '$6$' || body_has '[core]' || body_has 'root:' || body_has 'hoard test repository' || body_has '-regen --hook'; then
        leaked=1
    fi
    [ "$ST" -ge 400 ] && [ "$ST" -lt 500 ] && [ "$leaked" = 0 ]
    check "$target" $? "status $ST, leaked $leaked"
done
for name in "a/b" ".." "../x" "x.git" ".hidden" "a b" "%2e%2e" "_ok..no"; do
    hc -addrepo "$name"
    [ "$RC" = 1 ] && grep -q "invalid repository name" "$T/cli.err"
    check "addrepo refuses '$name'" $? "rc $RC: $(err1)"
done
hc -addrepo -x
[ "$RC" = 64 ]
check "addrepo of a name spelled like a command is a usage error (exit 64)" $? "rc $RC: $(err1)"
hc_in "pw" -adduser "a:b"
[ "$RC" = 1 ] && grep -q "invalid user name" "$T/cli.err"
check "adduser refuses a name with ':' (the Basic separator)" $? "rc $RC: $(err1)"

# --- hoard: page serving refuses symlinks -----------------------------------------------

section "9b. page serving refuses symlinked components"
SECRET="$T/secret"
mkdir -p "$SECRET/dir"
printf 'TOPSECRET file\n' >"$SECRET/secret.html"
printf 'TOPSECRET index\n' >"$SECRET/dir/index.html"
printf 'TOPSECRET page\n' >"$SECRET/dir/page.html"
PP="$SRV/pages/pub"
ln -s "$SECRET/secret.html" "$PP/planted.html"
ln -s "$SECRET/dir" "$PP/planted.d"
ln -s "$SECRET/dir" "$PP/file/planted.d"
LOGPAGE=$(ls "$PP/commit" | head -n 1)
mv "$PP/commit/$LOGPAGE" "$T/saved-commit-page"
ln -s "$SECRET/secret.html" "$PP/commit/$LOGPAGE"
for target in /pub/planted.html /pub/planted.d/ /pub/planted.d/page.html /pub/file/planted.d/page.html "/pub/commit/$LOGPAGE"; do
    get "$target"
    [ "$ST" = 404 ] && ! body_has TOPSECRET
    check "a symlink planted in the pages tree is not followed: $target" $? "status $ST"
done
get /pub/log.html
[ "$ST" = 200 ]
check "regular pages beside the planted links are still served" $? "status $ST"
rm -f "$PP/planted.html" "$PP/planted.d" "$PP/file/planted.d" "$PP/commit/$LOGPAGE"
mv "$T/saved-commit-page" "$PP/commit/$LOGPAGE"
get "/pub/commit/$LOGPAGE"
[ "$ST" = 200 ]
check "the restored commit page is served again" $? "status $ST"

# --- hoard: the admin lock -----------------------------------------------------------------

section "9c. admin commands take <config>.lock"
mkdir "$CFG.lock"
hc_in "dave-pw" -adduser dave
[ "$RC" = 1 ] && grep -q "rmdir" "$T/cli.err" && grep -F -q "$CFG.lock" "$T/cli.err"
check "a held lock refuses a second admin command, naming rmdir and the lock" $? "rc $RC: $(err1)"
[ "$(py config_get "$CFG" users.dave)" = null ]
check "...and the config was not changed" $?
hc -grant pub alice write
[ "$RC" = 1 ] && grep -q "rmdir" "$T/cli.err"
check "grant is refused under a held lock too" $? "rc $RC: $(err1)"
hc -list
[ "$RC" = 0 ] && grep -q "pub (public)" "$T/cli.out"
check "the read-only -list does not need the lock" $? "rc $RC: $(err1)"
[ -d "$CFG.lock" ]
check "a refused command does not remove someone else's lock" $?
rmdir "$CFG.lock"
hc_in "dave-pw" -adduser dave
[ "$RC" = 0 ] && [ ! -e "$CFG.lock" ]
check "after rmdir the command runs, and its lock is released" $? "rc $RC: $(err1)"
hc -grant nosuch dave read
[ "$RC" = 1 ] && [ ! -e "$CFG.lock" ]
check "a command that fails releases the lock" $? "rc $RC: $(err1)"
# Eight admin commands at once: each either runs or is refused by the lock,
# and none of the ones that ran loses its update.
par_pids=""
i=1
while [ $i -le 8 ]; do
    (printf 'pw%s\n' "$i" | "$HOARD_BIN" --config "$CFG" -adduser "par$i" >"$T/par$i.out" 2>"$T/par$i.err"
     echo $? >"$T/par$i.rc") &
    par_pids="$par_pids $!"
    i=$((i + 1))
done
for p in $par_pids; do wait "$p"; done
ran=0
refused_ok=1
present=0
i=1
while [ $i -le 8 ]; do
    if [ "$(cat "$T/par$i.rc")" = 0 ]; then
        ran=$((ran + 1))
        [ "$(py config_get "$CFG" users.par$i)" != null ] && present=$((present + 1))
    else
        grep -q rmdir "$T/par$i.err" || refused_ok=0
    fi
    i=$((i + 1))
done
others=$(py config_get "$CFG" users | grep -o '"par[0-9]"' | wc -l | tr -d ' ')
[ "$ran" -ge 1 ] && [ "$present" = "$ran" ] && [ "$others" = "$ran" ] && [ "$refused_ok" = 1 ] && [ ! -e "$CFG.lock" ]
check "concurrent admin commands: each runs or is refused, no update is lost" $? "ran $ran, saved $present, users par* $others, refusals name rmdir: $refused_ok"
note "$ran of 8 concurrent -adduser commands ran"

# --- hoard: -adopt, -regen, -visibility --------------------------------------------------

section "9d. adopt, regen and visibility"
git init -q --bare -b main "$(bare adopted)"
AW="$WORK/adopt"
git init -q -b main "$AW"
ASHA=$(commit_file "$AW" README.md "adopted repository
" "made before hoard knew it")
g -C "$AW" push "$(bare adopted)" main
hc -adopt adopted --public
[ "$RC" = 0 ] && grep -q "adopted repository adopted" "$T/cli.out"
check "adopt takes over an existing bare repository" $? "rc $RC: $(err1)"
[ "$(git --git-dir "$(bare adopted)" config core.hooksPath)" = "$SRV/hooks" ] && [ "$(git --git-dir "$(bare adopted)" config hoard.repo)" = adopted ]
check "adopt points the repository at hoard's hook" $?
get /adopted/log.html
[ "$ST" = 200 ] && body_has "$ASHA"
check "adopt generates the pages for the existing history" $? "status $ST"
hc -adopt missing
[ "$RC" = 1 ] && grep -q "does not exist" "$T/cli.err"
check "adopt refuses a repository that is not on disk" $? "rc $RC: $(err1)"
hc -adopt adopted
[ "$RC" = 1 ] && grep -q "already exists" "$T/cli.err"
check "adopt refuses a repository hoard already has" $? "rc $RC: $(err1)"
hc -grant adopted alice write
ASHA2=$(commit_file "$AW" more.txt "more
" "pushed through hoard")
g -C "$AW" push "$(aurl "$ALICE" /adopted.git)" main
check "a push over HTTP to the adopted repository" $? "$(glast)"
get /adopted/log.html
body_has "$ASHA2"
check "the hook rebuilds an adopted repository's pages" $?

CP="$SRV/pages/pub/commit/$SHA.html"
printf '<!-- MARKER -->\n' >>"$CP"
rm -f "$SRV/pages/pub/log.html"
hc -regen --hook pub
[ "$RC" = 0 ] && [ -f "$SRV/pages/pub/log.html" ] && grep -q MARKER "$CP"
check "regen --hook rebuilds the pages but keeps commit pages that exist" $? "rc $RC: $(err1)"
hc -regen pub
[ "$RC" = 0 ] && ! grep -q MARKER "$CP"
check "regen rebuilds every page" $? "rc $RC: $(err1)"
hc -regen nosuch
[ "$RC" = 1 ] && grep -q "no repository" "$T/cli.err"
check "regen of an unknown repository fails (exit 1)" $? "rc $RC: $(err1)"
mkdir -p "$SRV/pages/pub/file/stale.d"
printf 'stale\n' >"$SRV/pages/pub/file/stale.d/old.txt.html"
hc -regen pub
[ ! -e "$SRV/pages/pub/file/stale.d" ]
check "regen removes stale pages and their emptied directories" $?

hc -visibility priv public
get "/priv.git/info/refs?service=git-upload-pack"
[ "$RC" = 0 ] && [ "$ST" = 200 ]
check "visibility public opens a repository to anonymous reads" $? "rc $RC, status $ST"
hc -visibility priv private
get "/priv.git/info/refs?service=git-upload-pack"
[ "$RC" = 0 ] && [ "$ST" = 401 ]
check "visibility private closes it again at once" $? "rc $RC, status $ST"
hc -visibility priv secret
[ "$RC" = 1 ]
check "visibility refuses a level that is not public or private" $? "rc $RC: $(err1)"

# --- hoard: -delrepo and -rename ------------------------------------------------------------

section "9e. delrepo keeps the repository in repos/.trash; rename carries everything over"
TRASH="$SRV/repos/.trash"
hc -addrepo doomed --public -grant doomed alice write
DW="$WORK/doomed"
git init -q -b main "$DW"
DSHA=$(commit_file "$DW" a.txt "doomed
" "before deletion")
g -C "$DW" push "$(aurl "$ALICE" /doomed.git)" main
mkdir -p "$T/outside"
printf 'keep\n' >"$T/outside/keep"
ln -s "$T/outside" "$SRV/pages/doomed/escape"
cp "$CFG" "$T/cfg.before"
hc -delrepo doomed
[ "$RC" = 64 ] && grep -q "would:" "$T/cli.err" && grep -q "add --yes" "$T/cli.err" && cmp -s "$CFG" "$T/cfg.before" \
    && [ -d "$(bare doomed)" ] && [ -f "$SRV/pages/doomed/index.html" ] && [ ! -e "$TRASH" ]
check "delrepo without --yes shows the plan and changes nothing (exit 64)" $? "rc $RC: $(err1)"
hc -addrepo never4 -delrepo doomed
[ "$RC" = 64 ] && [ ! -e "$(bare never4)" ]
check "...and refuses the whole line before any of it runs" $? "rc $RC: $(err1)"
hc -delrepo doomed --yes
TR=$(ls -d "$TRASH"/doomed-*.git 2>/dev/null | head -n 1)
[ "$RC" = 0 ] && [ "$(py config_get "$CFG" repos.doomed)" = null ] && [ ! -e "$(bare doomed)" ] && [ -n "$TR" ] \
    && grep -F -q "$TR" "$T/cli.out" && grep -q "restore:" "$T/cli.out" && grep -q "purge:" "$T/cli.out"
check "delrepo --yes drops the config entry and moves the repository to repos/.trash" $? "rc $RC: $(err1)"
git --git-dir "$TR" fsck --no-progress >/dev/null 2>&1 && g clone -q "$TR" "$WORK/fromtrash" && [ "$(git -C "$WORK/fromtrash" rev-parse HEAD)" = "$DSHA" ]
check "the trashed repository is intact: fsck passes and it clones" $? "$(gerr)"
[ ! -e "$SRV/pages/doomed" ] && [ -f "$T/outside/keep" ]
check "its pages are deleted, without following a symlink out of them" $?
get "/doomed.git/info/refs?service=git-upload-pack" -u "$ALICE"
s1=$ST
get /doomed/ -u "$ALICE"
s2=$ST
[ "$s1" = 404 ] && [ "$s2" = 404 ]
check "a deleted repository is 404 for git and for pages" $? "git $s1, pages $s2"
get / -u "$ALICE"
[ "$ST" = 200 ] && ! body_has doomed && ! body_has .trash
check "the index lists neither the deleted repository nor the trash" $? "status $ST"
get "/.trash/" -u "$ALICE"
s1=$ST
get "/.trash/$(basename "$TR")/info/refs?service=git-upload-pack" -u "$ALICE"
[ "$s1" = 404 ] && [ "$ST" = 404 ]
check "the trash is never served" $? "pages $s1, git $ST"
hc -addrepo doomed
[ "$RC" = 0 ] && [ -z "$(refs_of doomed)" ] && [ -d "$TR" ]
check "the name can be used again, and the trashed copy stays" $? "rc $RC: $(err1)"
hc -delrepo doomed --yes
[ "$RC" = 0 ] && [ "$(ls -d "$TRASH"/doomed-*.git | wc -l | tr -d ' ')" = 2 ]
check "a second delete of the name keeps both copies apart" $? "rc $RC: $(err1)"
hc -delrepo nosuch --yes
[ "$RC" = 1 ] && grep -q "no repository" "$T/cli.err"
check "delrepo of an unknown repository fails (exit 1)" $? "rc $RC: $(err1)"
hc -delrepo .trash --yes
[ "$RC" = 64 ] && [ -d "$TRASH" ]
check ".trash is not a repository name (exit 64)" $? "rc $RC: $(err1)"
hc -addrepo linked
rm -rf "$SRV/pages/linked"
mkdir -p "$T/outside2"
printf 'keep\n' >"$T/outside2/keep"
ln -s "$T/outside2" "$SRV/pages/linked"
hc -delrepo linked --yes
[ "$RC" = 1 ] && grep -q "symlink" "$T/cli.err" && [ -f "$T/outside2/keep" ] && [ "$(py config_get "$CFG" repos.linked)" = null ]
check "a pages directory that is a symlink is left alone and reported (exit 1)" $? "rc $RC: $(err1)"
rm -f "$SRV/pages/linked"

hc -addrepo moving -grant moving alice write -grant moving bob read
MW="$WORK/moving"
git init -q -b main "$MW"
MSHA=$(commit_file "$MW" m.txt "moving
" "before the rename")
g -C "$MW" push "$(aurl "$ALICE" /moving.git)" main
hc -rename moving moved
[ "$RC" = 0 ] && [ "$(py config_get "$CFG" repos.moving)" = null ] && [ ! -e "$(bare moving)" ] && [ -d "$(bare moved)" ] \
    && [ "$(git --git-dir "$(bare moved)" config hoard.repo)" = moved ]
check "rename moves the repository and its hoard.repo" $? "rc $RC: $(err1)"
[ "$(py config_get "$CFG" repos.moved.writers)" = '["alice"]' ] && [ "$(py config_get "$CFG" repos.moved.readers)" = '["bob"]' ] \
    && [ "$(py config_get "$CFG" repos.moved.public)" = false ]
check "rename carries the permissions over" $? "$(py config_get "$CFG" repos.moved)"
g clone -q "$(aurl "$ALICE" /moved.git)" "$WORK/moved-clone" && [ "$(git -C "$WORK/moved-clone" rev-parse HEAD)" = "$MSHA" ]
check "a clone through the new URL works" $? "$(gerr)"
get "/moving.git/info/refs?service=git-upload-pack" -u "$ALICE"
s1=$ST
get /moving/ -u "$ALICE"
[ "$s1" = 404 ] && [ "$ST" = 404 ] && [ ! -e "$SRV/pages/moving" ]
check "the old name is 404 and its pages are gone" $? "git $s1, pages $ST"
get /moved/ -u "$ALICE"
[ "$ST" = 200 ] && body_has "/moved.git" && ! body_has moving.git
check "the pages are rebuilt under the new name" $? "status $ST"
MSHA2=$(commit_file "$MW" n.txt "renamed
" "after the rename")
g -C "$MW" push "$(aurl "$ALICE" /moved.git)" main
rc=$?
get /moved/log.html -u "$ALICE"
[ "$rc" = 0 ] && body_has "$MSHA2"
check "a push to the renamed repository rebuilds its pages (the hook follows)" $? "$(glast)"
hc -rename moved pub
[ "$RC" = 1 ] && grep -q "already exists" "$T/cli.err" && [ -d "$(bare moved)" ]
check "rename onto a configured name is refused" $? "rc $RC: $(err1)"
git init -q --bare "$(bare stray)"
hc -rename moved stray
[ "$RC" = 1 ] && grep -q "already exists on disk" "$T/cli.err" && [ -d "$(bare moved)" ]
check "rename onto a directory already on disk is refused" $? "rc $RC: $(err1)"
rm -rf "$(bare stray)"
bad=0
for name in x.git a..b .hidden 'sp ace' ""; do
    hc -rename moved "$name"
    [ "$RC" = 64 ] || bad=1
done
[ "$bad" = 0 ] && [ -d "$(bare moved)" ]
check "rename refuses invalid names (exit 64)" $?
hc -rename nosuch other
[ "$RC" = 1 ] && grep -q "no repository" "$T/cli.err"
check "rename of an unknown repository fails (exit 1)" $? "rc $RC: $(err1)"
mkdir "$CFG.lock"
hc -rename moved locked
[ "$RC" = 1 ] && grep -q rmdir "$T/cli.err" && [ -d "$(bare moved)" ] && [ ! -e "$(bare locked)" ]
check "rename respects the admin lock" $? "rc $RC: $(err1)"
hc -delrepo moved --yes
[ "$RC" = 1 ] && [ -d "$(bare moved)" ]
check "delrepo respects the admin lock" $? "rc $RC: $(err1)"
rmdir "$CFG.lock"
# A rename that died after moving the directory: running it again finishes.
mv "$(bare moved)" "$(bare resumed)"
hc -rename moved resumed
[ "$RC" = 0 ] && [ "$(py config_get "$CFG" repos.resumed.writers)" = '["alice"]' ] && [ "$(git --git-dir "$(bare resumed)" config hoard.repo)" = resumed ]
check "a rename interrupted after the move finishes when run again" $? "rc $RC: $(err1)"
hc -rename adopted adopted2
g clone -q "$(url /adopted2.git)" "$WORK/adopted2" && [ -f "$WORK/adopted2/more.txt" ]
check "an adopted repository can be renamed" $? "rc $RC: $(err1) $(gerr)"
hc -delrepo adopted2 --yes
[ "$RC" = 0 ] && [ -n "$(ls -d "$TRASH"/adopted2-*.git 2>/dev/null)" ] && [ "$(py config_get "$CFG" repos.adopted2)" = null ]
check "an adopted repository can be deleted" $? "rc $RC: $(err1)"

# --- 10-11: damping and password changes --------------------------------------------------

section "10. repeated wrong passwords are damped"
py config_set "$CFG" trusted_proxies '["127.0.0.1"]'
X1="X-Forwarded-For: 10.9.9.9"
statuses=""
all401=0
for _ in 1 2 3 4 5; do
    get "/priv.git/info/refs?service=git-upload-pack" -u "bob:guess" -H "$X1"
    statuses="$statuses $ST"
    [ "$ST" = 401 ] || all401=1
done
check "the first five wrong passwords are 401" $all401 "$statuses"
get "/priv.git/info/refs?service=git-upload-pack" -u "$BOB" -H "$X1"
RA=$(header retry-after)
[ "$ST" = 429 ] && [ -n "$RA" ] && [ "$RA" -ge 1 ] && [ "$RA" -le 60 ]
check "then even the right password is refused with 429 and Retry-After" $? "status $ST, retry-after $RA"
get "/priv.git/info/refs?service=git-upload-pack" -u "$BOB" -H "X-Forwarded-For: 10.9.9.10"
[ "$ST" = 200 ]
check "another client address is unaffected" $? "status $ST"
get "/pub.git/info/refs?service=git-upload-pack" -H "$X1"
[ "$ST" = 200 ]
check "anonymous public access from the locked address still works" $? "status $ST"
get / -u "$BOB" -H "$X1"
[ "$ST" = 429 ]
check "the locked address gets 429 on the index too" $? "status $ST"

section "11. a changed password takes effect at once"
X2="X-Forwarded-For: 10.7.7.7"
get /priv/ -u "$BOB" -H "$X2"
[ "$ST" = 200 ]
check "bob's current password works (and is now cached)" $? "status $ST"
hc_in "a new password" -passwd bob
check "passwd bob" $RC "$(err1)"
get /priv/ -u "$BOB" -H "$X2"
[ "$ST" = 401 ]
check "the old password is refused immediately despite the cache" $? "status $ST"
get /priv/ -u "bob:a new password" -H "$X2"
[ "$ST" = 200 ]
check "the new password works" $? "status $ST"
hc -deluser carol
drc=$RC
get /pub/ -u "$CAROL" -H "$X2"
readers=$(py config_get "$CFG" repos.pub.readers)
[ "$drc" = 0 ] && [ "$ST" = 401 ] && ! printf '%s' "$readers" | grep -q carol
check "deluser removes the login and every grant" $? "rc $drc, status $ST, pub readers $readers"
hc -revoke priv bob
get /priv/ -u "bob:a new password" -H "$X2"
[ "$RC" = 0 ] && [ "$ST" = 404 ]
check "after revoke, bob gets 404 for priv" $? "rc $RC, status $ST"

section "10b. behind a proxy chain, damping follows the real client"
# 127.0.0.1 is rpxy; 192.0.2.0/24 stands in for Cloudflare's ranges. The
# header reads "client, edge": Cloudflare appends the client, rpxy appends
# the edge it came from.
hc -grant priv bob read
hc -proxies --set 127.0.0.1 192.0.2.0/24
check "proxies set accepts an address and a CIDR block" $RC "$(err1)"
hc -proxies --set 127.0.0.1 192.0.2.0/33
[ "$RC" != 0 ]
check "proxies set refuses a malformed block" $? "rc $RC"
VICTIM=203.0.113.5
for i in 1 2 3 4 5; do
    get "/priv.git/info/refs?service=git-upload-pack" -u "bob:guess" -H "X-Forwarded-For: $VICTIM, 192.0.2.$i"
done
get "/priv.git/info/refs?service=git-upload-pack" -u "bob:a new password" -H "X-Forwarded-For: $VICTIM, 192.0.2.200"
[ "$ST" = 429 ]
check "five failures through different edges lock that client (429)" $? "status $ST"
get "/priv.git/info/refs?service=git-upload-pack" -u "bob:a new password" -H "X-Forwarded-For: 203.0.113.6, 192.0.2.1"
[ "$ST" != 429 ]
check "another client on the same edge is unaffected" $? "status $ST"
ATTACKER=198.51.100.9
for _ in 1 2 3 4 5; do
    get "/priv.git/info/refs?service=git-upload-pack" -u "bob:guess" -H "X-Forwarded-For: 203.0.113.77, $ATTACKER"
done
get "/priv.git/info/refs?service=git-upload-pack" -u "bob:a new password" -H "X-Forwarded-For: 203.0.113.77, 192.0.2.1"
[ "$ST" != 429 ]
check "a spoofed client in the header is not what gets locked" $? "status $ST"
get "/priv.git/info/refs?service=git-upload-pack" -u "bob:a new password" -H "X-Forwarded-For: 203.0.113.78, $ATTACKER"
[ "$ST" = 429 ]
check "the address the trusted proxy appended is" $? "status $ST"
hc -proxies --set 127.0.0.1

# --- 12: a config save is atomic -----------------------------------------------------------

section "12. a config save is atomic"
# What a crash before the rename leaves behind: the untouched config and a
# half-written temp file beside it (hoard writes <config>.tmp).
py half "$CFG" "$CFG.tmp"
py half "$CFG" "$CFG.tmp"
hc -list
[ "$RC" = 0 ] && grep -q "pub (public)" "$T/cli.out"
check "a half-written temp file left by a crash is ignored" $? "rc $RC: $(err1)"
get "/pub.git/info/refs?service=git-upload-pack"
[ "$ST" = 200 ]
check "the server keeps serving" $? "status $ST"
chmod 644 "$CFG.tmp"
hc -grant pub bob read
[ "$RC" = 0 ] && [ "$(py config_get "$CFG" repos.pub.readers)" = '["bob"]' ] && [ ! -e "$CFG.tmp" ]
check "the next save replaces the config by rename and leaves no temp file" $? "rc $RC: $(err1); readers $(py config_get "$CFG" repos.pub.readers)"
rm -f "$CFG.tmp"
[ "$(py mode "$CFG")" = 600 ]
check "the saved config is readable only by its owner (0600), even over a stray 0644 temp" $? "mode $(py mode "$CFG")"
# A hand edit the server sees half-written must not take the server down or
# open anything up: it keeps the last config that parsed.
cp "$CFG" "$T/cfg.good"
py half "$T/cfg.good" "$CFG"
get "/priv.git/info/refs?service=git-upload-pack"
s1=$ST
get "/pub.git/info/refs?service=git-upload-pack"
s2=$ST
cp "$T/cfg.good" "$CFG"
chmod 600 "$CFG"
[ "$s1" = 401 ] && [ "$s2" = 200 ]
check "a truncated config on disk: the server keeps the last good one" $? "priv $s1, pub $s2"

# --- 13: the command line ---------------------------------------------------------------

section "13. the command line: -command, --option, and nothing half-done"
hc -addrepo gram -grant gram alice write -visibility gram public
rc=$RC
hc -list
[ "$rc" = 0 ] && grep -q "gram (public)" "$T/cli.out" && grep -q "gram (public) readers= writers=alice" "$T/cli.out"
check "several commands on one line run in the order typed" $? "rc $rc"
hc -addrepo never1 -regn gram
[ "$RC" = 64 ] && grep -q "unknown command '-regn'" "$T/cli.err"
check "a misspelled command anywhere refuses the whole line (exit 64)" $? "rc $RC: $(err1)"
[ ! -e "$(bare never1)" ]
check "...and nothing before it ran" $?
hc -addrepo never2 -grant gram
[ "$RC" = 64 ] && grep -q "missing <user>" "$T/cli.err"
check "a missing operand anywhere refuses the whole line (exit 64)" $? "rc $RC: $(err1)"
[ ! -e "$(bare never2)" ]
check "...and nothing before it ran" $?
hc -addrepo gram -addrepo never3
[ "$RC" = 1 ] && grep -q "already exists" "$T/cli.err"
check "a command that fails at run time stops the ones after it (exit 1)" $? "rc $RC: $(err1)"
[ ! -e "$(bare never3)" ]
check "...and the later command did not run" $?
hc -addrepo serve
check "a repository may be called 'serve'" $RC "$(err1)"
hc addrepo nodash
[ "$RC" = 64 ] && grep -q "'addrepo' is a command, so it is written with a dash: '-addrepo'" "$T/cli.err"
check "a command without its dash is refused, and named" $? "rc $RC: $(err1)"
hc -h
[ "$RC" = 64 ] && grep -q "write '--help'" "$T/cli.err"
check "-h says help is an option" $? "rc $RC: $(err1)"
hc --help
[ "$RC" = 0 ] && grep -q -- "-addrepo" "$T/cli.out" && grep -q -- "-adopt" "$T/cli.out"
check "--help lists the commands with their dashes" $? "rc $RC"
hc -addrepo --help
[ "$RC" = 0 ] && grep -q "usage: hoard -addrepo" "$T/cli.out"
check "a command's --help is that command's" $? "rc $RC"
hc -l
[ "$RC" = 0 ] && grep -q "repositories:" "$T/cli.out"
check "a short command is one dash and one letter" $? "rc $RC: $(err1)"
hc
[ "$RC" = 64 ]
check "no command at all is a usage error (exit 64)" $? "rc $RC"
hc -serve --workers 0
[ "$RC" = 64 ]
check "serve --workers 0 is a usage error (exit 64)" $? "rc $RC: $(err1)"
hc -grant gram alice admin
[ "$RC" = 1 ] && grep -q "read or write" "$T/cli.err"
check "grant refuses a level that is not read or write (exit 1)" $? "rc $RC: $(err1)"
hc -proxies --set 127.0.0.1 192.0.2.0/24 198.51.100.7 -list
rc=$RC
hc -proxies
[ "$rc" = 0 ] && [ "$(cat "$T/cli.out")" = "127.0.0.1
192.0.2.0/24
198.51.100.7" ]
check "a list option takes every value up to the next dash" $? "rc $rc: $(cat "$T/cli.out")"
hc -proxies --set 127.0.0.1 --set 10.0.0.1
[ "$RC" = 64 ] && grep -q "given more than once" "$T/cli.err"
check "...and is refused if written twice (exit 64)" $? "rc $RC: $(err1)"
hc -proxies --set 127.0.0.1
hc -proxies --set 999.1.2.3
[ "$RC" = 1 ] && grep -q "not an IP address" "$T/cli.err"
check "a value only hoard can judge is its own refusal (exit 1)" $? "rc $RC: $(err1)"
hc -proxies
grep -q "127.0.0.1" "$T/cli.out"
check "...and the list was left alone" $?
hc -list -list
[ "$RC" = 0 ] && [ "$(grep -c "users:" "$T/cli.out")" = 2 ]
check "the same command twice is a list, not a set" $? "rc $RC: $(err1)"
[ ! -e "$CFG.lock" ]
check "no admin lock is left behind at the end" $?
kill -0 "$SPID" 2>/dev/null
check "the server is still running at the end" $?

section "done"
if [ "$FAILED" -gt 0 ]; then
    printf '%s\n' "$FAILED_NAMES" | sed '/^$/d'
fi
printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]
