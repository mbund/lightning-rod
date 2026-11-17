/*
 * Builds libdeflate's compressor with one more entry point. Fragments must be nonfinal
 * DEFLATE streams that end at a byte boundary, and only the compressor knows where its
 * last block ends.
 *
 * libdeflate clears 196 KiB of hash tables before every input. A 2 KiB fragment spends a
 * third of its time there. The fragment entry point clears only the entries its input
 * touched and tells the next call to skip the full clear. To do that, the hash chain
 * matchfinder is included first under another name, so the compressor's calls to its
 * initializer reach the wrapper below.
 */
#include "lib/lib_common.h"
#include "lib/deflate_constants.h"

/* deflate_compress.c defines this before it includes the matchfinders. */
#define MATCHFINDER_WINDOW_ORDER DEFLATE_WINDOW_ORDER
#define hc_matchfinder_init lightning_rod_hc_matchfinder_clear
#include "lib/hc_matchfinder.h"
#undef hc_matchfinder_init

/* Set only around one fragment call, so ordinary compression always clears its tables. */
static __thread bool lightning_rod_tables_clean;

static forceinline void
lightning_rod_hc_matchfinder_init(struct hc_matchfinder *mf)
{
	if (lightning_rod_tables_clean) {
		lightning_rod_tables_clean = false;
		return;
	}
	lightning_rod_hc_matchfinder_clear(mf);
}

#define hc_matchfinder_init lightning_rod_hc_matchfinder_init
#include "lib/deflate_compress.c"
#undef hc_matchfinder_init

/* Past this size clearing every entry is as cheap as finding the touched ones. */
#define LIGHTNING_ROD_TIDY_MAX 4096

/*
 * Restores the hash tables to their cleared state. The matchfinder files each position
 * under the hashes of the four bytes there, and files the first position under hash zero
 * because no hash was computed yet. Chain links need no reset, since a position's link is
 * written before any search can follow it.
 */
static void
lightning_rod_hc_matchfinder_tidy(struct hc_matchfinder *mf, const u8 *in, size_t in_nbytes)
{
	size_t i;

	mf->hash3_tab[0] = MATCHFINDER_INITVAL;
	mf->hash4_tab[0] = MATCHFINDER_INITVAL;
	for (i = 0; i + 4 <= in_nbytes; i++) {
		const u32 seq = get_unaligned_le32(in + i);

		mf->hash3_tab[lz_hash(seq & 0xFFFFFF, HC_MATCHFINDER_HASH3_ORDER)] = MATCHFINDER_INITVAL;
		mf->hash4_tab[lz_hash(seq, HC_MATCHFINDER_HASH4_ORDER)] = MATCHFINDER_INITVAL;
	}
#ifndef NDEBUG
	/* A missed entry would later name a position ahead of the search, which corrupts output. */
	for (i = 0; i < ARRAY_LEN(mf->hash3_tab); i++)
		if (mf->hash3_tab[i] != MATCHFINDER_INITVAL)
			__builtin_trap();
	for (i = 0; i < ARRAY_LEN(mf->hash4_tab); i++)
		if (mf->hash4_tab[i] != MATCHFINDER_INITVAL)
			__builtin_trap();
#endif
}

/*
 * Returns 0 when the output does not fit, the input needed more than one block, or the
 * input is shorter than any level compresses. Level 12 compresses inputs from 8 bytes, so
 * every level's matcher accepts them, while libdeflate would store them uncompressed.
 *
 * `clean` belongs to the compressor's owner and starts false. It records that the previous
 * fragment left the hash tables cleared. Any other use of the compressor must reset it.
 */
size_t
lightning_rod_deflate_fragment(struct libdeflate_compressor *c, const void *in,
			       size_t in_nbytes, void *out, size_t out_nbytes_avail,
			       bool *clean)
{
	/* The closing stored block needs at most three bytes of bits then LEN and NLEN. */
	const size_t sync_bytes = 7;
	/* Only these implementations use the hash chain matchfinder. */
	const bool chained = c->impl == deflate_compress_greedy ||
			     c->impl == deflate_compress_lazy ||
			     c->impl == deflate_compress_lazy2;
	struct deflate_output_bitstream os;
	u8 *bytes = out;

	if (in_nbytes < 8 || c->impl == NULL || out_nbytes_avail <= sync_bytes + 5)
		return 0;
	os.bitbuf = 0;
	os.bitcount = 0;
	os.next = out;
	os.end = os.next + out_nbytes_avail - sync_bytes;
	os.overflow = false;
	lightning_rod_tables_clean = chained && *clean;
	(*c->impl)(c, in, in_nbytes, &os);
	lightning_rod_tables_clean = false;
	*clean = chained && in_nbytes <= LIGHTNING_ROD_TIDY_MAX;
	if (*clean)
		lightning_rod_hc_matchfinder_tidy(&c->p.g.hc_mf, in, in_nbytes);
	/* A stream whose first block is final has exactly one block. */
	if (os.overflow || os.next == bytes || (bytes[0] & 1) == 0)
		return 0;
	bytes[0] &= ~1;
	/*
	 * A nonfinal stored block ends the fragment at a byte boundary. Its padding is ones, which
	 * decoders ignore, so a join can find where the data ends below the three zero header bits
	 * and leave the stored block out. Without room for padding, an empty fixed block comes
	 * first: a zero, the type bits one and zero, and seven zero bits of the end code.
	 */
	{
		u64 bits = os.bitbuf;
		unsigned count = os.bitcount;
		unsigned padding;

		if (count == 5) {
			bits |= (u64)2 << count;
			count += 10;
		}
		count += 3;
		padding = (8 - count % 8) % 8;
		bits |= (((u64)1 << padding) - 1) << count;
		count += padding;
		for (; count != 0; count -= 8) {
			*os.next++ = (u8)bits;
			bits >>= 8;
		}
	}
	put_unaligned_le32(0xFFFF0000, os.next);
	os.next += 4;
	return os.next - bytes;
}
