/* SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 Ozy-666 (https://dnsdoh.art)
 *
 * dnssec-verify-bench — measure the crypto primitives a DNSSEC signed-miss
 * flood actually spends its time in.
 *
 * Unbound's exposure to BoringSSL is libcrypto only: for every signed answer
 * that misses the cache it verifies RRSIGs. Algorithm 8 (RSASHA256, still what
 * the root and most TLDs sign with) and algorithm 13 (ECDSAP256SHA256, what
 * most modern zones use) are the two that matter. Signing cost is irrelevant
 * here — a validating resolver only ever verifies.
 *
 * This is deliberately not an end-to-end flood: an end-to-end run measures the
 * network far more than the library, so it cannot answer "did swapping
 * libcrypto make validation slower". Build this once per library version and
 * compare. Correctness is asserted on every iteration, so a library that
 * verifies fast but wrongly cannot post a good number.
 *
 * Build against a specific BoringSSL:
 *   gcc -O2 dnssec-verify-bench.c -o bench \
 *       -I<prefix>/include -L<prefix>/lib -lcrypto -Wl,-rpath,<prefix>/lib
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <openssl/obj_mac.h>
#include <openssl/rsa.h>

/* A DNSKEY-signed RRset digest is small; 64 bytes is representative. */
static const unsigned char MSG[64] = "dnsdoh.art RRSIG payload for validation benchmarking, 64 bytes.";

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* Verify `iters` times, asserting success each round; returns verifies/sec. */
static double bench_verify(EVP_PKEY *pkey, const unsigned char *sig,
                           size_t siglen, int iters, const char *label) {
    double t0 = now_sec();
    for (int i = 0; i < iters; i++) {
        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        if (!ctx) { fprintf(stderr, "%s: ctx alloc failed\n", label); exit(1); }
        if (EVP_DigestVerifyInit(ctx, NULL, EVP_sha256(), NULL, pkey) != 1 ||
            EVP_DigestVerify(ctx, sig, siglen, MSG, sizeof(MSG)) != 1) {
            fprintf(stderr, "%s: VERIFY FAILED at iteration %d\n", label, i);
            exit(1);
        }
        EVP_MD_CTX_free(ctx);
    }
    double elapsed = now_sec() - t0;
    return (double)iters / elapsed;
}

static EVP_PKEY *make_ecdsa_p256(void) {
    EC_KEY *ec = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    if (!ec || EC_KEY_generate_key(ec) != 1) return NULL;
    EVP_PKEY *pkey = EVP_PKEY_new();
    if (!pkey || EVP_PKEY_assign_EC_KEY(pkey, ec) != 1) return NULL;
    return pkey;  /* pkey owns ec */
}

static EVP_PKEY *make_rsa(int bits) {
    RSA *rsa = RSA_new();
    BIGNUM *e = BN_new();
    if (!rsa || !e || BN_set_word(e, RSA_F4) != 1 ||
        RSA_generate_key_ex(rsa, bits, e, NULL) != 1) return NULL;
    BN_free(e);
    EVP_PKEY *pkey = EVP_PKEY_new();
    if (!pkey || EVP_PKEY_assign_RSA(pkey, rsa) != 1) return NULL;
    return pkey;  /* pkey owns rsa */
}

/* Sign once so the verify loop has something real to check. */
static unsigned char *sign_once(EVP_PKEY *pkey, size_t *siglen_out) {
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    size_t siglen = 0;
    if (!ctx || EVP_DigestSignInit(ctx, NULL, EVP_sha256(), NULL, pkey) != 1 ||
        EVP_DigestSign(ctx, NULL, &siglen, MSG, sizeof(MSG)) != 1) return NULL;
    unsigned char *sig = malloc(siglen);
    if (!sig || EVP_DigestSign(ctx, sig, &siglen, MSG, sizeof(MSG)) != 1) return NULL;
    EVP_MD_CTX_free(ctx);
    *siglen_out = siglen;
    return sig;
}

int main(int argc, char **argv) {
    int iters = (argc > 1) ? atoi(argv[1]) : 20000;

    struct { const char *name; int rsa_bits; int iters_div; } cases[] = {
        {"ECDSA P-256 verify  (DNSSEC alg 13)", 0,    1},
        {"RSA-2048 verify     (DNSSEC alg 8)",  2048, 1},
        {"RSA-1024 verify     (legacy ZSK)",    1024, 1},
    };

    printf("%-38s %14s %12s\n", "primitive", "verifies/sec", "us/verify");
    printf("---------------------------------------------------------------\n");

    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        EVP_PKEY *pkey = cases[i].rsa_bits ? make_rsa(cases[i].rsa_bits)
                                           : make_ecdsa_p256();
        if (!pkey) { fprintf(stderr, "keygen failed for %s\n", cases[i].name); return 1; }

        size_t siglen = 0;
        unsigned char *sig = sign_once(pkey, &siglen);
        if (!sig) { fprintf(stderr, "sign failed for %s\n", cases[i].name); return 1; }

        /* Warm up so the first timed iteration is not paying for lazy init. */
        bench_verify(pkey, sig, siglen, 200, cases[i].name);

        int n = iters / cases[i].iters_div;
        double rate = bench_verify(pkey, sig, siglen, n, cases[i].name);
        printf("%-38s %14.0f %12.2f\n", cases[i].name, rate, 1e6 / rate);

        free(sig);
        EVP_PKEY_free(pkey);
    }
    return 0;
}
