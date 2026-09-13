#!/usr/bin/env python3
# elfsyms.py — minimal ELF64 LE symbol reader (no dependencies).
#   elfsyms.py undef  <file.ko>      -> undefined global symbols the module needs
#   elfsyms.py defined <kernel>      -> all defined symbols (from .symtab and .dynsym)
#   elfsyms.py check <file.ko> <kernel> -> report module symbols the kernel does not export
import struct, sys
def sections(b):
    (shoff,) = struct.unpack_from('<Q', b, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x3A)
    secs = []
    for i in range(shnum):
        off = shoff + i * shentsize
        name, typ, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from('<IIQQQQIIQQ', b, off)
        secs.append(dict(name=name, type=typ, offset=offset, size=size, link=link, entsize=entsize))
    strtab = secs[shstrndx]
    for s in secs:
        n = strtab['offset'] + s['name']
        s['sname'] = b[n:b.index(b'\0', n)].decode()
    return secs
def symbols(b, secs, want):
    out = []
    for s in secs:
        if s['sname'] != want: continue
        strs = secs[s['link']]
        for j in range(s['size'] // 24):
            st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from('<IBBHQQ', b, s['offset'] + j * 24)
            n = strs['offset'] + st_name
            name = b[n:b.index(b'\0', n)].decode()
            out.append((name, st_info >> 4, st_info & 0xf, st_shndx))
    return out
def undef(b):
    secs = sections(b)
    return sorted({n for n, bind, typ, shndx in symbols(b, secs, '.symtab') if shndx == 0 and n and bind in (1, 2)})
def defined(b):
    secs = sections(b)
    d = set()
    for tab in ('.symtab', '.dynsym'):
        d |= {n for n, bind, typ, shndx in symbols(b, secs, tab) if shndx != 0 and n}
    return d
cmd = sys.argv[1]
if cmd == 'undef':
    for n in undef(open(sys.argv[2], 'rb').read()): print(n)
elif cmd == 'defined':
    for n in sorted(defined(open(sys.argv[2], 'rb').read())): print(n)
elif cmd == 'check':
    u = undef(open(sys.argv[2], 'rb').read()); k = defined(open(sys.argv[3], 'rb').read())
    missing = [n for n in u if n not in k]
    print(f"module needs {len(u)} external symbols; kernel defines {len(k)}; missing: {len(missing)}")
    for n in missing: print("  MISSING", n)
    sys.exit(1 if missing else 0)
