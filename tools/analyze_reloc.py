import sys, collections
sec = ''
loaded = collections.Counter()
dbg = collections.Counter()
for l in sys.stdin:
    if l.startswith('Relocation section'):
        p = l.split()
        sec = p[2].strip("'\"") if len(p) > 2 else ''
        continue
    p = l.split()
    if len(p) >= 3 and p[2].startswith('R_AARCH64'):
        if 'debug' in sec:
            dbg[p[2]] += 1
        else:
            loaded[p[2]] += 1
print("== LOADED (non-debug) sections ==")
for k, v in loaded.most_common():
    print(f"  {k}: {v}")
print("== DEBUG sections (stripped, not loaded) ==")
for k, v in dbg.most_common():
    print(f"  {k}: {v}")
