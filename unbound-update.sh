#!/bin/bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Ozy-666 (https://dnsdoh.art)
# ============================================================================
# unbound-update.sh — build latest Unbound against a PINNED private BoringSSL
# ============================================================================
# Published at https://github.com/Ozy-666/unbound-edge — for the resolver
# behind https://dnsdoh.art
#
# ⚠️  HOST-SPECIFIC — NOT A PORTABLE INSTALLER. Written for one machine:
#   * -march=znver2 : AMD Zen 2 only. Binaries SIGILL on other CPUs.
#   * Hardcoded paths: /root/nginx-build/{unbound-auto,boringssl}, and the
#     non-standard conf file /etc/unbound/unbound.conf.d/unbound.conf.
#   * Copies binaries over the DISTRO'S /usr/sbin/unbound — a later
#     `apt upgrade` of the unbound package silently reverts this build.
#   * Assumes systemd, Debian-ish layout, root, and port 5353.
#   * Does NOT verify the tarball's SHA256/PGP signature — check it by hand
#     against nlnetlabs.nl before trusting a security update.
# Read it and adapt the configure line rather than running it elsewhere.
# See the README's "Reusing this on another host" section.
# ============================================================================
# Why BoringSSL: on this AMD EPYC 7542 (Zen 2), an end-to-end signed-miss flood
# showed BoringSSL cuts unbound's crypto CPU ~44%->~39% and lifts worst-case
# DNSSEC throughput ~+14% / latency -27% vs system OpenSSL 3.0.16 (the gain is
# from BoringSSL's fiat-crypto EC + zero provider-dispatch tax). Validation
# correctness verified on real RSA+ECDSA chains and dnssec-failed.org (SERVFAIL).
#
# Isolation/safety:
#  - BoringSSL is a PRIVATE shared build in /opt/boring (pinned commit), NOTHING
#    in the system is touched. unbound finds it via baked-in RUNPATH (no
#    LD_LIBRARY_PATH needed).
#  - unbound-anchor is NOT rebuilt (BoringSSL lacks PKCS7); the system
#    unbound-anchor is PRESERVED for root-key bootstrap. In-daemon RFC5011
#    refresh still works.
#  - Fallback: /root/nginx-build/unbound-update-openssl.sh rebuilds against the
#    system OpenSSL exactly as before, if BoringSSL ever causes trouble.
# ============================================================================
set -e

BUILD_DIR="/root/nginx-build/unbound-auto"
BORING_SRC="/root/nginx-build/boringssl"
BORING_PREFIX="/opt/boring"
BORING_PIN="$(cat ${BORING_PREFIX}/COMMIT 2>/dev/null || echo ef4f3c2197f90c96a44716aedaac55a10cb4e479)"
CPU_CORES=$(nproc)
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# 0. Ensure the pinned BoringSSL is built into /opt/boring (idempotent)
# ---------------------------------------------------------------------------
# build_boringssl <git-ref> — build the shared libs at <ref> and stage them
# into $BORING_PREFIX, recording the exact commit in $BORING_PREFIX/COMMIT.
build_boringssl() {
    local ref="$1"
    if [ ! -d "$BORING_SRC/.git" ]; then
        git clone https://boringssl.googlesource.com/boringssl "$BORING_SRC"
    fi
    cd "$BORING_SRC"
    git fetch --depth 1 origin "$ref" 2>/dev/null || git fetch --tags origin 2>/dev/null || true
    git checkout -q "$ref" 2>/dev/null || git checkout -q FETCH_HEAD
    local resolved
    resolved=$(git rev-parse HEAD)
    rm -rf build && mkdir build && cd build
    cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=1 .. >/dev/null
    make -j"$CPU_CORES" crypto ssl >/dev/null
    ls libcrypto.so libssl.so >/dev/null || { echo "❌ BoringSSL shared libs missing — abort"; exit 1; }
    mkdir -p "${BORING_PREFIX}/include" "${BORING_PREFIX}/lib"
    rm -rf "${BORING_PREFIX}/include/openssl"
    cp -r "${BORING_SRC}/include/"* "${BORING_PREFIX}/include/"
    # Install the shared libs ATOMICALLY. `cp` truncates and rewrites the
    # EXISTING inode, which is still mmap'd by the running unbound — that
    # SIGSEGVs the live daemon (observed 2026-07-25 23:28:50, caught only by
    # Restart=always). Writing a temp file and rename(2)-ing it over the old
    # name swaps the directory entry while the running process keeps its old
    # inode until it is restarted below.
    local lib
    for lib in libcrypto.so libssl.so; do
        cp "${BORING_SRC}/build/${lib}" "${BORING_PREFIX}/lib/.${lib}.new"
        mv -f "${BORING_PREFIX}/lib/.${lib}.new" "${BORING_PREFIX}/lib/${lib}"
    done
    echo "$resolved" > "${BORING_PREFIX}/COMMIT"
    echo "✅ BoringSSL staged to ${BORING_PREFIX} (${resolved})"
}

# BoringSSL is PINNED by default: a routine Unbound security update must not
# silently swap the crypto library underneath it. Opt in explicitly with:
#     BORING_UPDATE=1 ./unbound-update.sh
# BoringSSL has NO stable ABI and no support cadence — it is a rolling branch,
# so /opt/boring must never be bumped without rebuilding Unbound against the
# new headers. Doing both in this one run is precisely why that is safe here.
# The library was chosen on measured DNSSEC performance, so after a bump re-run
# the signed-miss flood rather than assuming parity.
BORING_UPDATE="${BORING_UPDATE:-0}"

# do_boringssl — called AFTER the Unbound tarball is downloaded and verified.
# Ordering matters: bumping /opt/boring first and only then discovering the
# download failed leaves the box with a NEW crypto library and an Unbound
# binary linked for the OLD one (hit 2026-07-25 — a transient nlnetlabs.nl
# fetch returned 0 bytes and `set -e` exited mid-way). Everything that can
# fail cheaply now runs before anything that mutates /opt/boring.
do_boringssl() {
if [ "$BORING_UPDATE" = "1" ]; then
    echo "==== 2c. BoringSSL — updating to latest RELEASE TAG (BORING_UPDATE=1) ===="
    # Latest release tag, not main HEAD: tags are release points, and this
    # matches the policy nginx-update.sh already uses for boringssl-nginx.
    BORING_TAG=$(git ls-remote --tags --sort=-v:refname https://github.com/google/boringssl 2>/dev/null \
        | grep -oE 'refs/tags/[0-9]+\.[0-9]+\.[0-9]+$' | sed 's#refs/tags/##' | head -n1)
    [ -n "$BORING_TAG" ] || { echo "❌ Could not resolve a BoringSSL release tag — abort"; exit 1; }
    OLD_COMMIT=$(cat "${BORING_PREFIX}/COMMIT" 2>/dev/null || echo "none")
    echo "    current: ${OLD_COMMIT}"
    echo "    latest tag: ${BORING_TAG}"
    if [ -d "${BORING_PREFIX}" ]; then
        BORING_BAK="${BORING_PREFIX}.bak.$(date +%Y%m%d_%H%M)"
        cp -a "${BORING_PREFIX}" "${BORING_BAK}"
        echo "    previous /opt/boring backed up to ${BORING_BAK}"
    fi
    build_boringssl "refs/tags/${BORING_TAG}"
    BORING_BUMPED=1
elif [ -f "${BORING_PREFIX}/lib/libcrypto.so" ] && [ -f "${BORING_PREFIX}/lib/libssl.so" ]; then
    echo "==== 2c. BoringSSL (pinned ${BORING_PIN}) ===="
    echo "✅ /opt/boring present (commit $(cat ${BORING_PREFIX}/COMMIT 2>/dev/null))"
    echo "   (run with BORING_UPDATE=1 to move to the latest BoringSSL release tag)"
else
    echo "==== 2c. BoringSSL (pinned ${BORING_PIN}) ===="
    echo "⚠️  /opt/boring missing — building BoringSSL from pinned source..."
    build_boringssl "$BORING_PIN"
fi
grep -q OPENSSL_IS_BORINGSSL "${BORING_PREFIX}/include/openssl/base.h" || { echo "❌ /opt/boring is not BoringSSL — abort"; exit 1; }
}

# ---------------------------------------------------------------------------
# 1. jemalloc preload pre-flight (jemalloc is via LD_PRELOAD, not a build flag)
# ---------------------------------------------------------------------------
echo "==== 1. jemalloc preload pre-flight ===="
OVERRIDE="/etc/systemd/system/unbound.service.d/override.conf"
JEMALLOC_LIB=$(ldconfig -p 2>/dev/null | awk '/libjemalloc\.so\.2/{print $NF; exit}')
PRELOAD_LIB=$(grep -hoP 'LD_PRELOAD=\K\S*libjemalloc\S*' "$OVERRIDE" 2>/dev/null | head -1)
if [ -z "$JEMALLOC_LIB" ]; then
    echo "⚠️  libjemalloc.so.2 not found — install libjemalloc2."
elif [ -z "$PRELOAD_LIB" ]; then
    echo "⚠️  $OVERRIDE has no LD_PRELOAD jemalloc line."
else
    echo "✅ jemalloc preload ready: $PRELOAD_LIB"
fi

# ---------------------------------------------------------------------------
# 2. Fetch latest stable Unbound
# ---------------------------------------------------------------------------
cd "$BUILD_DIR"
echo "==== 2. Downloading latest Unbound ===="
wget -qO unbound-latest.tar.gz https://nlnetlabs.nl/downloads/unbound/unbound-latest.tar.gz
DIR_NAME=$(tar -tzf unbound-latest.tar.gz | head -1 | cut -f1 -d"/")
LATEST_VER=${DIR_NAME#unbound-}

# ---------------------------------------------------------------------------
# 2b. Verify the tarball BEFORE unpacking or building it as root.
#     HTTPS authenticates nlnetlabs.nl, not the artefact. Only versioned
#     checksums are published (unbound-latest.tar.gz.sha256 is a 404), so the
#     version is detected from the archive first, then its checksum fetched.
#     SHA256 mismatch is FATAL. PGP is checked when a keyring already trusts
#     the signer; a missing key warns rather than aborting (importing a key
#     fetched over the same channel would prove nothing).
# ---------------------------------------------------------------------------
echo "==== 2b. Verifying unbound-${LATEST_VER}.tar.gz ===="
BASE_URL="https://nlnetlabs.nl/downloads/unbound"
EXPECTED_SHA=$(curl -fsSL "${BASE_URL}/unbound-${LATEST_VER}.tar.gz.sha256" 2>/dev/null \
    | grep -oiE '[0-9a-f]{64}' | head -1)
ACTUAL_SHA=$(sha256sum unbound-latest.tar.gz | cut -d' ' -f1)
if [ -z "$EXPECTED_SHA" ]; then
    echo "❌ Could not fetch the published SHA256 for ${LATEST_VER} — refusing to build."
    echo "   Check ${BASE_URL}/ by hand; do not skip this on a security update."
    exit 1
fi
if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "❌ SHA256 MISMATCH — the tarball is NOT what upstream published. Aborting."
    echo "   expected: $EXPECTED_SHA"
    echo "   actual:   $ACTUAL_SHA"
    exit 1
fi
echo "✅ SHA256 verified: $ACTUAL_SHA"

if command -v gpg >/dev/null 2>&1 \
   && curl -fsSL -o unbound-latest.tar.gz.asc "${BASE_URL}/unbound-${LATEST_VER}.tar.gz.asc" 2>/dev/null; then
    GPG_OUT=$(gpg --verify unbound-latest.tar.gz.asc unbound-latest.tar.gz 2>&1) && GPG_RC=0 || GPG_RC=$?
    if [ "$GPG_RC" -eq 0 ]; then
        echo "✅ PGP signature verified"
    elif echo "$GPG_OUT" | grep -qiE "No public key|no public key"; then
        echo "⚠️  PGP signature present but the signing key is not in your keyring —"
        echo "    SHA256 already passed. To enable this check, import the NLnet Labs"
        echo "    release key from a channel you trust and re-run."
    else
        echo "❌ PGP VERIFICATION FAILED — aborting."
        echo "$GPG_OUT"
        exit 1
    fi
else
    echo "ℹ️  Skipping PGP check (gpg unavailable or signature not published)."
fi

# Tarball is present and verified — only now is it safe to touch /opt/boring.
do_boringssl
cd "$BUILD_DIR"

echo "⚠️  Building Unbound $LATEST_VER against BoringSSL (Zen 2)..."
tar -zxf unbound-latest.tar.gz
cd "$DIR_NAME"
make distclean 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Configure against BoringSSL
#    --disable-gost : BoringSSL has no GOST  |  RUNPATH so no LD_LIBRARY_PATH
# ---------------------------------------------------------------------------
echo "==== 3. Configuring (BoringSSL prefix ${BORING_PREFIX}) ===="
./configure \
    --prefix=/usr --sysconfdir=/etc \
    --with-conf-file=/etc/unbound/unbound.conf.d/unbound.conf \
    --with-run-dir=/var/lib/unbound --with-rootkey-file=/var/lib/unbound/root.key \
    --enable-subnet --enable-systemd --enable-tfo-client --enable-tfo-server \
    --with-libevent --with-pthreads --with-ssl="${BORING_PREFIX}" \
    --enable-pie --enable-relro-now --disable-gost \
    CFLAGS="-O3 -march=znver2 -mtune=znver2 -fomit-frame-pointer -flto -fstack-protector-strong" \
    LDFLAGS="-flto -Wl,-z,now -Wl,-rpath,${BORING_PREFIX}/lib"

# BoringSSL has no OpenSSL ENGINE support; configure detects the *system* header.
# Disable it so util/crypto/crypt_openssl.c compiles.
sed -i 's|#define HAVE_OPENSSL_ENGINE_H 1|/* #undef HAVE_OPENSSL_ENGINE_H */|' config.h

# ---------------------------------------------------------------------------
# 4. Compile daemon + control tools ONLY (skip unbound-anchor: needs PKCS7)
# ---------------------------------------------------------------------------
echo "==== 4. Compiling on $CPU_CORES cores (no unbound-anchor) ===="
make -j"$CPU_CORES" unbound unbound-checkconf unbound-control unbound-host

# ---------------------------------------------------------------------------
# 5. Validate new binary against the live config
# ---------------------------------------------------------------------------
echo "==== 5. Validating new binary against live config ===="
if ./unbound-checkconf /etc/unbound/unbound.conf.d/unbound.conf; then
    echo "✅ Config check passed."
else
    echo "❌ New binary failed config validation. Aborting swap."; exit 1
fi
./unbound -V 2>&1 | grep -qi BoringSSL || { echo "❌ Binary not linked to BoringSSL. Aborting."; exit 1; }

# ---------------------------------------------------------------------------
# 6. Backup & atomic swap (PRESERVE system unbound-anchor)
# ---------------------------------------------------------------------------
echo "==== 6. Backing up and swapping ===="
BACKUP_SUFFIX=".bak.$(date +%Y%m%d_%H%M)"
for bin in unbound unbound-control unbound-checkconf unbound-host unbound-anchor; do
    [ -f /usr/sbin/$bin ] && cp /usr/sbin/$bin "/usr/sbin/${bin}${BACKUP_SUFFIX}"
done
systemctl stop unbound
cp -f ./unbound          /usr/sbin/unbound
cp -f ./unbound-control  /usr/sbin/unbound-control
cp -f ./unbound-checkconf /usr/sbin/unbound-checkconf
# NOTE: unbound-host intentionally NOT replaced — the build-tree ./unbound-host
# is a LIBTOOL WRAPPER SCRIPT (real binary lives in ./.libs/ and only gets
# relinked by `make install`); copying the wrapper bricked the tool until the
# 2026-06-10 restore from the .bak.20260326 distro binary. The system (OpenSSL)
# unbound-host is preserved — it's a diagnostic tool, BoringSSL gains nothing.
# NOTE: unbound-anchor intentionally NOT replaced (BoringSSL lacks PKCS7).
systemctl start unbound

# ---------------------------------------------------------------------------
# 7. Verification
# ---------------------------------------------------------------------------
echo "==== 7. Verification ===="
sleep 1
/usr/sbin/unbound -V 2>&1 | grep -iE 'Version|Linked libs'
NEWPID=$(pgrep -x unbound | head -1)
if [ -n "$NEWPID" ] && grep -q '/opt/boring/lib/libcrypto.so' /proc/$NEWPID/maps 2>/dev/null; then
    echo "✅ BoringSSL libcrypto mapped in live process"
else
    echo "⚠️  BoringSSL NOT mapped — check RUNPATH / /opt/boring"
fi
if [ -n "$NEWPID" ] && grep -q jemalloc /proc/$NEWPID/maps 2>/dev/null; then
    echo "✅ jemalloc active (LD_PRELOAD)"
else
    echo "⚠️  jemalloc NOT mapped — check the systemd override"
fi
if dig @127.0.0.1 -p 5353 +short +time=2 +tries=1 cloudflare.com >/dev/null 2>&1; then
    echo "✅ Live query OK"
else
    echo "❌ Live query FAILED — investigate (rollback: restore /usr/sbin/unbound${BACKUP_SUFFIX} or run unbound-update-openssl.sh)"
fi
if dig @127.0.0.1 -p 5353 +dnssec +time=2 +tries=1 cloudflare.com 2>/dev/null | grep -q 'flags:.* ad'; then
    echo "✅ DNSSEC validation OK (ad flag)"
else
    echo "⚠️  No ad flag — verify DNSSEC validation"
fi
echo "🚀 Complete: Unbound $LATEST_VER on BoringSSL ($(cat ${BORING_PREFIX}/COMMIT))"
echo "   Rollback: cp /usr/sbin/unbound${BACKUP_SUFFIX} /usr/sbin/unbound && systemctl restart unbound"
echo "   Or full OpenSSL rebuild: /root/nginx-build/unbound-update-openssl.sh"
if [ "${BORING_BUMPED:-0}" = "1" ]; then
    echo ""
    echo "⚠️  BoringSSL was bumped this run: ${OLD_COMMIT} -> $(cat ${BORING_PREFIX}/COMMIT)"
    echo "    BoringSSL was chosen on MEASURED DNSSEC performance — re-run the"
    echo "    signed-miss flood before assuming this build is at least as fast."
    echo "    Rolling BoringSSL back also requires rebuilding unbound (no stable ABI):"
    echo "      rm -rf ${BORING_PREFIX} && cp -a ${BORING_BAK} ${BORING_PREFIX} && ./unbound-update.sh"
fi
