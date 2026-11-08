"""Bereinigen für die Fotos-App (wie Apples „Bereinigen“ / Clean Up): markierte Objekte aus einem Foto entfernen.

Apple rechnet das auf dem iPhone mit einem eigenen Modell; eine öffentliche Schnittstelle dafür gibt es nicht.
Hier übernimmt das LaMa-Modell (Inpainting, ONNX, nur CPU) auf dem eigenen Server.

POST /bereinigen  multipart: image (JPEG/PNG), mask (PNG, weiß = entfernen, beliebige Größe)
→ image/jpeg in der Größe des Eingangsbildes.  Anmeldung wie bei Immich (Authorization: Bearer … / x-api-key).

Nur der Bereich um die Markierung wird gerechnet (auf 512 px skaliert) und weich zurückgesetzt – der Rest des Fotos
bleibt Pixel für Pixel unverändert.
"""
import cgi, io, logging, os, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import cv2, numpy as np, onnxruntime as ort, requests

IMMICH = os.environ.get("IMMICH_URL", "http://immich-server:2283/api")
PORT = int(os.environ.get("PORT", "2285"))
MODEL = os.environ.get("MODEL", "/models/lama_fp32.onnx")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.info

opts = ort.SessionOptions(); opts.intra_op_num_threads = int(os.environ.get("THREADS", "4"))
sess = ort.InferenceSession(MODEL, opts, providers=["CPUExecutionProvider"])
NAMES = [i.name for i in sess.get_inputs()]
_run = threading.Lock()
_users: dict[str, float] = {}


def authorized(h) -> bool:
    cred = h.get("Authorization") or h.get("x-api-key") or ""
    if not cred:
        return False
    if _users.get(cred, 0) > time.time():
        return True
    hdr = {"Authorization": cred} if h.get("Authorization") else {"x-api-key": cred}
    ok = requests.get(f"{IMMICH}/users/me", headers=hdr, timeout=10).status_code == 200
    if ok:
        _users[cred] = time.time() + 600
    return ok


def lama(crop: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """crop: 512×512×3 RGB uint8, mask: 512×512 uint8 (0/255) → 512×512×3 RGB uint8"""
    img = crop.astype(np.float32).transpose(2, 0, 1)[None] / 255.0
    m = (mask > 127).astype(np.float32)[None, None]
    feeds = {NAMES[0]: img, NAMES[1]: m}
    with _run:
        out = sess.run(None, feeds)[0][0]
    if out.max() <= 1.5:
        out = out * 255.0
    return np.clip(out.transpose(1, 2, 0), 0, 255).astype(np.uint8)


def clean(image: np.ndarray, mask: np.ndarray) -> np.ndarray:
    H, W = image.shape[:2]
    if mask.shape[:2] != (H, W):
        mask = cv2.resize(mask, (W, H), interpolation=cv2.INTER_LINEAR)
    mask = (mask > 127).astype(np.uint8) * 255
    if not mask.any():
        return image
    k = max(3, int(max(H, W) / 300)) | 1          # etwas über den Rand der Markierung hinaus
    mask = cv2.dilate(mask, np.ones((k, k), np.uint8))
    ys, xs = np.nonzero(mask)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    # quadratischer Ausschnitt: Markierung + reichlich Umgebung (LaMa braucht Kontext)
    side = int(max(x1 - x0, y1 - y0) * 2.2) + 64
    side = max(side, min(512, max(H, W)))
    side = min(side, max(H, W))
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    sx = int(np.clip(cx - side // 2, 0, max(0, W - side))); sy = int(np.clip(cy - side // 2, 0, max(0, H - side)))
    sw, sh = min(side, W), min(side, H)
    crop = image[sy:sy + sh, sx:sx + sw]; mcrop = mask[sy:sy + sh, sx:sx + sw]
    rgb = cv2.cvtColor(cv2.resize(crop, (512, 512), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB)
    m512 = cv2.resize(mcrop, (512, 512), interpolation=cv2.INTER_NEAREST)
    res = cv2.cvtColor(lama(rgb, m512), cv2.COLOR_RGB2BGR)
    res = cv2.resize(res, (sw, sh), interpolation=cv2.INTER_CUBIC)
    # weiche Kante, nur der markierte Bereich wird ersetzt
    soft = cv2.GaussianBlur(mcrop.astype(np.float32) / 255.0, (0, 0), sigmaX=k / 2)[..., None]
    out = image.copy()
    out[sy:sy + sh, sx:sx + sw] = (res * soft + crop * (1 - soft)).astype(np.uint8)
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        if self.path != "/bereinigen":
            return self.send_error(404)
        if not authorized(self.headers):
            return self.send_error(401)
        try:
            form = cgi.FieldStorage(fp=self.rfile, headers=self.headers, environ={"REQUEST_METHOD": "POST"})
            img = cv2.imdecode(np.frombuffer(form["image"].file.read(), np.uint8), cv2.IMREAD_COLOR)
            msk = cv2.imdecode(np.frombuffer(form["mask"].file.read(), np.uint8), cv2.IMREAD_GRAYSCALE)
            t = time.time()
            out = clean(img, msk)
            ok, jpg = cv2.imencode(".jpg", out, [cv2.IMWRITE_JPEG_QUALITY, 95])
            log("bereinigt %dx%d in %.1f s", img.shape[1], img.shape[0], time.time() - t)
            self.send_response(200); self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(jpg))); self.end_headers(); self.wfile.write(jpg.tobytes())
        except Exception as e:
            log("Fehler: %s", e)
            self.send_error(400, str(e))


if __name__ == "__main__":
    log("Bereinigen läuft auf Port %d (Modell %s)", PORT, MODEL)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
