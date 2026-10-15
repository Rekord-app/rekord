import json, sys, numpy as np
d = json.load(open(sys.argv[1])); r = d["rows"]
t = np.array([x["t"] for x in r]); s = np.array([x["scale"] for x in r]); dl = np.array([x["dlog"] for x in r])
dx = np.array([x["dx"] for x in r]); dy = np.array([x["dy"] for x in r]); inl = np.array([x["inliers"] for x in r]); sh = np.array([x["sharp"] for x in r])
print("t     scale  dlog*60  pan(px/s)  inl  sharp")
for i in range(0, len(r), 6):
    print(f"{t[i]:5.2f} {s[i]:6.3f} {dl[i]*60:7.3f} {np.hypot(dx[i],dy[i])*60:9.0f} {inl[i]:4d} {sh[i]:7.0f}")
# zoom transitions: contiguous frames with |dlog| > threshold
th = 0.003; segs = []; cur = None
for i,v in enumerate(dl):
    if abs(v) > th:
        if cur is None or np.sign(v) != cur[2] or i > cur[1]+2: 
            if cur: segs.append(cur)
            cur = [i,i,np.sign(v)]
        else: cur[1] = i
if cur: segs.append(cur)
print("\ntransitions (|dlog|>%.3f/frame):" % th)
for a,b,sg in segs:
    lo = max(0,a-3); hi = min(len(r)-1,b+3)
    total = s[hi]/s[lo]
    peak = np.argmax(np.abs(dl[a:b+1]))+a
    print(f"  {'IN ' if sg>0 else 'OUT'} {t[a]:.2f}-{t[b]:.2f}s dur {(b-a+1)/60:.2f}s  scale x{total:.2f}  peak rate at {(peak-a)/(b-a+1)*100:.0f}% of span, sharpness min {sh[a:b+1].min():.0f} vs before {sh[lo]:.0f}")
