import cv2, numpy as np, subprocess, sys
src, out = sys.argv[1], sys.argv[2]
N = 115  # frames before the cut (3.8333 s)
cap = cv2.VideoCapture(src); fr = []
for i in range(N):
    ok, f = cap.read(); assert ok; fr.append(f)
y0, y1, x0, x1 = 715, 800, 250, 470
st = np.stack([cv2.cvtColor(f[y0:y1, x0:x1], cv2.COLOR_BGR2GRAY) for f in fr])
mn = st.min(0)
mask = (mn > 55).astype(np.uint8) * 255
mask = cv2.dilate(mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9)))
print('mask px', int((mask > 0).sum()))
ff = subprocess.Popen(['ffmpeg', '-y', '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'bgr24', '-s', '720x1280', '-framerate', '30', '-i', '-',
    '-c:v', 'libx264', '-crf', '16', '-preset', 'medium', '-pix_fmt', 'yuv420p', '-r', '30', '-video_track_timescale', '15360', out], stdin=subprocess.PIPE)
soft = cv2.GaussianBlur(mask, (7, 7), 0).astype(np.float32)[..., None] / 255
for f in fr:
    roi = f[y0:y1, x0:x1]
    fix = cv2.inpaint(roi, mask, 5, cv2.INPAINT_TELEA)
    fix = cv2.GaussianBlur(fix, (5, 5), 0) * soft + fix * (1 - soft)   # soften the patch only
    g = f.copy(); g[y0:y1, x0:x1] = (fix * soft + roi * (1 - soft)).astype(np.uint8)
    ff.stdin.write(g.tobytes())
ff.stdin.close(); assert ff.wait() == 0
