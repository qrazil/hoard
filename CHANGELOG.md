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
