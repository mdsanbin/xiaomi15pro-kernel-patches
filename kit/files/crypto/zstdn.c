// SPDX-License-Identifier: GPL-2.0-only
/*
 * Cryptographic API.
 *
 * Copyright (c) 2017-present, Facebook, Inc.
 *
 * zstdn: a second Zstandard backend that shares lib/zstd but compresses at a
 * low level (1) instead of the default 3.  It exists so that zram can be
 * switched between "balanced" (zstd, level 3) and "fast" (zstdn, level 1)
 * without touching the vendor zram.ko: crypto algorithms are discovered at
 * runtime, so registering a new name is enough and it immediately becomes a
 * valid comp_algorithm value.
 */
#include <linux/crypto.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/net.h>
#include <linux/vmalloc.h>
#include <linux/zstd.h>
#include <crypto/internal/scompress.h>


#define ZSTDN_DEF_LEVEL	1

struct zstdn_ctx {
	zstd_cctx *cctx;
	zstd_dctx *dctx;
	void *cwksp;
	void *dwksp;
};

static zstd_parameters zstdn_params(void)
{
	return zstd_get_params(ZSTDN_DEF_LEVEL, 0);
}

static int zstdn_comp_init(struct zstdn_ctx *ctx)
{
	int ret = 0;
	const zstd_parameters params = zstdn_params();
	const size_t wksp_size = zstd_cctx_workspace_bound(&params.cParams);

	ctx->cwksp = vzalloc(wksp_size);
	if (!ctx->cwksp) {
		ret = -ENOMEM;
		goto out;
	}

	ctx->cctx = zstd_init_cctx(ctx->cwksp, wksp_size);
	if (!ctx->cctx) {
		ret = -EINVAL;
		goto out_free;
	}
out:
	return ret;
out_free:
	vfree(ctx->cwksp);
	goto out;
}

static int zstdn_decomp_init(struct zstdn_ctx *ctx)
{
	int ret = 0;
	const size_t wksp_size = zstd_dctx_workspace_bound();

	ctx->dwksp = vzalloc(wksp_size);
	if (!ctx->dwksp) {
		ret = -ENOMEM;
		goto out;
	}

	ctx->dctx = zstd_init_dctx(ctx->dwksp, wksp_size);
	if (!ctx->dctx) {
		ret = -EINVAL;
		goto out_free;
	}
out:
	return ret;
out_free:
	vfree(ctx->dwksp);
	goto out;
}

static void zstdn_comp_exit(struct zstdn_ctx *ctx)
{
	vfree(ctx->cwksp);
	ctx->cwksp = NULL;
	ctx->cctx = NULL;
}

static void zstdn_decomp_exit(struct zstdn_ctx *ctx)
{
	vfree(ctx->dwksp);
	ctx->dwksp = NULL;
	ctx->dctx = NULL;
}

static int __zstdn_init(void *ctx)
{
	int ret;

	ret = zstdn_comp_init(ctx);
	if (ret)
		return ret;
	ret = zstdn_decomp_init(ctx);
	if (ret)
		zstdn_comp_exit(ctx);
	return ret;
}

static void *zstdn_alloc_ctx(struct crypto_scomp *tfm)
{
	int ret;
	struct zstdn_ctx *ctx;

	ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return ERR_PTR(-ENOMEM);

	ret = __zstdn_init(ctx);
	if (ret) {
		kfree(ctx);
		return ERR_PTR(ret);
	}

	return ctx;
}

static int zstdn_init(struct crypto_tfm *tfm)
{
	struct zstdn_ctx *ctx = crypto_tfm_ctx(tfm);

	return __zstdn_init(ctx);
}

static void __zstdn_exit(void *ctx)
{
	zstdn_comp_exit(ctx);
	zstdn_decomp_exit(ctx);
}

static void zstdn_free_ctx(struct crypto_scomp *tfm, void *ctx)
{
	__zstdn_exit(ctx);
	kfree_sensitive(ctx);
}

static void zstdn_exit(struct crypto_tfm *tfm)
{
	struct zstdn_ctx *ctx = crypto_tfm_ctx(tfm);

	__zstdn_exit(ctx);
}

static int __zstdn_compress(const u8 *src, unsigned int slen,
			    u8 *dst, unsigned int *dlen, void *ctx)
{
	size_t out_len;
	struct zstdn_ctx *zctx = ctx;
	const zstd_parameters params = zstdn_params();

	out_len = zstd_compress_cctx(zctx->cctx, dst, *dlen, src, slen, &params);
	if (zstd_is_error(out_len))
		return -EINVAL;
	*dlen = out_len;
	return 0;
}

static int zstdn_compress(struct crypto_tfm *tfm, const u8 *src,
			  unsigned int slen, u8 *dst, unsigned int *dlen)
{
	struct zstdn_ctx *ctx = crypto_tfm_ctx(tfm);

	return __zstdn_compress(src, slen, dst, dlen, ctx);
}

static int zstdn_scompress(struct crypto_scomp *tfm, const u8 *src,
			   unsigned int slen, u8 *dst, unsigned int *dlen,
			   void *ctx)
{
	return __zstdn_compress(src, slen, dst, dlen, ctx);
}

static int __zstdn_decompress(const u8 *src, unsigned int slen,
			      u8 *dst, unsigned int *dlen, void *ctx)
{
	size_t out_len;
	struct zstdn_ctx *zctx = ctx;

	out_len = zstd_decompress_dctx(zctx->dctx, dst, *dlen, src, slen);
	if (zstd_is_error(out_len))
		return -EINVAL;
	*dlen = out_len;
	return 0;
}

static int zstdn_decompress(struct crypto_tfm *tfm, const u8 *src,
			    unsigned int slen, u8 *dst, unsigned int *dlen)
{
	struct zstdn_ctx *ctx = crypto_tfm_ctx(tfm);

	return __zstdn_decompress(src, slen, dst, dlen, ctx);
}

static int zstdn_sdecompress(struct crypto_scomp *tfm, const u8 *src,
			     unsigned int slen, u8 *dst, unsigned int *dlen,
			     void *ctx)
{
	return __zstdn_decompress(src, slen, dst, dlen, ctx);
}

static struct crypto_alg alg = {
	.cra_name		= "zstdn",
	.cra_driver_name	= "zstdn-generic",
	.cra_flags		= CRYPTO_ALG_TYPE_COMPRESS,
	.cra_ctxsize		= sizeof(struct zstdn_ctx),
	.cra_module		= THIS_MODULE,
	.cra_init		= zstdn_init,
	.cra_exit		= zstdn_exit,
	.cra_u			= { .compress = {
	.coa_compress		= zstdn_compress,
	.coa_decompress		= zstdn_decompress } }
};

static struct scomp_alg scomp = {
	.alloc_ctx		= zstdn_alloc_ctx,
	.free_ctx		= zstdn_free_ctx,
	.compress		= zstdn_scompress,
	.decompress		= zstdn_sdecompress,
	.base			= {
		.cra_name	= "zstdn",
		.cra_driver_name = "zstdn-scomp",
		.cra_module	 = THIS_MODULE,
	}
};

static int __init zstdn_mod_init(void)
{
	int ret;

	ret = crypto_register_alg(&alg);
	if (ret)
		return ret;

	ret = crypto_register_scomp(&scomp);
	if (ret)
		crypto_unregister_alg(&alg);

	return ret;
}

static void __exit zstdn_mod_fini(void)
{
	crypto_unregister_alg(&alg);
	crypto_unregister_scomp(&scomp);
}

subsys_initcall(zstdn_mod_init);
module_exit(zstdn_mod_fini);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Zstd Compression Algorithm (level 1)");
MODULE_ALIAS_CRYPTO("zstdn");
