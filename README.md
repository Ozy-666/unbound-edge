# unbound-edge

Build tooling and configuration for a **BoringSSL-linked, Zen 2-optimised Unbound**,
as deployed on the [dnsdoh.art](https://dnsdoh.art) edge resolver (AMD EPYC 7542,
Debian, KVM VPS).

Currently running **Unbound 1.26.1** (16 September 2026) against a pinned BoringSSL.

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
re-measure afterwards, since the library was chosen on measured performance rather
than assumed parity.

#### Verifying a bump did not cost performance

`bench/` answers that directly. Unbound's whole exposure to BoringSSL is RRSIG
verification, so the question is not how fast the resolver answers — that is mostly
network — but whether *this* libcrypto verifies signatures as fast as the one it
replaced:

```sh
bench/run-verify-bench.sh /opt/boring.bak.<timestamp> /opt/boring
```

The bump leaves the previous library in `/opt/boring.bak.<timestamp>`, which is what
makes the comparison possible. The script builds the same benchmark against both
prefixes, checks each binary really loads the library it was built for, and runs them
interleaved and pinned to one core so drift lands on both equally. It reports a median
and a win count over 8 paired rounds, because the run-to-run spread on a live box is a
few percent — larger than most differences worth caring about. Every iteration asserts
the signature actually verifies, so a library cannot post a good number by verifying
wrongly.

**2026-08-01, `8b43ff0f` → `fd490c05` (0.20260713.0 → 0.20260730.0):**

| Primitive | Old | New | Δ median | New faster in |
|---|---|---|---|---|
| ECDSA P-256 verify (alg 13) | 16,043/s | 16,130/s | +0.5% | 6/8 rounds |
| RSA-2048 verify (alg 8) | 53,986/s | 54,028/s | +0.1% | 4/8 rounds |
| RSA-1024 verify (legacy ZSK) | 154,292/s | 153,497/s | −0.5% | 4/8 rounds |

Parity. Every delta is inside the noise floor and no primitive regressed. Correctness
re-checked end-to-end on the live resolver at the same time: ECDSA and RSA chains
(`cloudflare.com`, `nlnetlabs.nl`, `internetsociety.org`) validate with the `ad` flag,
and `dnssec-failed.org` still returns SERVFAIL.

**2026-09-05, `30a26e97` → `0ce57bbf` (0.20260803.0 → 0.20260903.0), 15 rounds:**

| Primitive | Old | New | Δ median | New faster in |
|---|---|---|---|---|
| ECDSA P-256 verify (alg 13) | 16,122/s | 16,294/s | +1.1% | 12/15 rounds |
| RSA-2048 verify (alg 8) | 54,542/s | 53,597/s | −1.7% | 6/15 rounds |
| RSA-1024 verify (legacy ZSK) | 156,527/s | 154,904/s | −1.0% | 4/15 rounds |

No regression — but the median deltas alone do not establish that, and the script's own
"inside the run-to-run spread" verdict is a hardcoded assumption rather than something it
measured. What settles it is running the harness with **the same prefix on both sides**,
giving the deltas an identical library produces: +0.1%, 0.0%, −0.4%, at 7/15, 6/15 and
6/15 rounds — no systematic advantage to either slot. Against that null, the −1.7%
RSA-2048 "regression" has a win count of 6/15, *identical* to what the library scores
against itself (sign test p = 0.61): no directional evidence at all. The ECDSA gain at
12/15 (p = 0.035) is the only result standing apart from the null, and at n=15 that is
marginal.

Run the null control before believing a result in either direction. A harness reporting
no difference and a harness unable to detect a difference look the same from outside.

A first attempt at three rounds appeared to show ECDSA consistently ~2.6% slower; at
eight rounds that reversed. Three samples is not enough to separate a real change from
scheduler noise, which is why the default is higher.

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
bench/run-verify-bench.sh             A/B two BoringSSL builds on DNSSEC verify
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
prove nothing — see [The NLnet Labs release key](#the-nlnet-labs-release-key) for where
that key comes from and what it is actually worth. For reference, 1.26.1 is
`35a6dc0e425a9282c3426d9a3043144011bf0534aed4b73ab62c52aee0af1503`.

### The NLnet Labs release key

Why it is imported, and what that is worth.

The SHA256 check above is fetched from `nlnetlabs.nl` over HTTPS — the same host that
serves the tarball. It proves the download was not corrupted in transit. It proves
nothing if that host is the thing compromised: whoever can replace
`unbound-latest.tar.gz` can replace `unbound-<version>.tar.gz.sha256` in the same breath.
The PGP signature is the only link in the chain without that weakness, and it is worth
nothing until the signing key is known from somewhere else.

The signature on 1.26.1 names:

```
Signature made Wed Sep 16 10:37:18 2026 EEST
      using RSA key 231018690C4D903EF419146AA144323DEAACDF45
      "NLnet Labs releases signing key G2 <releases@nlnetlabs.nl>"
```

That fingerprint is **self-asserted**: an attacker who swapped the tarball would swap the
`.asc` alongside it and name their own key. It has to be corroborated from outside the
download path. What is actually available, re-checked 2026-09-16:

| Channel | Result |
|---|---|
| `OPENPGPKEY` record under `nlnetlabs.nl` | none published |
| Web Key Directory (`/.well-known/openpgpkey/`) | HTTP 404, no `openpgpkey.` host |
| Already present in a local or `/etc/apt` keyring | no |
| Debian `unbound` 1.26.0-2 `debian/upstream/signing-key.asc` | **matches** `2310…DF45` |
| Ubuntu `unbound` 1.19.2 `debian/upstream/signing-key.asc` | a different key — see below |

The DNS route is the one worth wanting: NLnet Labs' zone is DNSSEC-signed and this host
runs a validating resolver, so an `OPENPGPKEY` record would have been an independently
anchored answer requiring no third party. It does not exist.

So the key is taken from **Debian's packaging of the same upstream version line** — a
different organisation, on different infrastructure from the download server:

```sh
curl -fsSLO https://sources.debian.org/data/main/u/unbound/1.26.0-2/debian/upstream/signing-key.asc
gpg --show-keys --with-fingerprint signing-key.asc
#   expect 2310 1869 0C4D 903E F419  146A A144 323D EAAC DF45
gpg --import signing-key.asc
```

**The strongest chain available on this host does not corroborate it.** `apt-get source
unbound` verifies against an archive key already trusted here, but Ubuntu ships 1.19.2 and
its packaging carries `EDFAA3F2CA4E6EB05681AF8E9F6F1C2D7E045F8D`,
`W.C.A. Wijngaards <wouter@nlnetlabs.nl>` — a personal key predating the rotation to an
organisational release key. G2 is **not cross-certified** by it; its only signature is its
own self-sig. Trust therefore does not transfer from the one key rooted in something
already installed. That is a real limitation, not a footnote.

**The key is imported but deliberately not marked trusted.** `gpg --verify` still prints
`[unknown]` and `WARNING: This key is not certified with a trusted signature`, and the
script keys off the exit status, which is `0` for a good signature from an uncertified
key. Setting ownertrust or locally signing it would silence a warning that is accurate:
one HTTPS fetch from a third party's source tree is not grounds for asserting the key
belongs to NLnet Labs.

**What the import buys:** it defeats a compromise of the `nlnetlabs.nl` download path,
which the SHA256 check alone does not. It does not defeat someone able to place a bad key
into Debian's packaging. That is the honest boundary.

Confirm the check can fail before trusting it to pass — a signature check that cannot
report a failure is indistinguishable from one that passes:

```sh
cp unbound-latest.tar.gz t.tar.gz
printf '\xff' | dd of=t.tar.gz bs=1 seek=500000 count=1 conv=notrunc status=none
gpg --verify unbound-latest.tar.gz.asc t.tar.gz   # must print BAD signature, exit 1
rm -f t.tar.gz
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

1. ~~No integrity check on the downloaded tarball.~~ **Fixed in both scripts.** SHA256 is
   verified against NLnet Labs before the archive is unpacked, and a mismatch aborts;
   PGP is checked when the signing key is already in the keyring — see
   [The NLnet Labs release key](#the-nlnet-labs-release-key) for its provenance and the
   limits of that corroboration. The block is
   duplicated rather than shared, deliberately — the OpenSSL script is the break-glass
   path and must stay runnable on its own.
2. **Brief resolution outage.** The service is stopped, three binaries are copied, then it
   is started — a short window with no resolver. Acceptable for a single-host edge, worth
   knowing before scripting it into anything automated.
3. **Backups accumulate.** Every run leaves five `.bak.<timestamp>` copies in `/usr/sbin/`
   and they are never pruned.
4. ~~The two scripts verify different things.~~ **Fixed — now at parity.** Both confirm
   the expected SSL linkage *before* swapping (the OpenSSL script aborts if it somehow
   produced a BoringSSL-linked binary, e.g. from a stale `./configure` cache), then check
   the live query and the DNSSEC `ad` flag afterwards.
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

## Security posture: Unbound 1.26.1

1.26.1 is a **consolidated security release fixing 9 CVEs**, published 16 September 2026.
Three of them miss this deployment because the feature is *not compiled in* or *not
configured*:

| Not reachable here | Why |
|---|---|
| CVE-2026-82720 | Use-after-free in the DoH stream cleanup path — DoH is **not built**: `HAVE_NGHTTP2` is undefined in `config.h` and `libnghttp2` does not appear in the deployed binary's `ldd` output |
| CVE-2026-78227 | Use-after-free in the DoQ stream output buffer on reset re-transmission — DNS-over-QUIC is **not built** (`HAVE_NGTCP2` undefined, no `--with-libngtcp2`) |
| CVE-2026-77955 | ZONEMD verification bypass window — ZONEMD applies to auth zones; none are configured and `unbound-control list_auth_zones` returns empty |

The remaining six **do** apply, and are the reason to upgrade promptly. They sit in the
validator and iterator — the paths a validating resolver exercises on every query:

| Applies here | Issue |
|---|---|
| CVE-2026-81642 | Heap buffer overflow and **possible remote code execution** when digesting DNSKEY. The most serious of the set for this deployment: DNSKEY digesting is on the validation path for every signed zone. |
| CVE-2026-81634 | Possible heap buffer overflow during DNSSEC canonicalisation |
| CVE-2026-85501 | "Retrap" — algorithmic-complexity attacks against DNSSEC validation |
| CVE-2026-82717 | CNAME synthesis could lead to heap corruption |
| CVE-2026-77860 | `serve-expired` can bypass `wait-limit` — `serve-expired: yes` is set here (confirmed live via `unbound-control get_option serve-expired`) |
| CVE-2026-80225 | Degradation of service from continuous queries on one TCP/DoT connection. There is no DoT listener and the TCP listener binds `127.0.0.1` only, so this is not reachable directly from the internet — but queries still arrive over it from the local forwarder, so the exposure is reduced, not removed. |

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

The scripts, configuration and documentation in this repository are © 2026 Ozy-666
and released under the **2-clause BSD License** — see [`LICENSE`](LICENSE).

This repository contains no Unbound or BoringSSL source: the build scripts fetch
both at build time from their own upstreams.

Unbound is © NLnet Labs, under the 3-clause BSD License.
BoringSSL is © Google, under its own licence terms.
