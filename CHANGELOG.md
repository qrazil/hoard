# Changelog

## 0.1.0 (unreleased)

First version: the m31 port of orogit.

- Git smart HTTP through `git http-backend`, streamed both ways in constant
  memory (a 100 MB push peaks at about 8 MB resident).
- HTTP Basic auth with SHA-512-crypt hashes computed in-process; per-repository
  public, read and write permissions; 404 for anything a requester may not see.
- Failed-login damping per client address, walked back through trusted proxies.
- A worker pool (`-serve --workers N`, default 16) with one guard thread owning
  the login cache and the failure table.
- Static pages per repository, rebuilt by a post-receive hook; page serving
  refuses symbolic links anywhere on the path.
- Admin commands in Oro's args grammar, serialised by a `<config>.lock`
  directory; `-adopt` takes over an existing bare repository (an orogit move).
- Reads orogit's config file unchanged.
- `-delrepo NAME --yes` moves a repository to `repos/.trash/` (never destroys
  it) and deletes its pages; `-rename OLD NEW` renames one with its
  permissions. Both can be finished by running them again after a crash.
- Housekeeping: while serving, `git gc` runs every `gc_hours` hours (config,
  default 24, 0 is off) on repositories with loose objects or several packs;
  `-gc` runs a pass now.
- `TCP_NODELAY` on every connection: no 40 ms Nagle stall per kept-alive
  request.
- SHA-512 comes from m31 0.7.0's `lib/crypto/sha512`.
- `install.sh --source URL [--sha256 HASH]` builds from a source tarball (for
  example a hoard server's own tag tarball) with the m31 release named in
  `M31_VERSION` and the system C compiler. CI reads the same file.
- Tag tarballs: `/<repo>/archive/<tag>.tar.gz` streams `git archive` in
  constant memory, with the pages' access rules; strict tag names (no `/`,
  no leading `-`, no `..`) are checked before git runs. The summary page
  links each tag's tarball.
- Per-user access tokens for scripts and CI: `-token USER NAME [--read-only]`
  prints a `hoard_` token once, `-tokens` and `-revoke-token` manage them.
  Only a SHA-256 is stored, under the user in the config; a token logs in
  wherever the password does, never with more than the user's grants.
