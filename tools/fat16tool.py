#!/usr/bin/env python3
# fat16tool.py — list / extract files from a FAT12/FAT16 volume at a byte offset in an image.
#   fat16tool.py ls   <image> <offset>
#   fat16tool.py get  <image> <offset> <PATH/IN/FAT> <outfile>
import struct, sys
img, off = sys.argv[2], int(sys.argv[3])
f = open(img, 'rb'); f.seek(off); b = f.read(512)
bps, spc, rsv, nfat, rootent, tot16, media, spf16 = struct.unpack_from('<HBHBHHBH', b, 11)
tot32 = struct.unpack_from('<I', b, 32)[0]; tot = tot16 or tot32
fat_off = off + rsv * bps; root_off = fat_off + nfat * spf16 * bps
root_secs = (rootent * 32 + bps - 1) // bps; data_off = root_off + root_secs * bps
nclus = (tot - rsv - nfat * spf16 - root_secs) // spc; fat12 = nclus < 4085
f.seek(fat_off); fat = f.read(spf16 * bps)
def nxt(c):
    if fat12:
        i = c + c // 2; v = struct.unpack_from('<H', fat, i)[0]
        return (v >> 4) if c & 1 else (v & 0xfff)
    return struct.unpack_from('<H', fat, c * 2)[0]
def chain(c):
    out = []
    while 2 <= c < (0xff8 if fat12 else 0xfff8):
        out.append(c); c = nxt(c)
    return out
def read_chain(c, size):
    data = bytearray()
    for cl in chain(c):
        f.seek(data_off + (cl - 2) * spc * bps); data += f.read(spc * bps)
    return bytes(data[:size]) if size else bytes(data)
def entries(raw):
    ents = []; lfn = ''
    for i in range(0, len(raw), 32):
        e = raw[i:i + 32]
        if e[0] == 0: break
        if e[0] == 0xE5: lfn = ''; continue
        attr = e[11]
        if attr == 0x0F:
            part = (e[1:11] + e[14:26] + e[28:32]).decode('utf-16-le', 'replace').split('￿')[0].rstrip('\0')
            lfn = part + lfn; continue
        name = (e[:8].decode(errors='replace').rstrip() + ('.' + e[8:11].decode(errors='replace').rstrip() if e[8:11].strip() else '')).strip()
        first = struct.unpack_from('<H', e, 26)[0]; size = struct.unpack_from('<I', e, 28)[0]
        ents.append((lfn or name, attr, first, size)); lfn = ''
    return ents
def walk(raw, prefix):
    for name, attr, first, size in entries(raw):
        if name in ('.', '..'): continue
        if attr & 0x10:
            print(f"{prefix}{name}/"); walk(read_chain(first, 0), prefix + name + '/')
        else:
            print(f"{prefix}{name}  ({size} bytes)")
def find(raw, parts):
    for name, attr, first, size in entries(raw):
        if name.upper() == parts[0].upper():
            if len(parts) == 1: return first, size
            return find(read_chain(first, 0), parts[1:])
    raise SystemExit('not found: ' + '/'.join(parts))
f.seek(root_off); root = f.read(root_secs * bps)
print(f"FAT{'12' if fat12 else '16'} bps={bps} spc={spc} clusters={nclus} total_sectors={tot} label={b[43:54]!r}", file=sys.stderr)
if sys.argv[1] == 'ls': walk(root, '/')
elif sys.argv[1] == 'get':
    first, size = find(root, [p for p in sys.argv[4].split('/') if p]); open(sys.argv[5], 'wb').write(read_chain(first, size)); print(f"extracted {sys.argv[4]} ({size} bytes)")
