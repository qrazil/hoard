# hoard

A small self-hosted git server: HTTP only, Basic auth, per-repository
permissions and static browsable pages. Written in
[m31](https://github.com/qrazil/m31); the port of orogit, with the same config
file and URL layout.

```
/                     the repositories you may read (/?login to sign in)
/<repo>.git/...       git smart HTTP: clone, fetch, push
/<repo>/archive/<tag>.tar.gz
                      a tag's source tarball, linked from the summary page
/<repo>/...           the repository's generated pages
```

Tarballs are served for tags only, with names of letters, digits, `.`, `_`
and `-` (no `/`); readers of a private repository need to log in, as for its
pages.

## Install

```
curl -fsSL https://raw.githubusercontent.com/qrazil/hoard/main/install.sh | sh
```

Or build it (below). It needs `git` on `PATH` at run time.

## Use

```
hoard --config data/hoard.json -init --listen 127.0.0.1:8789 --base-url https://git.example.org
echo 'a password' | hoard --config data/hoard.json -adduser alice
hoard --config data/hoard.json -addrepo site --public -grant site alice write
hoard --config data/hoard.json -serve --workers 16
```

| Command | What it does |
|---|---|
| `-init [--listen ADDR] [--base-url URL]` | create the config, `repos/`, `pages/` and `hooks/post-receive` |
| `-serve [--listen ADDR] [--workers N]` | run the server |
| `-adduser NAME`, `-passwd NAME` | add a user, change a password; the password is read from stdin |
| `-deluser NAME` | remove a user and all their grants and tokens |
| `-token USER NAME [--read-only]` | make an access token and print it, once |
| `-tokens USER`, `-revoke-token USER NAME` | list a user's tokens (name, scope, date), delete one |
| `-addrepo NAME [--public]` | create a bare repository |
| `-adopt NAME [--public]` | take over an existing `repos/NAME.git` (moving from orogit) |
| `-delrepo NAME --yes` | move `repos/NAME.git` to `repos/.trash/` and delete its pages; prints how to restore or purge it. Without `--yes` it shows the plan and exits 64 |
| `-rename OLD NEW` | rename a repository, keeping its permissions; rebuilds its pages |
| `-grant REPO USER read\|write`, `-revoke REPO USER` | permissions |
| `-visibility REPO public\|private` | anonymous read access |
| `-proxies [--set ENTRY...]` | show or replace the trusted proxies (IPs, IPv4 CIDR blocks) |
| `-regen NAME` | rebuild a repository's pages |
| `-list` | users and repositories |

The config file defaults to `$HOARD_CONFIG`, then `./hoard.json`. Several
commands may share one line; the whole line is checked before any of it runs.
Usage errors exit 64, other failures 1.

Access tokens are for scripts and CI: a token works wherever the user's
password does (HTTP Basic, user name plus token), carries no more than the
user's grants, and with `--read-only` cannot push. Only its SHA-256 is kept,
so it is shown once:

```
TOKEN=$(hoard --config data/hoard.json -token alice ci --read-only)
git clone "https://alice:$TOKEN@git.example.org/site.git"
```

Moving from orogit: copy `orogit.json` to `hoard.json` and the `repos/`
directory beside it, run `-init` in a fresh directory to get the hook, then
`-adopt` each repository (or point each repository's `core.hooksPath` at the
new `hooks/` and set `hoard.repo`).

## Build

You need `m31c` and the m31 runtime (a checkout of qrazil/m31 at 0.7.0 or
later, or an extracted release).

```
M31_ROOT=/path/to/m31 LANGC=/path/to/m31c bash scripts/build.sh      # -> ./hoard
```

## Test

```
M31_ROOT=/path/to/m31 LANGC=/path/to/m31c bash tests/test.sh
```

Formatting, the naming lint, the unit tests (`tests/t_*.m31`) and the
end-to-end suite (`tests/e2e.sh`, a real git client against the built server).

## Layout

```
hoard.m31              the command line
core/HOARD_store.m31   config, permissions, atomic save, admin lock
core/HOARD_addr.m31    client address through trusted proxies
core/HOARD_crypt.m31   SHA-512-crypt
core/HOARD_token.m31   access tokens
core/HOARD_auth.m31    Basic credentials; the guard thread (cache, damping)
core/HOARD_server.m31  accept loop, workers, routing, index, page serving
core/HOARD_cgi.m31     git http-backend, streamed
core/HOARD_archive.m31 tag tarballs (git archive), streamed
core/HOARD_pages.m31   the page generator
core/HOARD_html.m31    escaping and page layout
tests/                 test.sh runs everything
docs/design.md         how it works and why
```

## Release

Add a `CHANGELOG.md` entry, bump `version` in `deps` and `VERSION` in
`hoard.m31`, then tag `vX.Y.Z` and push the tag. CI tests on every platform and
attaches the binaries and `SHA256SUMS` to the release.
