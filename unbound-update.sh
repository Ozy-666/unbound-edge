#!/bin/bash
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
echo "==== 0. BoringSSL (pinned ${BORING_PIN}) ===="
if [ -f "${BORING_PREFIX}/lib/libcrypto.so" ] && [ -f "${BORING_PREFIX}/lib/libssl.so" ]; then
    echo "✅ /opt/boring present (commit $(cat ${BORING_PREFIX}/COMMIT 2>/dev/null))"
else
    echo "⚠️  /opt/boring missing — building BoringSSL from pinned source..."
    if [ ! -d "$BORING_SRC/.git" ]; then
        git clone https://boringssl.googlesource.com/boringssl "$BORING_SRC"
    fi
    cd "$BORING_SRC"
    git fetch --depth 1 origin "$BORING_PIN" 2>/dev/null || git fetch origin 2>/dev/null || true
    git checkout -q "$BORING_PIN"
    rm -rf build && mkdir build && cd build
    cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=1 .. >/dev/null
    make -j"$CPU_CORES" crypto ssl >/dev/null
    mkdir -p "${BORING_PREFIX}/include" "${BORING_PREFIX}/lib"
    cp -r "${BORING_SRC}/include/"* "${BORING_PREFIX}/include/"
    cp "${BORING_SRC}/build/libcrypto.so" "${BORING_SRC}/build/libssl.so" "${BORING_PREFIX}/lib/"
    echo "$BORING_PIN" > "${BORING_PREFIX}/COMMIT"
    echo "✅ BoringSSL staged to ${BORING_PREFIX}"
fi
grep -q OPENSSL_IS_BORINGSSL "${BORING_PREFIX}/include/openssl/base.h" || { echo "❌ /opt/boring is not BoringSSL — abort"; exit 1; }

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
