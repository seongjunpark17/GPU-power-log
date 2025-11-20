import sys
import pynvml

pynvml.nvmlInit()

idxs = [int(x) for x in sys.argv[1:]]
vals = []
for idx in idxs:
    try:
        h = pynvml.nvmlDeviceGetHandleByIndex(idx)
        mw = pynvml.nvmlDeviceGetPowerUsage(h)  # milliwatts
        vals.append(f"{mw/1000.0:.3f}")
    except Exception:
        vals.append("")

print(",".join(vals))
