import sys, cv2, numpy as np, json
path, out = sys.argv[1], sys.argv[2]
mask_boxes = json.loads(sys.argv[3]) if len(sys.argv) > 3 else []   # [[x0,y0,x1,y1] in 0..1] regions to ignore
cap = cv2.VideoCapture(path); fps = cap.get(cv2.CAP_PROP_FPS)
orb = cv2.ORB_create(3000)
prev = None; logs = 0.0; cx = cy = 0.0; rows = []
i = 0
while True:
    ok, frame = cap.read()
    if not ok: break
    g = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY); h, w = g.shape
    m = np.full_like(g, 255)
    for x0,y0,x1,y1 in mask_boxes: m[int(y0*h):int(y1*h), int(x0*w):int(x1*w)] = 0
    kp, des = orb.detectAndCompute(g, m)
    sharp = cv2.Laplacian(g, cv2.CV_64F).var()
    ds = 0.0; dx = dy = 0.0; inl = 0
    if prev is not None and des is not None and prev[1] is not None and len(kp) > 20:
        matches = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True).match(prev[1], des)
        if len(matches) > 20:
            a = np.float32([prev[0][mm.queryIdx].pt for mm in matches]); b = np.float32([kp[mm.trainIdx].pt for mm in matches])
            M, inliers = cv2.estimateAffinePartial2D(a, b, method=cv2.RANSAC, ransacReprojThreshold=2.0, maxIters=4000)
            if M is not None:
                s = float(np.hypot(M[0,0], M[1,0])); ds = np.log(s); inl = int(inliers.sum())
                # translation of the frame centre in output pixels
                c = np.array([w/2, h/2]); dc = M[:, :2] @ c + M[:, 2] - c; dx, dy = float(dc[0]), float(dc[1])
    logs += ds; rows.append({"t": i/fps, "scale": float(np.exp(logs)), "dlog": ds, "dx": dx, "dy": dy, "inliers": inl, "sharp": sharp})
    prev = (kp, des); i += 1
json.dump({"fps": fps, "rows": rows}, open(out, "w"))
print("frames", i, "fps", fps)
