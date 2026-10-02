# -*- coding: utf-8 -*-
"""Extract newc cpio archive (ramdisk.cpio) into a directory."""
import os, sys, stat

SRC = r"E:/111/ldn-al20/extracted/ramdisk.cpio"
DST = r"E:/111/ldn-al20/ramdisk"

data = open(SRC, "rb").read()
pos = 0
count = 0
while pos + 110 <= len(data):
    magic = data[pos:pos+6]
    if magic not in (b"070701", b"070702"):
        break
    fields = [int(data[pos+6+i*8:pos+14+i*8], 16) for i in range(13)]
    ino, mode, uid, gid, nlink, mtime, filesize, devmaj, devmin, rdevmaj, rdevmin, namesize, check = fields
    name_start = pos + 110
    name = data[name_start:name_start+namesize-1].decode("utf-8", errors="replace")
    # header+name padded to 4
    hdr_end = (name_start + namesize + 3) & ~3
    fdata = data[hdr_end:hdr_end+filesize]
    pos = (hdr_end + filesize + 3) & ~3
    if name == "TRAILER!!!":
        break
    rel = name.lstrip("./").lstrip("/")
    if not rel:
        continue
    path = os.path.join(DST, rel.replace("/", os.sep))
    ftype = mode & 0o170000
    try:
        if ftype == stat.S_IFDIR:
            os.makedirs(path, exist_ok=True)
        elif ftype == stat.S_IFLNK:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            target = fdata.decode("utf-8", errors="replace")
            # store symlink as text file with .symlink suffix (Windows-safe)
            open(path + ".symlink", "w").write(target)
        elif ftype == stat.S_IFREG:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "wb").write(fdata)
            count += 1
    except Exception as e:
        print("skip", name, e)
print("files extracted:", count)
