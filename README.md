# unbound-edge

Build tooling and configuration for a **BoringSSL-linked, Zen 2-optimised Unbound**,
as deployed on the [dnsdoh.art](https://dnsdoh.art) edge resolver (AMD EPYC 7542,
Debian, KVM VPS).

Currently running **Unbound 1.25.2** (22 July 2026) against a pinned BoringSSL.

> **This is not a fork of Unbound.** No upstream source is patched or vendored here —
> every customisation lives in build flags, configuration, and the systemd unit.
> `unbound-update.sh` downloads the official NLnet Labs tarball at build time, so
> there is no source tree to re-sync on each release and nothing to merge. If you
> want the upstream code, get it from
> [NLnetLabs/unbound](https://github.com/NLnetLabs/unbound).

Part of the `adguardhome-edge` stack behind [dnsdoh.art](https://dnsdoh.art):

```
AGH-Edge   443 DoH + DoH3 · 853 DoT + DoQ · 53 plain
  └─> Unbound  127.0.0.1:5353   ← this repo (DNSSEC validation)
        └─> dnscrypt-proxy  127.0.0.1:5053
              └─> Cloudflare DoH · Quad9 DNSCrypt
```

Unbound here is a **validating forwarder**, not a full recursor: it validates DNSSEC
locally but hands recursion to
[dnscrypt-proxy](https://github.com/Ozy-666/dnscrypt-proxy), which carries queries
out encrypted. Related repos:
[dnscrypt-proxy fork](https://github.com/Ozy-666/dnscrypt-proxy) ·
[AdGuardHome-edge-spec](https://github.com/Ozy-666/AdGuardHome-edge-spec).

---

## Why BoringSSL

On this EPYC 7542 (Zen 2), an end-to-end signed-miss flood measured BoringSSL against
the system OpenSSL 3.0.16:

| Metric | Result |
|---|---|
| Unbound crypto CPU | ~44% → ~39% |
| Worst-case DNSSEC throughput | **+14%** |
| Worst-case DNSSEC latency | **−27%** |

The gain comes from BoringSSL's fiat-crypto EC implementation and the absence of
OpenSSL 3.x's provider-dispatch tax. Validation correctness was verified against real
RSA and ECDSA chains, and `dnssec-failed.org` correctly returns SERVFAIL.

**Isolation.** BoringSSL is a *private* shared build in `/opt/boring` at a pinned
commit. Nothing system-wide is touched — Unbound finds it through a baked-in RUNPATH,
so no `LD_LIBRARY_PATH` is needed. If BoringSSL ever causes trouble,
`unbound-update-openssl.sh` rebuilds against the system OpenSSL unchanged.

### BoringSSL is pinned, not tracked — bumping is opt-in

`/opt/boring` is pinned and **only rebuilds if it is missing**, so a routine Unbound
security update does *not* silently swap the crypto library underneath it. To move to
the latest BoringSSL **release tag**:

```sh
BORING_UPDATE=1 ./unbound-update.sh
```

That resolves the newest `N.N.N` tag (release points, not rolling `main` — the same
policy `nginx-update.sh` uses), backs up the previous `/opt/boring`, rebuilds the shared
libs, **and rebuilds Unbound against them in the same run**. That last part is not
optional: BoringSSL offers **no stable ABI**, so `/opt/boring` must never be updated
without recompiling Unbound against the new headers. The script prints a reminder to
re-run the signed-miss flood afterwards, since the library was chosen on measured
performance rather than assumed parity.

Unbound's exposure to BoringSSL is **libcrypto only** (DNSSEC signature verification).
This config runs no TLS at all: no `tls-upstream`, no DoT/DoH listeners — it forwards
plaintext to dnscrypt-proxy on `127.0.0.1@5053`, which terminates the encryption. TLS-path
CVEs in BoringSSL therefore do not reach this daemon.

> **Note for the wider stack:** nginx on the same host uses a *separate*
> `boringssl-nginx` checkout that tracks the latest BoringSSL **tag** and links
> `libssl.a`/`libcrypto.a` statically. That is intentional — different directory,
> different linkage, different update policy, no collision with `/opt/boring`.

---

## Layout

```
unbound-update.sh                     build + swap against pinned BoringSSL
unbound-update-openssl.sh             fallback: rebuild against system OpenSSL
conf/unbound.conf                     the deployed server config
conf/unbound-remote-control.conf      unbound-control setup (keys NOT included)
systemd/unbound.service.d/override.conf  jemalloc preload, limits, hardening
docs/edge-tuning-notes.md             NIC/sysctl tuning + rollback
```

## Build and deploy

```sh
./unbound-update.sh
```

The script is version-agnostic — it fetches `unbound-latest.tar.gz`, so it picks up new
releases with no edit. It will:

1. Ensure the pinned BoringSSL exists in `/opt/boring` (idempotent; builds only if absent).
2. Pre-flight the jemalloc `LD_PRELOAD` override.
3. Download and unpack the latest Unbound.
4. Configure against BoringSSL with `-march=znver2 -O3 -flto`, PIE and RELRO-now.
5. Undefine `HAVE_OPENSSL_ENGINE_H` — BoringSSL has no ENGINE support, but `configure`
   detects the *system* header, which otherwise breaks `crypt_openssl.c`.
6. Build the daemon and control tools, validate against the **live** config, and abort
   before swapping if either the config check or the BoringSSL linkage check fails.
7. Back up the current binaries, swap, restart, and verify.

The tarball is verified automatically before it is unpacked or built (step 2b): the
version is detected from the archive, the matching `.sha256` is fetched from NLnet Labs,
and **a mismatch aborts the run**. Only versioned checksums are published — 
`unbound-latest.tar.gz.sha256` is a 404 — which is why the version is resolved first.
The PGP signature is checked too when the signing key is already in your keyring; a
missing key warns rather than aborts, since importing a key over the same channel would
prove nothing. For reference, 1.25.2 is
`0d92275c703d5f5f8baba3dab22117dd8c29b495588a5c229768ed6581566600`.

### Two binaries are deliberately NOT replaced

- **`unbound-anchor`** — BoringSSL lacks PKCS#7, so it is not rebuilt. The system
  (OpenSSL) binary is preserved for root-key bootstrap; in-daemon RFC 5011 refresh is
  unaffected.
- **`unbound-host`** — the build-tree `./unbound-host` is a *libtool wrapper script*,
  not a binary (the real one lives in `.libs/` and is only relinked by `make install`).
  Copying the wrapper bricked the tool once, requiring a restore from a distro backup.
  It is a diagnostic tool and gains nothing from BoringSSL.

### Rollback

```sh
cp /usr/sbin/unbound.bak.<timestamp> /usr/sbin/unbound && systemctl restart unbound
# or, to leave BoringSSL entirely:
./unbound-update-openssl.sh
```

---

## Reusing this on another host — read first

**These scripts are written for one specific machine and are not portable as-is.**
They are published because the *approach* is reusable and the trade-offs are
documented, not because they are a drop-in installer. Running either script unmodified
on a different box will, at best, waste your time and, at worst, replace working system
binaries with ones that will not execute.

| Assumption | Where | What breaks elsewhere |
|---|---|---|
| `-march=znver2 -mtune=znver2` | both scripts | **The big one.** Binaries built for AMD Zen 2 crash with `SIGILL` on other microarchitectures. Change to `-march=native`, or drop it, before building anywhere else. |
| `/root/nginx-build/unbound-auto` build dir, `/root/nginx-build/boringssl` source | both | Hardcoded to this host's layout. Nothing auto-creates the parent. |
| `--with-conf-file=/etc/unbound/unbound.conf.d/unbound.conf` | both | Non-standard: most distros use `/etc/unbound/unbound.conf`. The binary bakes this path in as its default. |
| Binaries copied into `/usr/sbin/` | both | **Overwrites your distro's package-managed binaries.** A later `apt upgrade` of the `unbound` package silently reverts the custom build. There is no packaging step here. |
| `systemctl stop/start unbound`, `Type=notify`, systemd drop-in | both | systemd-only. |
| `dig @127.0.0.1 -p 5353` verification | both | Hardcodes this deployment's port. |
| `LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2` | systemd drop-in | Debian/Ubuntu amd64 multiarch path. |
| Runs as root, no `set -u`, no confirmation prompt | both | Assumes an operator who has read the script. |

If you want the same result on your own hardware, the honest advice is to **read the
scripts and adapt the configure line**, rather than run them. The parts genuinely worth
copying are the BoringSSL linkage approach, the `HAVE_OPENSSL_ENGINE_H` workaround, the
two binaries that must not be swapped, and the validate-before-swap ordering.

### Review notes / known rough edges

An honest list of what these scripts do *not* do, for anyone considering them:

1. ~~No integrity check on the downloaded tarball.~~ **Fixed** in `unbound-update.sh`:
   SHA256 is now verified against NLnet Labs before the archive is unpacked, and a
   mismatch aborts. **The OpenSSL fallback still has no verification** — check it by hand
   if you use that path.
2. **Brief resolution outage.** The service is stopped, three binaries are copied, then it
   is started — a short window with no resolver. Acceptable for a single-host edge, worth
   knowing before scripting it into anything automated.
3. **Backups accumulate.** Every run leaves five `.bak.<timestamp>` copies in `/usr/sbin/`
   and they are never pruned.
4. **The two scripts verify different things.** The BoringSSL script checks the linkage,
   runs a live query and confirms the DNSSEC `ad` flag; the OpenSSL fallback checks neither
   the linkage nor DNSSEC. If you rely on the fallback, verify by hand afterwards.
5. **`make -j` vs targeted targets.** The OpenSSL script builds everything; the BoringSSL
   one builds only the four needed targets. The latter is deliberate — see the
   `unbound-anchor` note above.
6. ~~Replacing `/opt/boring/lib/*.so` crashed the running daemon.~~ **Fixed.** `cp`
   truncates and rewrites the *existing* inode, which is still `mmap`'d by the live
   Unbound — the daemon took a `SIGSEGV` the first time a BoringSSL bump was run
   (2026-07-25 23:28:50), and only `Restart=always` in the systemd drop-in kept the
   resolver up. The libraries are now written to a temp name and `rename(2)`-d into
   place, so the running process keeps its old inode until it is restarted.
7. ~~A failed download could strand the host mid-upgrade.~~ **Fixed.** The BoringSSL bump
   used to run *before* the Unbound tarball was fetched, so a transient download failure
   (seen the same day — `nlnetlabs.nl` returned 0 bytes and `set -e` exited) left a new
   crypto library behind an Unbound binary linked for the old one. Everything that can
   fail cheaply now runs first; `/opt/boring` is touched only after the tarball is
   downloaded and verified.

---

## Security posture: Unbound 1.25.2

1.25.2 is a **security release fixing 24 CVEs**. Two whole CVE clusters miss this
deployment because the features are *not compiled in* — there is no `--with-libngtcp2`
(no DNS-over-QUIC) and no `--enable-dnscrypt`:

| Not reachable here | Why |
|---|---|
| CVE-2026-14586, -32665, -41637, -55991 | DNS-over-QUIC — not built |
| CVE-2026-40691, -55990 | DNSCrypt — not built |
| CVE-2026-50046 | DoT forwarding — no `tls-upstream` configured |
| CVE-2026-50243, -50248, -55717 | needs `response-ip` / `rpz` / auth zones — none configured |
| CVE-2026-54478 | needs `proxy-protocol` — not configured |
| CVE-2026-55973 | needs `dns-error-reporting: yes` — default off |
| CVE-2026-55708 | needs `views` with `unbound-control` local data — not configured |
| CVE-2026-44621 | affects **libunbound applications**; this host runs the daemon |

The rest **do** apply to this configuration and are the reason to upgrade promptly —
cache-poisoning and memory-safety issues in the validator and iterator, which are
exactly the paths a validating recursor exercises on every query:

| Applies here | Issue |
|---|---|
| CVE-2026-56416 | heap buffer overflow canonicalising RDATA containing a domain name |
| CVE-2026-52863 | memory corruption → crash / DoS |
| CVE-2026-44690 | cross-zone wildcard cache poisoning via `RRSIG.labels` manipulation |
| CVE-2026-46582 | wildcard replay poisoning in the serve-expired path (`serve-expired: yes`) |
| CVE-2026-50252 | cache poisoning by mapping source-port population per thread |
| CVE-2026-50251 | attacker-supplied `0.0.0.0`/`::` glue triggers a defensive full-cache flush |
| CVE-2026-42955 | A/AAAA TTL clamp — 'ghost domain' delegation renewal via glue |
| CVE-2026-44687 | off-by-one in `harden-below-nxdomain` can shadow a stub/forward zone |
| CVE-2026-50045 | `max-global-quota` reset by DNSSEC validation restarts |
| CVE-2026-56444 | `discard-timeout` + `serve-expired-client-timeout` interaction |

> This table is **operational triage** for this specific build and config, derived from
> the configure flags and `conf/unbound.conf` — not an upstream advisory. Check the
> [NLnet Labs advisories](https://www.nlnetlabs.nl/projects/unbound/security-advisories/)
> before relying on it for a different deployment. "Not reachable" means *not reachable
> in this configuration*; enabling any of those features changes the answer.

---

## Configuration notes

The resolver listens on `127.0.0.1:5353` only and forwards to dnscrypt-proxy — it is not
internet-facing. Highlights:

- **Validating recursor**: `module-config: "validator iterator"`, auto trust anchor,
  `harden-*` hardening, `aggressive-nsec`, `qname-minimisation`.
- **Cache**: 256M msg / 512M rrset with 8 slabs each, `prefetch` + `prefetch-key`,
  `serve-expired` with a 500 ms client timeout.
- **Privacy**: `hide-identity`, `hide-version`, `deny-any`, no query/reply logging.
- **Threads**: 4 (one per vCPU), `so-reuseport`, 8 MB socket buffers.
- **EDNS**: buffer 1232 to stay under the fragmentation threshold.

`conf/unbound.conf` is the deployed file verbatim. The `access-control` entry for the
host's own public address is kept as-is — `dnsdoh.art` already resolves to it publicly,
and the listener binds to loopback regardless, so it discloses nothing new. Substitute
your own address, or drop the line, when reusing this config.

`conf/unbound-remote-control.conf` references key/cert files that are **not** in this
repo. Generate them locally:

```sh
unbound-control-setup -d /etc/unbound/unbound.conf.d
```

## Runtime tuning

`systemd/unbound.service.d/override.conf` supplies jemalloc via `LD_PRELOAD` — Unbound
has no jemalloc configure flag, and the old `--with-libjemalloc` flag was a silent no-op
that left glibc malloc in place. `MALLOC_CONF=narenas:4,background_thread:true` gives one
arena per worker thread and moves page purging off the query hot path.

Host-level NIC and sysctl tuning, including what was investigated and deliberately *not*
changed, is in [`docs/edge-tuning-notes.md`](docs/edge-tuning-notes.md).

## License

Unbound itself is BSD-licensed by NLnet Labs. The scripts and configuration here are
provided as-is.
