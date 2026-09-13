#!/usr/bin/env python3
# ufs2tool.py — read (and same-length in-place patch) files on a UFS2 filesystem
# inside a raw disk image, from any host. No dependencies.
#   ufs2tool.py parts <image>                    -> partition table (GPT or MBR)
#   ufs2tool.py ls    <image> <path>             -> directory listing
#   ufs2tool.py cat   <image> <path>             -> file contents to stdout
#   ufs2tool.py patch <image> <path> <newfile>   -> overwrite file data in place;
#                                                  new content must be <= old size,
#                                                  padded with '\n' to the old size.
import struct, sys, uuid
SBLOCK_UFS2 = 65536; FS_UFS2_MAGIC = 0x19540119; DINODE2_SIZE = 256
UFS_GUID = uuid.UUID('516e7cb6-6ecf-11d6-8ff8-00022d09712a')

def gpt_parts(f):
    f.seek(512); h = f.read(92)
    if h[:8] != b'EFI PART': return None
    ent_lba, nent, entsz = struct.unpack_from('<QII', h, 72)
    f.seek(ent_lba * 512); parts = []
    for i in range(nent):
        e = f.read(entsz)
        tguid = uuid.UUID(bytes_le=e[:16])
        if tguid.int == 0: continue
        first, last = struct.unpack_from('<QQ', e, 32)
        name = e[56:128].decode('utf-16-le').rstrip('\0')
        parts.append((i + 1, tguid, first, last, name))
    return parts

def mbr_parts(f):
    f.seek(0); m = f.read(512); parts = []
    for i in range(4):
        e = m[446 + 16 * i: 462 + 16 * i]
        typ = e[4]; start, size = struct.unpack_from('<II', e, 8)
        if typ: parts.append((i + 1, typ, start, start + size - 1, ''))
    return parts

def ufs_offset(f):
    g = gpt_parts(f)
    if g:
        for idx, guid, first, last, name in g:
            if guid == UFS_GUID: return first * 512
        raise SystemExit('no freebsd-ufs GPT partition')
    for idx, typ, first, last, name in mbr_parts(f):
        if typ == 0xa5:
            f.seek(first * 512 + 512); lbl = f.read(512)
            if lbl[:4] == b'WEV\x82':
                npart = struct.unpack_from('<H', lbl, 138)[0]
                for p in range(npart):
                    psize, poff, pfsize, pfstype = struct.unpack_from('<IIIB', lbl, 148 + 16 * p)
                    if pfstype == 7: return (first + poff) * 512  # bsdlabel offsets are slice-relative
            return first * 512
    raise SystemExit('no UFS partition found')

class UFS2:
    def __init__(self, f, base):
        self.f = f; self.base = base
        f.seek(base + SBLOCK_UFS2); sb = f.read(1376)
        (self.magic,) = struct.unpack_from('<I', sb, 1372)
        if self.magic != FS_UFS2_MAGIC: raise SystemExit('UFS2 magic not found at %#x' % (base + SBLOCK_UFS2))
        self.iblkno, self.dblkno, self.cgoffset, self.cgmask = struct.unpack_from('<iiii', sb, 16)
        self.ncg, self.bsize, self.fsize, self.frag = struct.unpack_from('<iiii', sb, 44)
        (self.fsbtodb,) = struct.unpack_from('<i', sb, 100)
        (self.inopb,) = struct.unpack_from('<i', sb, 120)
        self.ipg, self.fpg = struct.unpack_from('<ii', sb, 184)
    def cgstart(self, c): return c * self.fpg + self.cgoffset * (c & ~self.cgmask)
    def inode(self, ino):
        cg = ino // self.ipg
        blk = self.cgstart(cg) + self.iblkno + ((ino % self.ipg) // self.inopb) * self.frag
        off = self.base + blk * self.fsize + (ino % self.inopb) * DINODE2_SIZE
        self.f.seek(off); d = self.f.read(DINODE2_SIZE)
        mode = struct.unpack_from('<H', d, 0)[0]; size = struct.unpack_from('<Q', d, 16)[0]
        db = struct.unpack_from('<12q', d, 112); ib = struct.unpack_from('<3q', d, 208)
        return dict(ino=ino, mode=mode, size=size, db=db, ib=ib, off=off)
    def blocks(self, ino):
        size = ino['size']; nb = (size + self.bsize - 1) // self.bsize; out = []
        addrs = list(ino['db'][:min(nb, 12)])
        if nb > 12:
            self.f.seek(self.base + ino['ib'][0] * self.fsize)
            ind = struct.unpack('<%dq' % (self.bsize // 8), self.f.read(self.bsize))
            addrs += list(ind[:nb - 12])
        remaining = size
        for a in addrs:
            ln = min(self.bsize, remaining)
            out.append((self.base + a * self.fsize if a else None, ln)); remaining -= ln
        return out
    def read(self, ino):
        buf = bytearray()
        for off, ln in self.blocks(ino):
            if off is None: buf += b'\0' * ln
            else: self.f.seek(off); buf += self.f.read(ln)
        return bytes(buf)
    def readdir(self, ino):
        data = self.read(ino); ents = []; p = 0
        while p + 8 <= len(data):
            d_ino, reclen, dtype, namlen = struct.unpack_from('<IHBB', data, p)
            if reclen == 0: break
            name = data[p + 8: p + 8 + namlen].decode(errors='replace')
            if d_ino: ents.append((name, d_ino, dtype))
            p += reclen
        return ents
    def lookup(self, path):
        ino = self.inode(2)
        for comp in [c for c in path.split('/') if c]:
            for name, n, t in self.readdir(ino):
                if name == comp: ino = self.inode(n); break
            else: raise SystemExit('not found: ' + comp + ' in ' + path)
        return ino

cmd, img = sys.argv[1], sys.argv[2]
with open(img, 'r+b' if cmd == 'patch' else 'rb') as f:
    if cmd == 'parts':
        g = gpt_parts(f)
        if g:
            for idx, guid, first, last, name in g:
                print(f"p{idx} {name!r:22} type {guid} start {first} end {last} size {(last-first+1)*512/1048576:.1f} MiB")
        else:
            for p in mbr_parts(f): print("mbr", p)
        sys.exit(0)
    fs = UFS2(f, ufs_offset(f))
    if cmd == 'ls':
        for name, n, t in fs.readdir(fs.lookup(sys.argv[3])): print(f"{n:8d} {'d' if t == 4 else '-'} {name}")
    elif cmd == 'cat':
        sys.stdout.buffer.write(fs.read(fs.lookup(sys.argv[3])))
    elif cmd == 'patch':
        ino = fs.lookup(sys.argv[3]); new = open(sys.argv[4], 'rb').read()
        if len(new) > ino['size']: raise SystemExit(f"new content {len(new)} > file size {ino['size']}")
        new = new + b'\n' * (ino['size'] - len(new))
        pos = 0
        for off, ln in fs.blocks(ino):
            if off is None: raise SystemExit('sparse block; refusing')
            f.seek(off); f.write(new[pos:pos + ln]); pos += ln
        f.flush(); print(f"patched {sys.argv[3]}: {ino['size']} bytes in place")
