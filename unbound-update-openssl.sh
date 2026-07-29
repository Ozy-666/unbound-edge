#!/bin/bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Ozy-666 (https://dnsdoh.art)
# ============================================================================
# unbound-update-openssl.sh — FALLBACK build against the SYSTEM OpenSSL
# ============================================================================
# Use only if the BoringSSL build (unbound-update.sh) causes trouble; that one
# is the primary path and is ~14% faster on worst-case DNSSEC here.
#
# Published at https://github.com/Ozy-666/unbound-edge — for the resolver
# behind https://dnsdoh.art
#
# ⚠️  HOST-SPECIFIC — NOT A PORTABLE INSTALLER. Same caveats as
# unbound-update.sh: -march=znver2 (AMD Zen 2 only, SIGILL elsewhere),
# hardcoded /root/nginx-build paths, a non-standard conf-file location,
# binaries copied over the distro's /usr/sbin, and systemd assumed.
#
# Verification is at parity with unbound-update.sh: the tarball's SHA256 is
# checked against nlnetlabs.nl before it is unpacked (fatal on mismatch, with
# PGP when the signing key is trusted locally), the new binary's OpenSSL
# linkage is confirmed before the swap, and the live query plus the DNSSEC
# `ad` flag are checked afterwards.
# See the README's "Reusing this on another host" section.
# ============================================================================
set -e

BUILD_DIR="/root/nginx-build/unbound-auto"
mkdir -p $BUILD_DIR
cd $BUILD_DIR

# 1. Hardware & Environment Detection
CPU_CORES=$(nproc)
BIN_SERVER=$(which unbound || echo "/usr/sbin/unbound")

# 1b. jemalloc readiness pre-flight
# Unbound has no jemalloc configure option; it's provided at runtime via an
# LD_PRELOAD drop-in (see note at the configure step). Verify the pieces exist
# BEFORE the long build/swap so a missing lib or drop-in is caught early.
# Non-fatal: unbound still runs (on glibc malloc) if jemalloc is absent.
echo "==== 1b. jemalloc preload pre-flight ===="
OVERRIDE="/etc/systemd/system/unbound.service.d/override.conf"
JEMALLOC_LIB=$(ldconfig -p 2>/dev/null | awk '/libjemalloc\.so\.2/{print $NF; exit}')
PRELOAD_LIB=$(grep -hoP 'LD_PRELOAD=\K\S*libjemalloc\S*' "$OVERRIDE" 2>/dev/null | head -1)
if [ -z "$JEMALLOC_LIB" ]; then
    echo "⚠️  libjemalloc.so.2 not found via ldconfig — install it (e.g. 'apt-get install libjemalloc2') so the LD_PRELOAD drop-in can work."
elif [ -z "$PRELOAD_LIB" ]; then
    echo "⚠️  $OVERRIDE has no 'LD_PRELOAD=...libjemalloc' line — add 'Environment=LD_PRELOAD=$JEMALLOC_LIB' under [Service], then 'systemctl daemon-reload'."
elif [ "$(realpath -m "$PRELOAD_LIB" 2>/dev/null)" != "$(realpath -m "$JEMALLOC_LIB" 2>/dev/null)" ]; then
    # compare canonicalized paths so the /lib -> /usr/lib usr-merge symlink isn't a false mismatch
    echo "⚠️  $OVERRIDE LD_PRELOAD ($PRELOAD_LIB) doesn't resolve to the installed jemalloc ($JEMALLOC_LIB) — verify the path."
else
    echo "✅ jemalloc preload ready: $PRELOAD_LIB"
fi

# 2. Fetch Latest Stable
echo "==== 1. Downloading Latest Unbound ===="
wget -qO unbound-latest.tar.gz https://nlnetlabs.nl/downloads/unbound/unbound-latest.tar.gz

DIR_NAME=$(tar -tzf unbound-latest.tar.gz | head -1 | cut -f1 -d"/")
LATEST_VER=${DIR_NAME#unbound-}

# ---------------------------------------------------------------------------
# 1c. Verify the tarball BEFORE unpacking or building it as root.
#     HTTPS authenticates nlnetlabs.nl, not the artefact. Only versioned
#     checksums are published (unbound-latest.tar.gz.sha256 is a 404), so the
#     version is detected from the archive first, then its checksum fetched.
#     SHA256 mismatch is FATAL. PGP is checked when a keyring already trusts
#     the signer; a missing key warns rather than aborting.
#
#     Deliberately duplicated from unbound-update.sh rather than sourced from a
#     shared helper: this is the break-glass fallback and must stay runnable on
#     its own, even if the rest of the tooling is missing or broken.
# ---------------------------------------------------------------------------
echo "==== 1c. Verifying unbound-${LATEST_VER}.tar.gz ===="
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
    elif echo "$GPG_OUT" | grep -qiE "no public key"; then
        echo "⚠️  PGP signature present but the signing key is not in your keyring —"
        echo "    SHA256 already passed. Import the NLnet Labs release key from a"
        echo "    channel you trust to enable this check."
    else
        echo "❌ PGP VERIFICATION FAILED — aborting."
        echo "$GPG_OUT"
        exit 1
    fi
else
    echo "ℹ️  Skipping PGP check (gpg unavailable or signature not published)."
fi

echo "⚠️ Building Unbound $LATEST_VER for Zen 2..."
tar -zxf unbound-latest.tar.gz
cd $DIR_NAME

# Clean previous build if exists
make distclean 2>/dev/null || true

# 3. Configure with Zen 2 optimizations
# NOTE: jemalloc is NOT a configure option in Unbound — the old
# --with-libjemalloc flag was unrecognized and silently ignored, so every
# build before this ran on glibc malloc. jemalloc is now provided at runtime
# via LD_PRELOAD in /etc/systemd/system/unbound.service.d/override.conf.
echo "==== 2. Configuring for AMD EPYC 7542 (znver2) ===="

./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --with-conf-file=/etc/unbound/unbound.conf.d/unbound.conf \
    --with-run-dir=/var/lib/unbound \
    --with-rootkey-file=/var/lib/unbound/root.key \
    --enable-subnet \
    --enable-systemd \
    --enable-tfo-client \
    --enable-tfo-server \
    --with-libevent \
    --with-pthreads \
    --with-ssl=/usr \
    --enable-pie \
    --enable-relro-now \
    CFLAGS="-O3 -march=znver2 -mtune=znver2 -fomit-frame-pointer -flto -fstack-protector-strong" \
    LDFLAGS="-flto -Wl,-z,now"

# 4. Compile on all cores
echo "==== 3. Compiling using $CPU_CORES cores ===="
make -j$CPU_CORES

# 5. Pre-deployment Syntax Check
echo "==== 4. Validating New Binary against Live Config ===="
if ./unbound-checkconf /etc/unbound/unbound.conf.d/unbound.conf; then
    echo "✅ Config check passed."
else
    echo "❌ ERROR: New binary failed validation. Aborting swap."
    exit 1
fi
# Confirm this really is the OpenSSL build before swapping. Mirrors the
# BoringSSL check in unbound-update.sh — the whole point of this script is to
# get OFF BoringSSL, so silently producing another BoringSSL-linked binary
# (e.g. a stale ./configure cache picking up /opt/boring) would defeat it.
./unbound -V 2>&1 | grep -qi BoringSSL && {
    echo "❌ Binary is linked to BoringSSL, not the system OpenSSL. Aborting."
    echo "   Run 'make distclean' in $BUILD_DIR/$DIR_NAME and retry."
    exit 1
}
./unbound -V 2>&1 | grep -qi 'OpenSSL' || {
    echo "❌ Could not confirm OpenSSL linkage in the new binary. Aborting."; exit 1
}
echo "✅ Linked against system OpenSSL."

# 6. Backup & Atomic Swap
echo "==== 5. Backing up and Swapping Binaries ===="
BACKUP_SUFFIX=".bak.$(date +%Y%m%d_%H%M)"
for bin in unbound unbound-control unbound-checkconf unbound-host unbound-anchor; do
    [ -f /usr/sbin/$bin ] && cp /usr/sbin/$bin "/usr/sbin/${bin}${BACKUP_SUFFIX}"
done

# Stop, Replace, Start
systemctl stop unbound
cp -f ./unbound /usr/sbin/unbound
cp -f ./unbound-control /usr/sbin/unbound-control
cp -f ./unbound-checkconf /usr/sbin/unbound-checkconf
# NOTE: ./unbound-host and ./unbound-anchor in the build top-dir are LIBTOOL
# WRAPPER SCRIPTS (real binaries live in ./.libs/, relinked only by `make
# install`). Copying the wrappers bricked both tools (found 2026-06-10,
# restored from .bak.20260326). Preserve the system distro binaries instead.
systemctl start unbound

# Verify
echo "==== 6. Verification ===="
sleep 1
unbound -V | head -3
NEWPID=$(pgrep -x unbound || true)
if [ -n "$NEWPID" ] && grep -q jemalloc /proc/$NEWPID/maps 2>/dev/null; then
    echo "✅ jemalloc active (via LD_PRELOAD drop-in)"
else
    echo "⚠️  jemalloc NOT mapped — check LD_PRELOAD in /etc/systemd/system/unbound.service.d/override.conf"
fi
if dig @127.0.0.1 -p 5353 +short +time=2 +tries=1 cloudflare.com >/dev/null 2>&1; then
    echo "✅ Live query OK"
else
    echo "❌ Live query FAILED — investigate before trusting this build"
    echo "   Rollback: cp /usr/sbin/unbound${BACKUP_SUFFIX} /usr/sbin/unbound && systemctl restart unbound"
fi
if dig @127.0.0.1 -p 5353 +dnssec +time=2 +tries=1 cloudflare.com 2>/dev/null | grep -q 'flags:.* ad'; then
    echo "✅ DNSSEC validation OK (ad flag)"
else
    echo "⚠️  No ad flag — verify DNSSEC validation"
fi

echo "🚀 Complete: Unbound $LATEST_VER on system OpenSSL (Optimized for znver2)"
echo "   Rollback: cp /usr/sbin/unbound${BACKUP_SUFFIX} /usr/sbin/unbound && systemctl restart unbound"
