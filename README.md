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
AGH-Edge (DoH 444 / DoT 853 / plain 53)
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

### BoringSSL is pinned, not tracked

`/opt/boring` is pinned to a specific commit and **only rebuilds if it is missing**, so
an Unbound upgrade does *not* silently pull in a new BoringSSL. Bumping the pin is a
deliberate act — the library was chosen on measured performance, so re-run the DNSSEC
flood after any bump rather than assuming parity.

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

Verify the release tarball before a security update:

```sh
sha256sum unbound-1.25.2.tar.gz
# 0d92275c703d5f5f8baba3dab22117dd8c29b495588a5c229768ed6581566600
```

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

1. **No integrity check on the downloaded tarball.** Both fetch
   `unbound-latest.tar.gz` over HTTPS and build and install it as root without verifying
   the published SHA256 or the PGP signature. TLS alone authenticates the *host*, not the
   artefact. For a workflow whose entire purpose is applying security updates, this is the
   weakest link — verify manually until it is scripted:
   ```sh
   sha256sum unbound-latest.tar.gz   # compare with nlnetlabs.nl/downloads/unbound/
   ```
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
