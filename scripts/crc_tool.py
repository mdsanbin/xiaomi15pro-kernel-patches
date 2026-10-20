#!/usr/bin/env python3
"""CRC (symbol-version) gate for GKI kernels.

The Android GKI ABI is defined by the reference build: every exported symbol's
`__crc_*` value must match it exactly, or prebuilt vendor modules refuse to load
("disagrees about version of symbol ...").  This tool lets a build be checked
against a stored baseline so any CRC drift fails the build.

Usage:
  crc_tool.py dump <vmlinux>                 # print "name<TAB>0xCRC", sorted
  crc_tool.py gate <vmlinux> <baseline.txt>  # exit 1 if anything differs
"""
import struct
import sys


def load_crc(vmlinux):
    d = open(vmlinux, "rb").read()
    if d[:4] != b"\x7fELF" or d[4] != 2 or d[5] != 1:
        raise SystemExit("not a 64-bit little-endian ELF: %s" % vmlinux)
    e_shoff, = struct.unpack_from("<Q", d, 0x28)
    e_shentsize, = struct.unpack_from("<H", d, 0x3a)
    e_shnum, = struct.unpack_from("<H", d, 0x3c)
    secs = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        name, typ = struct.unpack_from("<II", d, o)
        _, addr, off, size = struct.unpack_from("<QQQQ", d, o + 8)
        link, _ = struct.unpack_from("<II", d, o + 0x28)
        entsize, = struct.unpack_from("<Q", d, o + 0x38)
        secs.append((name, typ, addr, off, size, link, entsize))

    def nm_at(strtab_off, idx):
        end = d.index(b"\0", strtab_off + idx)
        return d[strtab_off + idx:end].decode("ascii", "replace")

    def read_at(vaddr):
        for (_, _typ, addr, off, size, _l, _e) in secs:
            if addr and addr <= vaddr < addr + size:
                b = d[off + (vaddr - addr):off + (vaddr - addr) + 4]
                if len(b) == 4:
                    return struct.unpack("<I", b)[0]
        return None

    out = {}
    for (name, typ, addr, off, size, link, entsize) in secs:
        if typ != 2:  # SHT_SYMTAB
            continue
        strtab_off = secs[link][3]
        step = entsize or 24
        for j in range(size // step):
            so = off + j * step
            st_name, _info, _other, _shndx = struct.unpack_from("<IBBH", d, so)
            st_value, = struct.unpack_from("<Q", d, so + 8)
            if not st_name:
                continue
            nm = nm_at(strtab_off, st_name)
            if not nm.startswith("__crc_"):
                continue
            c = read_at(st_value)
            if c is not None:
                out[nm[6:]] = c
    return out


def read_baseline(path):
    base = {}
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        n, c = line.rsplit("\t", 1)
        base[n] = int(c, 16)
    return base


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    cmd = sys.argv[1]
    if cmd == "dump":
        crc = load_crc(sys.argv[2])
        for k in sorted(crc):
            print("%s\t0x%08x" % (k, crc[k]))
        return
    if cmd == "gate":
        cur = load_crc(sys.argv[2])
        base = read_baseline(sys.argv[3])
        only_c = set(cur) - set(base)
        only_b = set(base) - set(cur)
        diff = [k for k in cur if k in base and cur[k] != base[k]]
        print("vmlinux      : %s" % sys.argv[2])
        print("baseline     : %s" % sys.argv[3])
        print("baseline_syms=%d current_syms=%d" % (len(base), len(cur)))
        print("only_in_current=%d only_in_baseline=%d DIFFERENT_CRC=%d"
              % (len(only_c), len(only_b), len(diff)))
        for k in sorted(diff)[:40]:
            print("  %-40s current=0x%08x baseline=0x%08x"
                  % (k, cur[k], base[k]))
        for k in sorted(only_c)[:20]:
            print("  +  %s" % k)
        for k in sorted(only_b)[:20]:
            print("  -  %s" % k)
        if diff or only_c or only_b:
            print("CRC_GATE: FAIL")
            sys.exit(1)
        print("CRC_GATE: PASS")
        return
    raise SystemExit("unknown command: %s" % cmd)


if __name__ == "__main__":
    main()
