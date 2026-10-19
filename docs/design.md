# hoard: design

hoard is a small self-hosted git server written in m31: HTTP only, Basic auth,
per-repository permissions and static browsable pages. It is the m31 port of
orogit (written in Oro), and it keeps orogit's behaviour, its config file and
its security rules. The changes come from what m31 has that Oro did not.

## 1. Scope

The same feature set as orogit, nothing more in 0.1:

| Area | Behaviour |
|---|---|
| Transport | Git smart HTTP through `git http-backend`, streamed both ways in constant memory. No SSH. |
| Auth | HTTP Basic. Passwords stored as SHA-512-crypt (`$6$`) hashes. |
| Permissions | Per repository: public flag, readers, writers. A user without access gets 404, never 403, so private names cannot be probed. A reader who tries to push gets 403. |
| Damping | Failed logins counted per client address (walked back through trusted proxies in `X-Forwarded-For`). Five failures in 10 minutes lock the address out for 60 s, doubling per further failure, capped at 15 min. Each failure is answered 250 ms late. |
| Pages | stagit-style static pages per repository, rebuilt by a post-receive hook: summary, log, files, one page per file and per commit. |
| Index | `/` lists the repositories the requester may read; `/?login` asks for credentials. |
| Admin | One CLI, Oro's args grammar: `-init`, `-serve`, `-adduser`, `-passwd`, `-deluser`, `-addrepo [--public]`, `-adopt`, `-delrepo --yes`, `-rename`, `-grant`, `-revoke`, `-visibility`, `-proxies [--set ...]`, `-regen [--hook]`, `-list`. |
| Tarballs | `/<repo>/archive/<tag>.tar.gz`: a tag's source, made by `git archive` and streamed. Tags only. Not in orogit. |

URL layout (unchanged from orogit):

```
/                     repositories the requester may read
/<repo>.git/...       git smart HTTP
/<repo>/archive/<tag>.tar.gz
                      a tag's source tarball (hoard only)
/<repo>/...           the repository's generated pages
```

The config file has orogit's schema, so an orogit install moves over by
copying `orogit.json` to `hoard.json`. The `oro` key is ignored.

```json
{
  "listen": "127.0.0.1:8789",
  "repo_root": "repos",
  "pages_root": "pages",
  "base_url": "https://git.example.org",
  "trusted_proxies": ["127.0.0.1"],
  "users": {"alice": {"hash": "$6$salt$..."}},
  "repos": {"hello": {"public": true, "readers": [], "writers": ["alice"]}}
}
```

## 2. What changes from orogit, and why

| orogit (Oro) | hoard (m31) | Reason |
|---|---|---|
| `openssl passwd -6` in a subprocess, with a 5-minute login cache because the call blocked the VM | SHA-512-crypt computed in-process (`HOARD_crypt`, about 30 ms per verify). The cache is kept only to save CPU. | No subprocess, no password on any pipe. Checked against the spec vectors and `openssl passwd -6`. `HOARD_crypt` carries its own SHA-512 on plain 64-bit ints: `lib/crypto/sha512` allocates per word and made a verify take about 650 ms. |
| Green threads; `http.serve` with a connection cap | An accept loop plus a fixed pool of worker threads; each accepted `net.Conn` is moved to a worker over a channel. | m31's `http.serve` handles one connection at a time and cannot share a handler between threads (non-atomic refcounts). Moving the connection is the documented pattern (reference §8.3). |
| `static_files`, which follows symlinks | hoard serves pages itself: it refuses any path component that is a symlink, then checks `fs.realpath` stays inside the pages root. | m31 has `fs.is_link` and `fs.realpath`. Closes orogit's documented race. The rule that pages are written as regular files, never checked out, stays. |
| Post-receive hook is an Oro script reached through `core.hooksPath` (Oro has no chmod) | `-init` writes `hooks/post-receive`, a two-line shell script created with mode 0755 (`io.open(perm:)`), which runs `hoard -regen --hook <repo>`. | m31 can set a mode when it creates a file. |
| No lock: two admin commands at once can lose an update | Admin commands take a lock by creating `<config>.lock` with `fs.mkdir`, which is atomic. A lock left by a crash is reported with the path to remove. | A real fix for an open orogit gap without needing `flock`. |
| Emptied page directories left behind (no rmdir) | Stale page directories are removed with `fs.rmdir`. | m31 has rmdir. |
| One process, one interpreter | One static binary per platform, released with `SHA256SUMS` and a curl installer. | Repo standard. |

## 3. Architecture

```
hoard.m31                entry: the command line (lib/args), dispatch
core/HOARD_store.m31     config: names, load, normalise, permissions, atomic save, lock
core/HOARD_addr.m31      client address through trusted proxies (IPv4 CIDR, exact v6)
core/HOARD_crypt.m31     SHA-512-crypt hash and verify, constant-time compare
core/HOARD_auth.m31      Basic credentials, the guard thread (cache and damping)
core/HOARD_server.m31    accept loop, worker pool, request loop, routing, index, pages
core/HOARD_cgi.m31       git http-backend as streamed CGI
core/HOARD_archive.m31   tag tarballs: git archive, streamed
core/HOARD_pages.m31     the page generator
core/HOARD_html.m31      escaping and the page layout
tests/                   unit tests (t_*.m31) and the end-to-end suite
scripts/                 build.sh, test.sh, release helpers
install.sh               curl installer
```

### 3.1 Threads

```
main thread       accept() ──send(Conn)──► conns: Chan<net.Conn>(64)
worker 1..N       recv(conns) → serve one connection to the end, then the next
guard thread      owns the login cache and the failure table
housekeeper       every gc_hours (default 24): git gc where loose objects
                  or several packs are found (HOARD_gc; -gc runs one pass)
```

- Workers: `N = 16` by default (`--workers`). A long clone occupies one
  worker, not the server. When every worker is busy, new connections wait in
  the channel, then in the listen backlog.
- Each worker re-reads the config file per request and re-parses it only when
  the bytes change, as orogit does.
- The guard thread is the only owner of shared mutable state. A worker sends
  it a request (`Check(addr)`, `Verify(user, password, hash)`,
  `Failed(addr)`, `Succeeded(addr)`) together with the worker's own reply
  channel, and waits for the answer. Channels are shared, not moved, so this
  needs no locks.
- Password verification runs in the worker, not the guard, so one slow
  verification never stalls the others. The guard only answers cache lookups
  and records outcomes.

### 3.2 A connection

```
loop:
  read_request_stream(conn)         head checked as read_request checks it
  route + authorise                 no body read yet
  git path   → cgi.run(...)         body piped to the backend, output streamed back
  archive    → git archive streamed back
  pages path → file streamed back   start_response + BodyWriter
  index      → buffered page
  keep-alive only if the request body was read to the end
                and BodyWriter.is_keep_alive()
```

Requests that are refused before their body is read (401, 403, 404) close the
connection afterwards, because the unread body would desynchronise the next
request.

### 3.3 git http-backend

1. Build the CGI environment exactly as orogit does: `GIT_PROJECT_ROOT`,
   `PATH_INFO`, `QUERY_STRING` (only `service=` on `info/refs`),
   `REQUEST_METHOD`, `CONTENT_TYPE`, `HTTP_CONTENT_ENCODING`,
   `HTTP_GIT_PROTOCOL` (validated), `REMOTE_USER`, `REMOTE_ADDR`, and
   `GIT_HTTP_EXPORT_ALL` only on the path where read access was checked.
2. `proc.start(["git", "http-backend"], env:, cwd:)`. Its stderr pipe is
   moved to a spawned thread that logs it line by line, so a chatty backend
   cannot fill a pipe nobody reads.
3. Copy the request body into stdin with `RequestStream.read`, then close
   stdin. This cannot deadlock with git's stateless RPC: upload-pack and
   receive-pack read their whole request before they write anything large.
   orogit relies on the same property.
4. Read the CGI head from stdout (`read_until("\r\n\r\n", 64 KiB)`), map
   `Status:` and the headers, and drop hop-by-hop headers.
5. `start_response`, then copy stdout to the `BodyWriter` in 64 KiB pieces,
   then `finish` and `wait`. A client that disconnects mid-stream drops the
   `Proc`, which kills and reaps the backend.

Only the backend paths orogit allows reach a process. Everything else is a 404
before `git` runs.

### 3.4 Pages

A port of orogit's generator, with the same limits: log of 200 commits, 10 on
the summary, blobs up to 512 KiB shown, diffs capped at 256 KiB, binary
sniffed from the first 8000 bytes. Everything comes from `git` subprocesses
(`for-each-ref`, `log -z`, `ls-tree -r -l -z`, `cat-file --batch`, `show`).
Every piece of repository text is HTML-escaped on its way into a page. Pages
are written as regular files, and stale ones are removed.

Two pushes close together each re-render until the branch tip they rendered
is still the tip afterwards, so the last one to finish shows the newest commit.

The summary's tag table links each tag's tarball (3.5). A tag whose name
the server would refuse is listed without a link.

Later (not 0.1): read objects through the m31git library instead of `git`
subprocesses.

### 3.5 Tag tarballs

`GET` or `HEAD /<repo>/archive/<tag>.tar.gz` answers a tag's source as
`git archive --format=tar.gz --prefix=<repo>-<tag>/`.

- Tags only, never branches or commit names, so a URL keeps meaning the same
  bytes and can be cached.
- The access rules are the pages' rules: anonymous on a private repository is
  401, a user without read access is 404, never 403.
- The tag name must be one path segment in the repository-name alphabet:
  letters, digits, `.`, `_` and `-`, starting with a letter, digit or `_`, at
  most 100 bytes, no `..`. That rules out a leading `-` (an option to git),
  `/` and everything git reads as revision syntax (`^`, `~`, `:`, `@{`).
  Tags with a `/` (`release/1.0`) are deliberately not served: one segment
  keeps the check simple. A refused name is a 404 and never reaches git.
- The name is then resolved once with `git rev-parse --verify --quiet
  refs/tags/<tag>^{commit}`; a missing tag, or one that names no commit, is
  the same 404. The archive is made from the commit found, so a tag moved
  mid-request cannot mix two trees.
- git runs with only `PATH`, `LC_ALL=C` and `GIT_CONFIG_NOSYSTEM=1`, so no
  user's config can swap the compressor. Its stdout is copied to the client
  in 64 KiB pieces (a 100 MB tarball peaks at about 9 MB resident). The first
  piece is read before the head goes out, so a git that fails at once is a
  clean 500. A client that disconnects drops the `Proc`, which kills git; a
  git that fails mid-stream closes the connection without ending the chunked
  body, so the client sees a truncated download, not a short valid one.
- Headers: `Content-Type: application/gzip`, `Content-Disposition:
  attachment; filename="<repo>-<tag>.tar.gz"`, `nosniff`. Public
  repositories add `Cache-Control: public, max-age=86400, immutable` (a day,
  because a tag can be moved by force); private ones `private, no-store`.
  A `HEAD` gets the headers without running `git archive`.
- `archive/` is routed before the pages and the generator never writes
  there, so no generated page can shadow a tarball or the reverse.

### 3.6 Security rules carried over unchanged

- Path checks run after percent-decoding; `..`, `.`, NUL and backslash are
  refused before any lookup.
- No access → 404. Wrong password → 401 plus a recorded failure, never
  anonymous access.
- A user that does not exist costs the same hash as a wrong password
  (a dummy hash is verified), so user names cannot be found by timing.
- Passwords come from stdin, never argv. A password with a line break or NUL,
  an empty one, or one over 1024 bytes is refused.
- The config is saved to `<config>.tmp` with mode 0600, then renamed over the
  config.
- Every generated page carries `Content-Security-Policy: default-src 'none';
  style-src 'unsafe-inline'; img-src 'self'`, `X-Content-Type-Options:
  nosniff` and `Referrer-Policy: same-origin`. Private repositories add
  `Cache-Control: private, no-store`.

### 3.6 Deleting and renaming a repository

orogit has neither. hoard never destroys a repository: deleting one is the
admin's decision, and undoing a mistake must not need a backup.

- `-delrepo NAME --yes` moves `repos/NAME.git` to
  `repos/.trash/NAME-<UTC time>.git` (a rename within `repo_root`, so atomic;
  `-2`, `-3`... if that name is taken), drops the config entry, and deletes
  `pages/NAME` with `fs.rmtree`, which unlinks a symlink inside the tree
  rather than following it and refuses one at the top. It prints where the
  repository went, its old permissions, and the two commands to restore it
  (`mv` back, then `-adopt` and grant again) or purge it (`rm -rf`).
- Without `--yes` it runs nothing on the line, prints the plan and exits 64,
  like any other usage error. Invalid names to `-delrepo` and `-rename` are
  usage errors too.
- `.trash` cannot be a repository name (a name starts with a letter, digit or
  `_`), so the server never routes to it and the index never lists it.
- `-rename OLD NEW` refuses a NEW that is configured or already on disk. Pages
  link by repository name, so they are rebuilt under NEW, not moved.

Both run under the admin lock, in an order that leaves a crash recoverable by
running the same command again:

| Step | `-delrepo` | `-rename` |
|---|---|---|
| 1 | move the repository into `.trash` | move `OLD.git` to `NEW.git` |
| 2 | save the config without it | set `hoard.repo = NEW` in it (the hook reads it) |
| 3 | delete its pages | save the config: the entry moves, permissions with it |
| 4 | | rebuild `pages/NEW`, delete `pages/OLD` |

After step 1 the config still names the repository. A second `-delrepo` finds
no directory and finishes; a second `-rename` finds `NEW.git` without `OLD.git`,
naming itself OLD or NEW in `hoard.repo`, and carries on from step 2. After the
config is saved only pages can be wrong: `-regen NEW`, and remove the old pages
directory by hand. The server does not take the lock, so a push in flight
while its repository is renamed may fail; the client pushes again to the new
URL.

## 4. Testing

- Unit tests (`tests/t_*.m31`): names, config normalisation, permissions,
  address walking and CIDR, SHA-512-crypt against vectors from
  `openssl passwd -6`, Basic credential parsing, CGI head parsing, escaping.
- End to end (`tests/e2e.sh`): orogit's 120 checks, ported. A real `git`
  client against a server on a free port with a temp config: public versus
  private, refused pushes, a 100 MB push with RSS measured, concurrent clones
  during it, page regeneration, HTML injection, path attacks, damping, the
  proxy-chain client address, atomic config save, and the admin lock.
  hoard adds tag tarballs: contents against a local `git archive`, access,
  HEAD, hostile tag names (a logging `git` wrapper shows none reaches git), a
  100 MB tarball with RSS measured, and a client hanging up mid-download.
- Everything runs through `tests/test.sh`, on Linux and macOS, in CI.

## 5. Release and install

- Tags `vX.Y.Z`. CI builds Linux x86-64 and aarch64 (glibc and musl) plus
  macOS arm64. Assets are `hoard-<version>-<os>-<arch>.tar.gz` plus
  `SHA256SUMS`, with notes taken from `CHANGELOG.md`.
- `install.sh` (`curl -fsSL .../install.sh | sh`) detects the OS and
  architecture, downloads the latest release (or `--version X`), checks
  `SHA256SUMS`, and installs to `~/.local/bin`.

## 6. Deployment (homelab)

```
~/homelab/apps/hoard/
  bin/hoard           the release binary
  data/hoard.json     the config (copied from orogit.json for the move)
  data/repos/         bare repositories (copied or moved from orogit)
  data/pages/
  hooks/post-receive  written by -init
  hoard.sh            start | stop | restart | status (nohup + pidfile, like orogit.sh)
```

hoard runs on `127.0.0.1:8789` beside orogit until it passes the e2e suite and
a real clone and push. Pointing `git.meghraj.uk` at it is an rpxy change the
user makes.

## 7. Dependencies on m31

- **m31 0.7.0**: `http.read_request_stream` and `http.start_response`
  (server-side streamed bodies). Built and tested on the
  `feat/http-stream` branch: 48 MiB echoed through a live socket with a 6.6 MiB
  peak RSS.
- Nothing else. Channels, `spawn`, `proc.start`, `fs.is_link`, `fs.realpath`,
  `fs.rmdir`, `io.open(perm:)`, `crypto.sha256`, `encoding.json` and
  `lib/args` all exist in 0.6.0.

## 8. Not in 0.1

- SSH transport (m31 has the crypto; it is a later decision).
- Log rotation, backups, TLS (rpxy terminates TLS).
- Graceful shutdown on SIGTERM (m31 has no signal handling). In-flight
  requests are cut, as they are with orogit.
