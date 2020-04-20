import sys
import hashlib

# https://unix.stackexchange.com/questions/417554/compute-md5sum-for-each-line-in-a-file
for r in sys.stdin:
    if r.strip():
        h = hashlib.md5()
        h.update(r.encode());
        print (h.hexdigest())
