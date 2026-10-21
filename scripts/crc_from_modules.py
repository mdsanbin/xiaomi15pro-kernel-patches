#!/usr/bin/env python3
"""Build the "vendor-module" symbol-CRC baseline for a GKI kernel.

Why this baseline instead of a full-tree one:

  * Every module built with CONFIG_MODVERSIONS carries a __versions section --
    an array of

        struct modversion_info { unsigned long crc; char name[MODULE_NAME_LEN]; }

    (8 + 56 = 64 bytes on arm64).  Those entries are exactly the CRCs the
    module demands from the kernel in check_version(); a mismatch is what
    produces "disagrees about version of symbol".

  * Symbols that one module exports to another (e.g. mac80211 -> cfg80211) are
    satisfied inside the module set itself.  They are NOT part of the kernel
    ABI and must not be demanded from vmlinux -- that mistake alone produces
    thousands of false "missing symbol" hits.

  * What remains -- required by a shipped module, but exported by no shipped
    module -- can only come from the kernel.  That is the real must-match set.

The baseline is derived purely from device artifacts, so it does not drift
when unrelated parts of the tree change, and it does not depend on whichever
compiler produced the reference build.

Usage:
  crc_from_modules.py <module-dir> [out.txt] [--loaded <lsmod.txt>]
                      [--vmlinux <vmlinux>]

Baseline format is what crc_tool.py reads: "name<TAB>0xCRC".
"""
import hashlib
import os
import struct
import sys


def elf_sections(d):
    """Return (list_of_sections, name->index)."""
    if d[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    if d[4] != 2 or d[5] != 1:
        raise ValueError("not a 64-bit little-endian ELF")
    e_shoff, = struct.unpack_from("<Q", d, 0x28)
    e_shentsize, = struct.unpack_from("<H", d, 0x3a)
    e_shnum, = struct.unpack_from("<H", d, 0x3c)
    e_shstrndx, = struct.unpack_from("<H", d, 0x3e)
    if not e_shoff or not e_shnum or e_shstrndx >= e_shnum:
        raise ValueError("no section headers")
    raw = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        name, typ = struct.unpack_from("<II", d, o)
        _, _, off, size = struct.unpack_from("<QQQQ", d, o + 8)
        link, _ = struct.unpack_from("<II", d, o + 0x28)
        entsize, = struct.unpack_from("<Q", d, o + 0x38)
        raw.append((name, typ, off, size, link, entsize))
    stroff = raw[e_shstrndx][2]

    def nm_at(idx):
        end = d.index(b"\0", stroff + idx)
        return d[stroff + idx:end].decode("ascii", "replace")

    secs = []
    index = {}
    for i, (name, typ, off, size, link, entsize) in enumerate(raw):
        nm = nm_at(name) if name else ""
        secs.append((nm, typ, off, size, link, entsize))
        if nm and nm not in index:
            index[nm] = i
    return secs, index


def read_versions(d):
    """{symbol: crc} that this module demands from its provider."""
    secs, index = elf_sections(d)
    if "__versions" not in index:
        return {}
    _, _, off, size, _, entsize = secs[index["__versions"]]
    ent = entsize or 64
    if ent < 16 or size % ent:
        raise ValueError("__versions size %d not a multiple of %d" % (size, ent))
    name_len = ent - 8
    out = {}
    for i in range(size // ent):
        o = off + i * ent
        crc, = struct.unpack_from("<Q", d, o)
        raw = d[o + 8:o + 8 + name_len]
        nm = raw.split(b"\0", 1)[0].decode("ascii", "replace")
        if nm:
            out[nm] = crc & 0xffffffff
    return out


def read_exports(d):
    """{symbol: crc} this module supplies to other modules."""
    secs, _index = elf_sections(d)
    out = {}
    for (sname, typ, off, size, link, entsize) in secs:
        if typ != 2:  # SHT_SYMTAB
            continue
        strtab_off = secs[link][2]
        step = entsize or 24
        for j in range(size // step):
            so = off + j * step
            st_name, _info, _other, st_shndx = struct.unpack_from("<IBBH", d, so)
            st_value, = struct.unpack_from("<Q", d, so + 8)
            if not st_name:
                continue
            end = d.index(b"\0", strtab_off + st_name)
            nm = d[strtab_off + st_name:end].decode("ascii", "replace")
            if not nm.startswith("__crc_") or st_shndx >= len(secs):
                continue
            provider = secs[st_shndx][0]
            if not provider.startswith("__kcrctab"):
                continue
            base = secs[st_shndx][2]
            b = d[base + st_value:base + st_value + 4]
            if len(b) != 4:
                continue
            out[nm[6:]] = struct.unpack("<I", b)[0]
    return out


def main():
    argv = list(sys.argv[1:])
    loaded_path = None
    vmlinux_path = None
    for flag in ("--loaded", "--vmlinux"):
        if flag in argv:
            i = argv.index(flag)
            val = argv[i + 1]
            del argv[i:i + 2]
            if flag == "--loaded":
                loaded_path = val
            else:
                vmlinux_path = val
    if not argv:
        raise SystemExit(__doc__)
    root = argv[0]
    out_path = argv[1] if len(argv) > 1 else None

    files = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if fn.endswith(".ko"):
                files.append(os.path.join(dirpath, fn))
    files.sort()

    per_module = {}
    by_name = {}
    crc_owner = {}
    conflicts = {}
    skipped = []
    seen_hash = {}
    dup = 0
    zero_crc = set()

    for path in files:
        data = open(path, "rb").read()
        h = hashlib.sha256(data).hexdigest()
        rel = os.path.relpath(path, root)
        if h in seen_hash:
            dup += 1
            continue
        seen_hash[h] = rel
        try:
            vers = read_versions(data)
        except (ValueError, struct.error) as e:
            skipped.append("%s: %s" % (rel, e))
            continue
        if not vers:
            skipped.append("%s: no __versions" % rel)
            continue
        modname = os.path.basename(path)[:-3]
        per_module[rel] = set(vers)
        by_name.setdefault(modname, set()).update(vers)
        for nm, crc in vers.items():
            if crc == 0:
                zero_crc.add(nm)
            old = crc_owner.get(nm)
            if old is None:
                crc_owner[nm] = (crc, modname)
            elif old[0] != crc:
                conflicts.setdefault(nm, set()).add(crc)

    # What the modules provide to each other.
    provided = {}
    provided_by = {}
    for path in files:
        data = open(path, "rb").read()
        try:
            exp = read_exports(data)
        except (ValueError, struct.error):
            continue
        modname = os.path.basename(path)[:-3]
        for nm, crc in exp.items():
            prev = provided.get(nm)
            if prev is None:
                provided[nm] = crc
                provided_by[nm] = modname
            elif prev != crc:
                conflicts.setdefault("export:" + nm, set()).add((prev, crc))

    required = {nm: v[0] for nm, v in crc_owner.items()}
    kernel_req = {nm: c for nm, c in required.items() if nm not in provided}

    print("modules_found   = %d" % len(files))
    print("modules_used    = %d (duplicates skipped: %d)" % (len(per_module), dup))
    print("modules_skipped = %d" % len(skipped))
    for s in skipped[:10]:
        print("  ! %s" % s)
    print("required_symbols= %d  (demanded by a shipped module)" % len(required))
    print("module_provided = %d  (satisfied inside the module set)" % len(provided))
    print("kernel_required = %d  (must match vmlinux __crc_*)" % len(kernel_req))
    print("zero_crc_symbols= %d" % len(zero_crc))
    print("crc_conflicts   = %d" % len(conflicts))
    for nm in sorted(conflicts)[:20]:
        print("  ! %s -> %s" % (nm, sorted(conflicts[nm])))

    if loaded_path:
        loaded = set()
        for line in open(loaded_path):
            parts = line.split()
            if len(parts) >= 2 and parts[0] != "Module":
                loaded.add(parts[0].replace("-", "_"))
        loaded_syms = set()
        for m in loaded:
            loaded_syms |= by_name.get(m, set())
        print("loaded_modules  = %d of %d" % (len(loaded), len(by_name)))
        print("loaded_require  = %d symbols (the rest belong to on-demand modules)"
              % len(loaded_syms))

    if vmlinux_path:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from crc_tool import load_crc
        cur = load_crc(vmlinux_path)
        missing = [k for k in kernel_req if k not in cur]
        diff = [k for k in kernel_req if k in cur and cur[k] != kernel_req[k]]
        print("vmlinux         = %s" % vmlinux_path)
        print("  missing_in_vmlinux = %d" % len(missing))
        print("  DIFFERENT_CRC      = %d" % len(diff))
        for k in sorted(missing)[:20]:
            print("  -  %s" % k)
        for k in sorted(diff)[:20]:
            print("  !  %-40s vmlinux=0x%08x required=0x%08x"
                  % (k, cur[k], kernel_req[k]))

    if out_path:
        with open(out_path, "w") as f:
            f.write("# Vendor-module symbol-CRC baseline (device-derived).\n")
            f.write("# Source: %d unique .ko shipped on Xiaomi 15 Pro (haotian).\n"
                    % len(per_module))
            f.write("# %d of %d symbols they demand are supplied by other shipped\n"
                    % (len(required) - len(kernel_req), len(required)))
            f.write("# modules and are therefore excluded here; every line below\n")
            f.write("# must be fulfilled by vmlinux with exactly this CRC.\n")
            for nm in sorted(kernel_req):
                f.write("%s\t0x%08x\n" % (nm, kernel_req[nm]))
        print("wrote           = %s (%d symbols)" % (out_path, len(kernel_req)))

        # Companion index: for every symbol the kernel must provide, which
        # shipped modules demand it.  crc_tool.py reads this next to the
        # baseline so a gate failure can name the modules that will not load.
        imp_index = {}
        for name, syms in by_name.items():
            for s in syms & set(kernel_req):
                imp_index.setdefault(s, []).append(name)
        imp_path = os.path.splitext(out_path)[0] + ".importers.txt"
        with open(imp_path, "w") as f:
            f.write("# symbol<TAB>comma-separated shipped modules that demand it\n")
            f.write("# from the kernel; generated next to the CRC baseline.\n")
            for nm in sorted(imp_index):
                f.write("%s\t%s\n" % (nm, ",".join(sorted(imp_index[nm]))))
        print("wrote           = %s (%d symbols)" % (imp_path, len(imp_index)))


if __name__ == "__main__":
    main()
