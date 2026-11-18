import sys, base64, os
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for line in sys.stdin:
    if line.startswith("SNAPSHOT_PNG "):
        _, name, data = line.split()
        open(os.path.join(out, name), "wb").write(base64.b64decode(data))
        print("wrote", os.path.join(out, name))
    elif line.startswith("SNAPSHOT") or line.startswith("snapshot"):
        print(line.strip())
