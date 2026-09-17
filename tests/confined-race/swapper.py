import os, sys
root, outside = sys.argv[1], sys.argv[2]
sub, real = os.path.join(root, "sub"), os.path.join(root, "sub_real")
# Until the suite kills it: a fixed end let the last operations run unraced.
while True:
    try:
        os.rename(sub, real); os.symlink(outside, sub)
        os.unlink(sub); os.rename(real, sub)
    except OSError:
        pass
