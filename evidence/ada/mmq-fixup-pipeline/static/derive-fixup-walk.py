"""Replicate mul_mat_q_stream_k_fixup block partition arithmetic and report,
per matmul shape, how many empty bidx values an accumulating block walks."""
import math

NSM = 60
I = 128
QK = 32
ITER_K = 256
BPI = ITER_K // QK          # blocks_per_iter = 8

def arm(nrows_x, ncols_x, ncols_dst, J):
    nty = (nrows_x + I - 1) // I
    ntx = (ncols_dst + J - 1) // J
    ntzw = 1
    bpn = ncols_x // QK                      # blocks_per_ne00
    ntiles = ntx * nty * ntzw
    nwaves = (ntiles + NSM - 1) // NSM
    eff = 100 * ntiles // (NSM * nwaves)
    gx = ntiles if eff >= 90 else NSM
    if ntiles % gx == 0:
        return None                          # fixup_needed false
    total = ntzw * ntx * nty * bpn

    def kbc(b):
        v = (b * total) // gx
        return v - (v % bpn) % BPI

    walks = []
    for b0 in range(gx):
        k0, k0s = kbc(b0), kbc(b0 + 1)
        if k0 == k0s:                                  continue
        if k0 % bpn == 0:                              continue
        if k0 // bpn == k0s // bpn and k0s % bpn != 0: continue
        empties = 0
        accums = 0
        bidx, kstop = b0 - 1, k0
        while bidx >= 0:
            k = kbc(bidx)
            if k == kstop:
                empties += 1
                bidx -= 1
                kstop = k
                continue
            accums += 1
            if k % bpn == 0 or k // bpn < k0 // bpn:
                break
            bidx -= 1
            kstop = k
        walks.append((empties, accums))
    return dict(nty=nty, bpn=bpn, total=total, gx=gx, chunk=total / gx,
                fixup_blocks=len(walks), walks=walks)

SHAPES = [
    ("qkv 2048x1024", 2048, 1024), ("k/v 512x1024", 512, 1024),
    ("o 1024x2048",   1024, 2048), ("gate/up 3584x1024", 3584, 1024),
    ("down 1024x3584", 1024, 3584),
]
print("shape\tJ\tnty\tbpn\tchunk\tfixup_blk\tempty_med\tempty_max\taccum_med")
for name, nr, nc in SHAPES:
    for J in (24, 32):
        r = arm(nr, nc, 17, J)
        if r is None:
            print("%s\t%d\t-\t-\t-\tno_fixup" % (name, J)); continue
        e = sorted(w[0] for w in r["walks"]); a = sorted(w[1] for w in r["walks"])
        if not e:
            print("%s\t%d\t%d\t%d\t%.2f\t0\t-\t-\t-" % (name, J, r["nty"], r["bpn"], r["chunk"])); continue
        print("%s\t%d\t%d\t%d\t%.2f\t%d\t%d\t%d\t%d" % (
            name, J, r["nty"], r["bpn"], r["chunk"], len(e),
            e[len(e)//2], e[-1], a[len(a)//2]))
