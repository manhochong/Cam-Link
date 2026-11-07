import ctypes
import platform

if platform.system() == "Windows":
    try:
        # 參數 2 代表 PROCESS_PER_MONITOR_DPI_AWARE，能讓文字與介面達到最銳利的狀態
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        pass

import base64
import hashlib
import os
import re
import socket
import ssl
import sys
import tempfile
import threading
import time
import urllib.parse
from ctypes import wintypes
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID
from PySide6.QtCore import QPointF, QRect, QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import (
    QColor,
    QFont,
    QGuiApplication,
    QIcon,
    QImage,
    QImageReader,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
)
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QFileDialog,
    QFrame,
    QGraphicsDropShadowEffect,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QSizePolicy,
    QSystemTrayIcon,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

VERSION = "0.2.25"
PORT = 9443
PAPER = "#F4F6F8"
INK = "#1C1E21"
GRAY = "#8A9099"
WARM = "#FF8430"
ACCENT = "#FF6B1A"
LINE = "#E2E5EA"
PHOTO = "#45474A"
FAINT = "#BABCC0"
FONT = "Microsoft JhengHei UI"

FILENAME = re.compile(r"(?i)^[a-z0-9][a-z0-9_.-]{0,190}\.jpe?g$")
SHA_HEADER = re.compile(r"^[a-f0-9]{64}$")


class DataBlob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


_crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
_kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
_crypt32.CryptProtectData.argtypes = [
    ctypes.POINTER(DataBlob), wintypes.LPCWSTR, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(DataBlob)
]
_crypt32.CryptProtectData.restype = wintypes.BOOL
_crypt32.CryptUnprotectData.argtypes = [
    ctypes.POINTER(DataBlob), ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(DataBlob)
]
_crypt32.CryptUnprotectData.restype = wintypes.BOOL
_kernel32.LocalFree.argtypes = [ctypes.c_void_p]
_kernel32.LocalFree.restype = ctypes.c_void_p


def _blob(data):
    buf = ctypes.create_string_buffer(data)
    return DataBlob(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))), buf


def _from_blob(blob):
    try:
        return ctypes.string_at(blob.pbData, blob.cbData)
    finally:
        _kernel32.LocalFree(blob.pbData)


def protect(data):
    incoming, hold = _blob(data)
    outgoing = DataBlob()
    if not _crypt32.CryptProtectData(ctypes.byref(incoming), None, None, None, None, 1, ctypes.byref(outgoing)):
        raise OSError(ctypes.get_last_error(), "CryptProtectData")
    del hold
    return _from_blob(outgoing)


def unprotect(data):
    incoming, hold = _blob(data)
    outgoing = DataBlob()
    if not _crypt32.CryptUnprotectData(ctypes.byref(incoming), None, None, None, None, 1, ctypes.byref(outgoing)):
        raise OSError(ctypes.get_last_error(), "CryptUnprotectData")
    del hold
    return _from_blob(outgoing)


def settings_dir():
    root = os.environ.get("LOCALAPPDATA") or str(Path.home())
    return Path(root) / "CamLinkReceiver"


def pictures_dir():
    return Path.home() / "Pictures" / "Cam Link"


def remembered_folder():
    path = settings_dir() / "folder.txt"
    if path.exists():
        text = path.read_text(encoding="utf-8").strip()
        if text:
            return text
    return str(pictures_dir())


def remembered_ip():
    path = settings_dir() / "ip.txt"
    if path.exists():
        return path.read_text(encoding="utf-8").strip()
    return ""


def auto_start_on():
    path = settings_dir() / "auto_start.txt"
    return path.exists() and path.read_text(encoding="utf-8").strip() == "1"


def write_setting(name, value):
    settings_dir().mkdir(parents=True, exist_ok=True)
    (settings_dir() / name).write_text(value, encoding="utf-8", newline="\n")


def _bundled(name):
    if getattr(sys, "frozen", False):
        packed = Path(getattr(sys, "_MEIPASS", "")) / name
        if packed.exists():
            return packed
    here = Path(__file__).resolve().parent
    for candidate in (here / name, here.parent / "release" / "brand" / name, here.parent / "windows" / name):
        if candidate.exists():
            return candidate
    return here / name


def logo_file():
    return _bundled("Cam-Link.png")


def icon_file():
    return _bundled("CamLink.ico")


def load_identity(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "identity.dat"
    if target.exists():
        raw = unprotect(target.read_bytes()).decode("utf-8")
    else:
        password = os.urandom(6).hex()
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Cam Link Receiver")])
        now = datetime.now(timezone.utc)
        cert = (
            x509.CertificateBuilder()
            .subject_name(name)
            .issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(days=1))
            .not_valid_after(now + timedelta(days=365 * 5))
            .sign(key, hashes.SHA256())
        )
        pfx = pkcs12.serialize_key_and_certificates(b"Cam Link Receiver", key, cert, None, serialization.NoEncryption())
        payload = (password + "\n" + base64.b64encode(pfx).decode("ascii")).encode("utf-8")
        temporary = target.with_name(target.name + "." + os.urandom(8).hex())
        temporary.write_bytes(protect(payload))
        os.replace(temporary, target)
        raw = payload.decode("utf-8")
    password, encoded = raw.split("\n", 1)
    pfx = base64.b64decode(encoded)
    return password, pfx_material(pfx)


def pfx_material(data):
    last = None
    for password in (b"", None):
        try:
            key, cert, _extra = pkcs12.load_key_and_certificates(data, password)
            if key is not None and cert is not None:
                return key, cert
        except Exception as exc:
            last = exc
    raise ValueError("無法讀取接收身分") from last


class Receiver:
    def __init__(self, ip, dest, settings, report, live=None):
        self.folder = str(Path(dest).resolve())
        os.makedirs(self.folder, exist_ok=True)
        self.report = report
        self.live = live
        self.password, (key, cert) = load_identity(settings)
        der = cert.public_bytes(serialization.Encoding.DER)
        self.fingerprint = hashlib.sha256(der).hexdigest()
        self._auth = "Basic " + base64.b64encode(b"camlink:" + self.password.encode("utf-8")).decode("ascii")
        self._pem = tempfile.TemporaryDirectory(prefix="camlink-tls-")
        cert_path = Path(self._pem.name) / "cert.pem"
        key_path = Path(self._pem.name) / "key.pem"
        cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        self._context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self._context.minimum_version = ssl.TLSVersion.TLSv1_2
        self._context.maximum_version = ssl.TLSVersion.TLSv1_2
        self._context.load_cert_chain(cert_path, key_path)
        self._slots = threading.Semaphore(3)
        self.faults = 0
        self._stopped = False
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.bind((ip, PORT))
        self._sock.listen(8)
        self._sock.settimeout(0.5)
        self._thread = threading.Thread(target=self._serve, name="camlink-receive", daemon=True)
        self._thread.start()

    def close(self):
        self._stopped = True
        try:
            self._sock.close()
        except OSError:
            pass
        self._thread.join(timeout=2)
        self._pem.cleanup()

    def _serve(self):
        while not self._stopped:
            try:
                client, _addr = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            if not self._slots.acquire(blocking=False):
                threading.Thread(target=self._reject, args=(client,), daemon=True).start()
                continue
            threading.Thread(target=self._handle, args=(client,), daemon=True).start()

    def _reject(self, client):
        try:
            client.settimeout(5)
            tls = self._context.wrap_socket(client, server_side=True)
            try:
                _reply(tls, 503)
            finally:
                try:
                    tls.settimeout(2)
                    tls.unwrap()
                except OSError:
                    pass
                tls.close()
        except Exception:
            self.faults += 1
        finally:
            try:
                client.close()
            except OSError:
                pass

    def _handle(self, client):
        try:
            client.settimeout(20)
            tls = self._context.wrap_socket(client, server_side=True)
            try:
                self._transaction(tls)
            finally:
                try:
                    tls.settimeout(5)
                    tls.unwrap()
                except OSError:
                    pass
                tls.close()
        except Exception:
            self.faults += 1
        finally:
            try:
                client.close()
            except OSError:
                pass
            self._slots.release()

    def _transaction(self, tls):
        request = _line(tls).split(" ")
        if len(request) != 3:
            _reply(tls, 400)
            return
        headers = {}
        for index in range(65):
            line = _line(tls)
            if line == "":
                break
            if index >= 64:
                raise OSError("too many headers")
            split = line.find(":")
            if split < 1:
                raise OSError("bad header")
            headers.setdefault(line[:split].lower(), line[split + 1 :].strip())
        if headers.get("authorization") != self._auth:
            _reply(tls, 401)
            return
        if request[0] == "HEAD" and request[1] == "/inbox/":
            _reply(tls, 200, "X-CamLink-Receiver: 1\r\n")
            return
        if not request[1].startswith("/inbox/"):
            _reply(tls, 404)
            return
        name = urllib.parse.unquote(request[1][7:])
        if not FILENAME.fullmatch(name):
            _reply(tls, 400)
            return
        if request[0] != "PUT":
            _reply(tls, 405)
            return
        try:
            size = int(headers.get("content-length", ""))
        except ValueError:
            size = 0
        expected = headers.get("x-camlink-sha256", "")
        if size < 1 or size > 512 * 1024 * 1024 or not SHA_HEADER.fullmatch(expected):
            _reply(tls, 400)
            return
        if headers.get("expect", "").lower() == "100-continue":
            _send(tls, b"HTTP/1.1 100 Continue\r\n\r\n")
        transfer = os.urandom(16).hex()
        temporary = os.path.join(self.folder, ".camlink-" + transfer + ".part")
        started = time.monotonic()
        got = 0
        self._notify(transfer, name, 0, size, False, False, started)

        def tick(amount):
            nonlocal got
            got = amount
            self._notify(transfer, name, got, size, False, False, started)

        saved = False
        try:
            with open(temporary, "wb") as handle:
                got = _copy(handle, tls, size, tick)
                handle.flush()
                os.fsync(handle.fileno())
            if _digest(temporary) != expected:
                self._notify(transfer, name, got, size, True, False, started)
                _reply(tls, 422)
                return
            final = os.path.join(self.folder, name)
            try:
                os.rename(temporary, final)
            except OSError:
                if not os.path.exists(final) or _digest(final) != expected:
                    self._notify(transfer, name, got, size, True, False, started)
                    _reply(tls, 409)
                    return
            saved = True
            self._notify(transfer, name, size, size, True, True, started)
            if self.report:
                self.report(datetime.now().strftime("%H:%M:%S") + "  已核對  " + name)
            _reply(tls, 201, "X-CamLink-SHA256: " + expected + "\r\n")
        except Exception:
            if not saved:
                self._notify(transfer, name, got, size, True, False, started)
            raise
        finally:
            if os.path.exists(temporary):
                try:
                    os.remove(temporary)
                except OSError:
                    pass

    def _notify(self, transfer, name, got, size, finished, ok, started):
        if self.live is None:
            return
        try:
            elapsed = max(0.05, time.monotonic() - started)
            self.live(
                {
                    "id": transfer,
                    "name": name,
                    "got": got,
                    "size": size,
                    "finished": finished,
                    "ok": ok,
                    "rate": got / 1048576.0 / elapsed,
                    "note": ("已核對" if ok else "未核對") if finished else "接收中",
                }
            )
        except Exception:
            pass


def _line(stream):
    data = bytearray()
    while len(data) < 8192:
        piece = stream.read(1)
        if not piece:
            raise EOFError
        if piece == b"\n":
            return data.decode("ascii").rstrip("\r")
        data.extend(piece)
    raise OSError("Header too large")


def _send(stream, payload):
    if isinstance(payload, str):
        payload = payload.encode("ascii")
    sent = 0
    while sent < len(payload):
        count = stream.write(payload[sent:])
        if not count:
            raise OSError("連線已中斷")
        sent += count


def _reply(stream, code, extra=""):
    _send(stream, f"HTTP/1.1 {code} Result\r\nContent-Length: 0\r\nConnection: close\r\n{extra}\r\n")


def _copy(handle, stream, total, tick):
    got = 0
    mark = time.monotonic()
    while got < total:
        piece = stream.read(min(131072, total - got))
        if not piece:
            raise EOFError
        handle.write(piece)
        got += len(piece)
        now = time.monotonic()
        if now - mark >= 0.16:
            mark = now
            tick(got)
    tick(got)
    return got


def _digest(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for piece in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(piece)
    return digest.hexdigest()


def ipv4s():
    found = []
    try:
        for item in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET, socket.SOCK_STREAM):
            ip = item[4][0]
            if not ip.startswith("127.") and ip not in found:
                found.append(ip)
    except OSError:
        pass
    if found:
        return found
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("192.168.1.1", 9))
        ip = probe.getsockname()[0]
        probe.close()
        if not ip.startswith("127."):
            return [ip]
    except OSError:
        pass
    return []


_EXP = bytearray(512)
_LOG = [0] * 256
_x = 1
for _i in range(255):
    _EXP[_i] = _x
    _LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]
_FORMAT_M = (0x5412, 0x5125, 0x5E7C, 0x5B4B, 0x45F9, 0x40CE, 0x4F97, 0x4AA0)


def _mul(a, b):
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def _generator(ecc):
    poly = bytearray(b"\x01")
    for i in range(ecc):
        nxt = bytearray(len(poly) + 1)
        for j, value in enumerate(poly):
            nxt[j] ^= value
            nxt[j + 1] ^= _mul(value, _EXP[i])
        poly = nxt
    return poly[1:]


def _reed(data, ecc):
    gen = _generator(ecc)
    work = bytearray(data) + bytearray(ecc)
    for i in range(len(data)):
        coef = work[i]
        if coef == 0:
            continue
        for j in range(ecc):
            work[i + 1 + j] ^= _mul(gen[j], coef)
    return work[len(data) :]


def _add(bits, value, count):
    for shift in range(count - 1, -1, -1):
        bits.append(((value >> shift) & 1) == 1)


def qr_modules(text):
    raw = text.encode("utf-8")
    version = 2 if len(raw) <= 26 else 3 if len(raw) <= 42 else 4
    if len(raw) > 62:
        raise ValueError("QR payload too long")
    blocks, data_len, ecc_len = (2, 32, 18) if version == 4 else (1, 44, 26) if version == 3 else (1, 28, 16)
    bits = []
    _add(bits, 0x4, 4)
    _add(bits, len(raw), 8)
    for value in raw:
        _add(bits, value, 8)
    capacity = blocks * data_len * 8
    for _ in range(4):
        if len(bits) >= capacity:
            break
        bits.append(False)
    while len(bits) % 8:
        bits.append(False)
    data = bytearray(blocks * data_len)
    for i in range(len(bits) // 8):
        value = 0
        for b in range(8):
            if bits[i * 8 + b]:
                value |= 1 << (7 - b)
        data[i] = value
    pad = 0
    for i in range(len(bits) // 8, len(data)):
        data[i] = 0xEC if pad % 2 == 0 else 0x11
        pad += 1
    ecc = []
    for block in range(blocks):
        ecc.append(_reed(data[block * data_len : (block + 1) * data_len], ecc_len))
    message = bytearray()
    for i in range(data_len):
        for block in range(blocks):
            message.append(data[block * data_len + i])
    for i in range(ecc_len):
        for block in range(blocks):
            message.append(ecc[block][i])
    stream = []
    for value in message:
        _add(stream, value, 8)
    stream.extend([False] * 7)
    size = 17 + version * 4
    matrix = [[2] * size for _ in range(size)]
    for i in range(9):
        matrix[i][8] = 0
        matrix[8][i] = 0
    for i in range(8):
        matrix[size - 1 - i][8] = 0
        matrix[8][size - 1 - i] = 0
    bit = 1
    for i in range(8, size - 8):
        matrix[6][i] = matrix[i][6] = bit
        bit ^= 1
    _finder(matrix, 0, 0)
    _finder(matrix, 0, size - 7)
    _finder(matrix, size - 7, 0)
    align = (6, 18) if version == 2 else (6, 22) if version == 3 else (6, 26)
    for y in align:
        for x in align:
            if (x == 6 and y == 6) or (x == 6 and y == align[-1]) or (y == 6 and x == align[-1]):
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    matrix[y + dy][x + dx] = 0 if max(abs(dx), abs(dy)) == 1 else 1
    region = [[matrix[r][c] == 2 for c in range(size)] for r in range(size)]
    index = 0
    step = size - 1
    while step > 0:
        right = step - 1 if step <= 6 else step
        for vertical in range(size):
            for z in range(2):
                col = right - z
                up = ((right & 2) == 0) ^ (col < 6)
                row = size - 1 - vertical if up else vertical
                if matrix[row][col] == 2 and index < len(stream):
                    matrix[row][col] = 1 if stream[index] else 0
                    index += 1
        step -= 2
    if index != len(stream):
        raise RuntimeError(f"QR placement {index}/{len(stream)}")
    for r in range(size):
        for c in range(size):
            if region[r][c]:
                if matrix[r][c] == 2:
                    matrix[r][c] = 0
                if ((r + c) & 1) == 0:
                    matrix[r][c] ^= 1
    fmt = _FORMAT_M[0]
    v_off = h_off = 0
    for i in range(8):
        v_bit = (fmt >> i) & 1
        h_bit = (fmt >> (14 - i)) & 1
        if i == 6:
            v_off += 1
            h_off = 1
        matrix[i + v_off][8] = v_bit
        matrix[8][i + h_off] = h_bit
        matrix[8][size - 1 - i] = v_bit
        matrix[size - 1 - i][8] = h_bit
    matrix[size - 8][8] = 1
    return [[cell == 1 for cell in row] for row in matrix]


def _finder(matrix, row, col):
    for r in range(7):
        for c in range(7):
            edge = r in (0, 6) or c in (0, 6)
            core = 2 <= r <= 4 and 2 <= c <= 4
            matrix[row + r][col + c] = 1 if edge or core else 0
    size = len(matrix)
    for i in range(-1, 8):
        if 0 <= row + i < size:
            if col - 1 >= 0:
                matrix[row + i][col - 1] = 0
            if col + 7 < size:
                matrix[row + i][col + 7] = 0
        if 0 <= col + i < size:
            if row - 1 >= 0:
                matrix[row - 1][col + i] = 0
            if row + 7 < size:
                matrix[row + 7][col + i] = 0


def save_qr(payload, path):
    modules = qr_modules(payload)
    n = len(modules)
    scale, quiet = 8, 4
    span = n + quiet * 2
    image = QImage(span * scale, span * scale, QImage.Format_RGB32)
    image.fill(QColor("white"))
    painter = QPainter(image)
    painter.fillRect(image.rect(), QColor("white"))
    painter.setPen(Qt.NoPen)
    painter.setBrush(QColor("black"))
    for r, row in enumerate(modules):
        for c, on in enumerate(row):
            if on:
                painter.drawRect((c + quiet) * scale, (r + quiet) * scale, scale, scale)
    painter.end()
    image.save(str(path))


def amount(n):
    if n >= 1048576:
        return f"{n / 1048576.0:.1f} MB"
    return f"{max(0, n // 1024)} KB"


def fixture(root, ip):
    root = Path(root)
    server = None
    try:
        server = Receiver(ip, str(root / "inbox"), str(root / "profile"), lambda _text: None)
        (root / "pair.tmp").write_text(server.fingerprint + "\n" + server.password, encoding="utf-8", newline="\n")
        for _ in range(180):
            if (root / "stop").exists():
                break
            time.sleep(1)
        return 0
    except Exception as exc:
        try:
            root.mkdir(parents=True, exist_ok=True)
            (root / "failure.txt").write_text(type(exc).__name__ + " " + str(exc), encoding="utf-8", newline="\n")
        except OSError:
            pass
        return 1
    finally:
        if server is not None:
            server.close()


QSS = f"""
* {{
  font-family: "{FONT}";
  color: {INK};
}}
QWidget#window {{ background: {PAPER}; }}
QFrame#card, QFrame#setup, QFrame#files {{
  background: white;
  border: 1px solid {LINE};
  border-radius: 18px;
}}
QFrame#tile {{
  background: white;
  border: 1px solid {LINE};
  border-radius: 14px;
}}
QLabel {{ background: transparent; }}
QLabel#muted, QLabel#section {{ color: {GRAY}; }}
QComboBox, QLineEdit {{
  background: white;
  border: 1px solid {LINE};
  border-radius: 8px;
  padding: 4px 8px;
  min-height: 28px;
}}
QComboBox::drop-down {{ border: none; width: 22px; }}
QPushButton#choose {{
  background: {PAPER};
  border: 1px solid {LINE};
  border-radius: 10px;
  min-width: 72px;
  min-height: 36px;
}}
QPushButton#open {{
  background: transparent;
  border: none;
  color: {ACCENT};
  padding: 0;
}}
QPushButton#qr {{
  background: white;
  border: 1px solid {LINE};
  border-radius: 12px;
  min-height: 44px;
}}
QPushButton#start {{
  background: {WARM};
  color: white;
  border: none;
  border-radius: 18px;
  font-weight: 700;
  min-height: 52px;
}}
QPushButton#start[running="true"] {{
  background: {INK};
  color: white;
}}
QTableWidget {{
  background: white;
  border: none;
  gridline-color: #F0F2F5;
  selection-background-color: #F4F6F8;
  selection-color: {INK};
}}
QHeaderView::section {{
  background: white;
  color: {GRAY};
  border: none;
  border-bottom: 1px solid #F0F2F5;
  padding: 4px 2px;
  font-weight: 400;
}}
QProgressBar {{
  background: {LINE};
  border: none;
  border-radius: 2px;
  max-height: 4px;
  min-height: 4px;
}}
QProgressBar::chunk {{
  background: {ACCENT};
  border-radius: 2px;
}}
"""


def shadow(widget, blur=28, y=6, alpha=26):
    effect = QGraphicsDropShadowEffect(widget)
    effect.setBlurRadius(blur)
    effect.setOffset(0, y)
    effect.setColor(QColor(28, 30, 33, alpha))
    widget.setGraphicsEffect(effect)


def font(size, bold=False, family=FONT):
    face = QFont(family, size)
    face.setBold(bold)
    face.setStyleStrategy(QFont.PreferAntialias)
    face.setHintingPreference(QFont.PreferDefaultHinting)
    return face


class PhotoWell(QWidget):
    def __init__(self):
        super().__init__()
        self._image = None
        self._scaled = None
        self._key = None
        self.caption = ""
        self.setMinimumHeight(240)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)

    def show_photo(self, path, name):
        reader = QImageReader(path)
        reader.setAutoTransform(True)
        size = reader.size()
        limit = 1800
        if size.isValid() and max(size.width(), size.height()) > limit:
            scale = limit / max(size.width(), size.height())
            reader.setScaledSize(QSize(max(1, int(size.width() * scale)), max(1, int(size.height() * scale))))
        image = reader.read()
        if image.isNull():
            image = QImage(path)
        self._image = None if image.isNull() else image
        self._scaled = None
        self.caption = name if self._image is not None else name + "  已存檔"
        self.update()

    def clear_photo(self):
        self._image = None
        self._scaled = None
        self.caption = ""
        self.update()

    def paintEvent(self, _event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setRenderHint(QPainter.SmoothPixmapTransform)
        rect = QRectF(self.rect())
        path = QPainterPath()
        path.addRoundedRect(rect.adjusted(0, 0, -1, -1), 22, 22)
        painter.setClipPath(path)
        painter.fillRect(rect, QColor(PHOTO))
        if self._image is not None and not self._image.isNull():
            area = self.rect().adjusted(12, 12, -12, -46)
            dpr = self.devicePixelRatioF()
            key = (area.width(), area.height(), round(dpr * 100))
            if self._scaled is None or self._key != key:
                self._scaled = QPixmap.fromImage(self._image).scaled(
                    max(1, int(area.width() * dpr)),
                    max(1, int(area.height() * dpr)),
                    Qt.KeepAspectRatio,
                    Qt.SmoothTransformation,
                )
                self._scaled.setDevicePixelRatio(dpr)
                self._key = key
            shown = self._scaled.deviceIndependentSize()
            x = area.x() + (area.width() - shown.width()) / 2
            y = area.y() + (area.height() - shown.height()) / 2
            painter.drawPixmap(QPointF(x, y), self._scaled)
            painter.fillRect(0, self.height() - 34, self.width(), 34, QColor(20, 20, 20, 210))
            painter.setPen(QColor(250, 246, 238))
            painter.setFont(font(9))
            painter.drawText(QRect(14, self.height() - 34, self.width() - 28, 34), Qt.AlignVCenter | Qt.AlignLeft, self.caption)
            return
        painter.setPen(Qt.NoPen)
        painter.setBrush(QColor(86, 88, 92))
        cx, cy, d = self.width() / 2, self.height() / 2 - 18, 64
        painter.drawEllipse(QRectF(cx - d / 2, cy - d / 2, d, d))
        pen = QPen(QColor(198, 200, 204), 1.6)
        painter.setPen(pen)
        painter.setBrush(Qt.NoBrush)
        painter.drawRect(QRectF(cx - 11, cy - 8, 22, 16))
        painter.drawLine(QPointF(cx - 7, cy + 8), QPointF(cx - 2, cy + 1))
        painter.drawLine(QPointF(cx - 2, cy + 1), QPointF(cx + 2, cy + 5))
        painter.drawLine(QPointF(cx + 2, cy + 5), QPointF(cx + 11, cy - 4))
        painter.drawEllipse(QRectF(cx + 4, cy - 5, 4, 4))
        painter.setPen(QColor(FAINT))
        painter.setFont(font(16))
        painter.drawText(QRect(0, int(cy + d / 2 + 8), self.width(), 36), Qt.AlignHCenter | Qt.AlignTop, "等待第一張照片")


class StartButton(QPushButton):
    def paintEvent(self, event):
        super().paintEvent(event)
        if self.text() != "開始接收":
            return
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        d = 18
        x = self.width() / 2 - 58
        y = (self.height() - d) / 2
        painter.setPen(Qt.NoPen)
        painter.setBrush(QColor("white"))
        painter.drawEllipse(QRectF(x, y, d, d))
        painter.setBrush(QColor(WARM))
        path = QPainterPath()
        path.moveTo(x + 7, y + 5)
        path.lineTo(x + 13, y + 9)
        path.lineTo(x + 7, y + 13)
        path.closeSubpath()
        painter.drawPath(path)


class QrDialog(QDialog):
    def __init__(self, modules, code, finger, parent):
        super().__init__(parent)
        self.modules = modules
        self.setWindowTitle("配對 QR")
        self.setModal(False)
        self.setFixedSize(380, 460)
        self.setStyleSheet(f"background:{PAPER};")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        self.canvas = QWidget()
        self.canvas.setStyleSheet("background:white;")
        self.canvas.paintEvent = self._paint
        hint = QLabel(f"用手機相機掃描，會開啟 Cam Link\n配對碼 {code}    指紋 {finger}")
        hint.setAlignment(Qt.AlignCenter)
        hint.setFont(font(9))
        hint.setStyleSheet(f"color:{GRAY}; background:{PAPER}; padding:8px;")
        hint.setFixedHeight(56)
        layout.addWidget(self.canvas, 1)
        layout.addWidget(hint)
        center = parent.frameGeometry().center() if parent else QGuiApplication.primaryScreen().availableGeometry().center()
        self.move(center.x() - self.width() // 2, center.y() - self.height() // 2)

    def _paint(self, _event):
        painter = QPainter(self.canvas)
        painter.setRenderHint(QPainter.Antialiasing, False)
        painter.fillRect(self.canvas.rect(), QColor("white"))
        box = self.canvas.rect().adjusted(24, 24, -24, -24)
        modules = self.modules
        n = len(modules)
        quiet = 4
        span = n + quiet * 2
        cell = max(1, min(box.width(), box.height()) // span)
        x0 = box.x() + (box.width() - cell * span) // 2
        y0 = box.y() + (box.height() - cell * span) // 2
        painter.setPen(Qt.NoPen)
        painter.setBrush(QColor("black"))
        for r, row in enumerate(modules):
            for c, on in enumerate(row):
                if on:
                    painter.drawRect(x0 + (c + quiet) * cell, y0 + (r + quiet) * cell, cell, cell)


class Window(QWidget):
    arrived = Signal(object)

    def __init__(self):
        super().__init__()
        self.setObjectName("window")
        self.setWindowTitle("Cam Link")
        self.resize(1240, 820)
        self.setMinimumSize(1080, 780)
        icon = icon_file()
        if icon.exists():
            self.setWindowIcon(QIcon(str(icon)))
        self.receiver = None
        self.modules = None
        self.pair_host = self.pair_code = self.pair_print = ""
        self.pair_visible = False
        self.rows = {}
        self.got_count = 0
        self.busy_count = 0
        self.verified_bytes = 0
        self.session_start = time.monotonic()
        self.shown = ""
        self.qr_window = None
        self.notified_first = False
        self.tray = QSystemTrayIcon(self.windowIcon() if not self.windowIcon().isNull() else QIcon(str(logo_file())), self)
        self.tray.setToolTip("Cam Link Receiver")
        self.tray.setVisible(True)
        self.arrived.connect(self._on_live)
        self._build()
        self._apply_pair()
        if auto_start_on() and self.ips.count() > 0:
            QTimer.singleShot(500, self._auto_start)

    def _build(self):
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        root.addWidget(self._header())
        stage = QHBoxLayout()
        stage.setContentsMargins(24, 8, 24, 16)
        stage.setSpacing(16)
        stage.addLayout(self._left(), 7)
        stage.addLayout(self._right(), 3)
        root.addLayout(stage, 1)

    def _header(self):
        head = QWidget()
        head.setFixedHeight(68)
        row = QHBoxLayout(head)
        row.setContentsMargins(28, 14, 28, 10)
        row.setSpacing(12)
        mark = QLabel()
        mark.setFixedSize(40, 40)
        pix = self._logo()
        if not pix.isNull():
            mark.setPixmap(pix)
        title = QLabel("Cam Link")
        title.setFont(font(18, True))
        version = QLabel("電腦收相    " + VERSION)
        version.setFont(font(9))
        version.setStyleSheet(f"color:{GRAY};")
        version.setContentsMargins(0, 8, 0, 0)
        row.addWidget(mark, 0, Qt.AlignVCenter)
        row.addWidget(title, 0, Qt.AlignVCenter)
        row.addWidget(version, 0, Qt.AlignVCenter)
        row.addStretch(1)
        return head

    def _logo(self):
        source = QPixmap(str(logo_file()))
        if source.isNull():
            return source
        screen = QGuiApplication.primaryScreen()
        dpr = screen.devicePixelRatio() if screen else 1
        pixels = max(1, int(round(40 * dpr)))
        scaled = source.scaled(pixels, pixels, Qt.KeepAspectRatio, Qt.SmoothTransformation)
        scaled.setDevicePixelRatio(dpr)
        return scaled

    def _left(self):
        column = QVBoxLayout()
        column.setSpacing(12)
        self.photo = PhotoWell()
        column.addWidget(self.photo, 7)
        files = QFrame()
        files.setObjectName("files")
        shadow(files, 22, 4, 18)
        body = QVBoxLayout(files)
        body.setContentsMargins(16, 10, 16, 12)
        body.setSpacing(0)
        title_row = QHBoxLayout()
        heading = QLabel("本輪檔案")
        heading.setFont(font(10, True))
        self.file_count = QLabel("共 0 個檔案")
        self.file_count.setFont(font(9))
        self.file_count.setStyleSheet(f"color:{GRAY};")
        title_row.addWidget(heading)
        title_row.addStretch(1)
        title_row.addWidget(self.file_count)
        body.addLayout(title_row)
        self.table = QTableWidget(0, 5)
        self.table.setHorizontalHeaderLabels(["時間", "檔名", "大小", "速度", "狀態"])
        self.table.verticalHeader().setVisible(False)
        self.table.setShowGrid(False)
        self.table.setEditTriggers(QTableWidget.NoEditTriggers)
        self.table.setSelectionBehavior(QTableWidget.SelectRows)
        self.table.setFocusPolicy(Qt.NoFocus)
        self.table.setFont(font(9))
        header = self.table.horizontalHeader()
        header.setFont(font(9))
        header.setStretchLastSection(False)
        header.setSectionResizeMode(1, header.ResizeMode.Stretch)
        for index, width in enumerate((72, 160, 110, 88, 72)):
            if index != 1:
                self.table.setColumnWidth(index, width)
        self.table.verticalHeader().setDefaultSectionSize(28)
        self.table.itemSelectionChanged.connect(self._pick_row)
        self.empty = QLabel("尚無傳輸紀錄")
        self.empty.setAlignment(Qt.AlignCenter)
        self.empty.setFont(font(10))
        self.empty.setStyleSheet(f"color:{GRAY};")
        body.addWidget(self.table, 1)
        body.addWidget(self.empty, 1)
        self.table.hide()
        column.addWidget(files, 3)
        return column

    def _right(self):
        column = QVBoxLayout()
        column.setSpacing(0)
        column.addWidget(self._card())
        column.addSpacing(16)
        column.addWidget(self._setup())
        column.addStretch(1)
        self.run = StartButton("開始接收")
        self.run.setObjectName("start")
        self.run.setFont(font(11, True))
        self.run.setCursor(Qt.PointingHandCursor)
        self.run.setProperty("running", False)
        self.run.clicked.connect(self._toggle)
        host = QWidget()
        host_layout = QVBoxLayout(host)
        host_layout.setContentsMargins(0, 16, 0, 0)
        host_layout.addWidget(self.run)
        column.addWidget(host)
        return column

    def _card(self):
        card = QFrame()
        card.setObjectName("card")
        shadow(card)
        body = QVBoxLayout(card)
        body.setContentsMargins(16, 14, 16, 14)
        body.setSpacing(8)
        kicker = QHBoxLayout()
        section = QLabel("連線狀態")
        section.setObjectName("section")
        section.setFont(font(9))
        self.state = QLabel("")
        self.state.setFont(font(9))
        self.state.setStyleSheet(f"color:{GRAY};")
        self.state.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        kicker.addWidget(section)
        kicker.addStretch(1)
        kicker.addWidget(self.state)
        body.addLayout(kicker)
        metrics = QHBoxLayout()
        metrics.setSpacing(8)
        self.received = self._metric("0", "已核對")
        self.active = self._metric("0", "傳輸中")
        self.verified = self._metric("0.0", "MB")
        metrics.addWidget(self.received[0])
        metrics.addWidget(self.active[0])
        metrics.addWidget(self.verified[0])
        body.addLayout(metrics)
        self.meter = self._meter()
        body.addWidget(self.meter)
        self.current = QLabel("")
        self.current.setFont(font(9))
        self.speed = QLabel("")
        self.speed.setFont(font(9))
        self.speed.setStyleSheet(f"color:{GRAY};")
        body.addWidget(self.current)
        body.addWidget(self.speed)
        self.address = self._fact(body, "手機地址", "開始接收後顯示")
        self.code = self._fact(body, "配對碼", "—")
        self.finger = self._fact(body, "指紋", "與手機畫面上的 16 位比對")
        for label in (self.address, self.code, self.finger):
            label.mouseReleaseEvent = lambda event, source=label: self._click_pair(event, source)
        self.qr = QPushButton("顯示 QR 掃描")
        self.qr.setObjectName("qr")
        self.qr.setFont(font(10))
        self.qr.setCursor(Qt.PointingHandCursor)
        self.qr.clicked.connect(self._open_qr)
        body.addWidget(self.qr)
        return card

    def _metric(self, value, caption):
        tile = QFrame()
        tile.setObjectName("tile")
        layout = QVBoxLayout(tile)
        layout.setContentsMargins(4, 8, 4, 6)
        layout.setSpacing(0)
        number = QLabel(value)
        number.setAlignment(Qt.AlignCenter)
        number.setFont(font(18, True))
        label = QLabel(caption)
        label.setAlignment(Qt.AlignCenter)
        label.setFont(font(9))
        label.setStyleSheet(f"color:{GRAY};")
        layout.addWidget(number)
        layout.addWidget(label)
        return tile, number

    def _meter(self):
        from PySide6.QtWidgets import QProgressBar

        bar = QProgressBar()
        bar.setRange(0, 100)
        bar.setValue(0)
        bar.setTextVisible(False)
        bar.setFixedHeight(4)
        return bar

    def _fact(self, body, caption, value):
        row = QHBoxLayout()
        cap = QLabel(caption)
        cap.setFont(font(9))
        cap.setStyleSheet(f"color:{GRAY};")
        cap.setFixedWidth(72)
        shown = QLabel(value)
        shown.setFont(font(9))
        shown.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        row.addWidget(cap)
        row.addWidget(shown, 1)
        body.addLayout(row)
        return shown

    def _setup(self):
        setup = QFrame()
        setup.setObjectName("setup")
        shadow(setup, 22, 4, 18)
        body = QVBoxLayout(setup)
        body.setContentsMargins(16, 14, 16, 14)
        body.setSpacing(6)
        net = QLabel("這部電腦的網絡")
        net.setFont(font(9))
        net.setStyleSheet(f"color:{GRAY};")
        self.ips = QComboBox()
        self.ips.setFont(font(10))
        remembered = remembered_ip()
        for ip in ipv4s():
            self.ips.addItem(ip)
        if remembered:
            index = self.ips.findText(remembered)
            if index >= 0:
                self.ips.setCurrentIndex(index)
        folder_head = QHBoxLayout()
        folder_label = QLabel("JPG 儲存資料夾")
        folder_label.setFont(font(9))
        folder_label.setStyleSheet(f"color:{GRAY};")
        self.open_folder = QPushButton("開啟資料夾")
        self.open_folder.setObjectName("open")
        self.open_folder.setFont(font(9))
        self.open_folder.setCursor(Qt.PointingHandCursor)
        self.open_folder.clicked.connect(self._open_folder)
        folder_head.addWidget(folder_label)
        folder_head.addStretch(1)
        folder_head.addWidget(self.open_folder)
        path_row = QHBoxLayout()
        path_row.setSpacing(8)
        self.folder = QLineEdit(remembered_folder())
        self.folder.setFont(font(10))
        self.browse = QPushButton("選擇")
        self.browse.setObjectName("choose")
        self.browse.setFont(font(10))
        self.browse.setCursor(Qt.PointingHandCursor)
        self.browse.clicked.connect(self._browse)
        path_row.addWidget(self.folder, 1)
        path_row.addWidget(self.browse)
        self.auto_start = QCheckBox("開啟程式後自動開始接收")
        self.auto_start.setFont(font(9))
        self.auto_start.setChecked(auto_start_on())
        self.auto_start.toggled.connect(lambda on: write_setting("auto_start.txt", "1" if on else "0"))
        self.rescan = QPushButton("補核對資料夾內 JPG")
        self.rescan.setObjectName("choose")
        self.rescan.setFont(font(9))
        self.rescan.setCursor(Qt.PointingHandCursor)
        self.rescan.clicked.connect(self._rescan)
        body.addWidget(net)
        body.addWidget(self.ips)
        body.addSpacing(6)
        body.addLayout(folder_head)
        body.addLayout(path_row)
        body.addWidget(self.auto_start)
        body.addWidget(self.rescan)
        return setup

    def _click_pair(self, event, source):
        if event.button() == Qt.LeftButton:
            self._reveal()
        QLabel.mouseReleaseEvent(source, event)

    def _toggle(self):
        if self.receiver is not None:
            self._stop()
            return
        try:
            ip = self.ips.currentText().strip()
            folder = self.folder.text().strip()
            if not ip or not folder:
                raise OSError("請選擇本機網絡及收相資料夾")
            write_setting("folder.txt", folder)
            write_setting("ip.txt", ip)
            self.rows.clear()
            self.table.setRowCount(0)
            self.got_count = self.busy_count = 0
            self.verified_bytes = 0
            self.session_start = time.monotonic()
            self.shown = ""
            self.notified_first = False
            self.photo.clear_photo()
            self._show_latest()
            self._set_count()
            self.receiver = Receiver(ip, folder, str(settings_dir()), lambda _text: None, lambda item: self.arrived.emit(item))
            self._show_pair(ip + ":9443", self.receiver.password, self.receiver.fingerprint[:16].upper(), "camlink://pair?ip=" + ip + "&code=" + self.receiver.password)
            self.state.setText("可以接收")
            self.current.setText("等待手機傳來的 JPG")
            self.speed.setText("按「顯示 QR」配對，指紋必須相同")
            self.meter.setValue(0)
            self.run.setText("停止接收")
            self.run.setProperty("running", True)
            self._polish(self.run)
            self.ips.setEnabled(False)
            self.folder.setEnabled(False)
            self.browse.setEnabled(False)
            self.auto_start.setEnabled(False)
        except Exception as exc:
            if self.receiver is not None:
                self.receiver.close()
                self.receiver = None
            QMessageBox.warning(self, "無法啟動", str(exc))

    def _on_live(self, transfer):
        row = self.rows.get(transfer["id"])
        if row is None:
            self.table.insertRow(0)
            values = [datetime.now().strftime("%H:%M:%S"), transfer["name"], "", "", "接收中"]
            row = []
            for column, text in enumerate(values):
                item = QTableWidgetItem(text)
                item.setFlags(Qt.ItemIsEnabled | Qt.ItemIsSelectable)
                item.setFont(font(9))
                self.table.setItem(0, column, item)
                row.append(item)
            self.rows[transfer["id"]] = row
            self.busy_count += 1
            self.table.show()
            self.empty.hide()
        row[2].setText(amount(transfer["got"]) + " / " + amount(transfer["size"]))
        row[3].setText(f"{transfer['rate']:.1f} MB/s")
        row[4].setText(transfer["note"])
        if transfer["finished"] and row[0].data(Qt.UserRole) != "done":
            row[0].setData(Qt.UserRole, "done")
            self.busy_count = max(0, self.busy_count - 1)
            if transfer["ok"]:
                self.got_count += 1
                self.verified_bytes += transfer["size"]
                self._show_photo(os.path.join(self.folder.text().strip(), transfer["name"]), transfer["name"])
                if not self.notified_first:
                    self.notified_first = True
                    self._notify("第一張已核對", transfer["name"])
            elif transfer["finished"]:
                self._notify("需處理", transfer["name"] + " 未核對")
        span = max(0.05, time.monotonic() - self.session_start)
        self.state.setText("正在接收" if self.busy_count else "剛核對一張" if self.got_count else "可以接收")
        self.current.setText(transfer["name"])
        self.speed.setText(
            amount(transfer["got"]) + " / " + amount(transfer["size"]) + "    " + f"{transfer['rate']:.1f} MB/s    全程 {self.verified_bytes / 1048576.0 / span:.1f} MB/s"
        )
        self.meter.setValue(0 if transfer["size"] <= 0 else int(min(100, transfer["got"] / transfer["size"] * 100)))
        self._set_count()
        if transfer["finished"] and self.busy_count == 0 and self.got_count > 0:
            self._notify("本輪傳完", f"已核對 {self.got_count} 張")

    def _auto_start(self):
        if self.receiver is None and auto_start_on():
            self._toggle()

    def _notify(self, title, text):
        if self.tray.isSystemTrayAvailable():
            self.tray.showMessage(title, text, QSystemTrayIcon.Information, 4000)

    def _pick_row(self):
        rows = self.table.selectionModel().selectedRows()
        if not rows:
            return
        item = self.table.item(rows[0].row(), 1)
        if item is None:
            return
        name = item.text()
        path = os.path.join(self.folder.text().strip(), name)
        if os.path.isfile(path):
            self._show_photo(path, name)

    def _rescan(self):
        folder = self.folder.text().strip()
        if not folder or not os.path.isdir(folder):
            QMessageBox.information(self, "補核對", "請先選擇收相資料夾。")
            return
        found = []
        for name in os.listdir(folder):
            if not FILENAME.fullmatch(name):
                continue
            path = os.path.join(folder, name)
            if not os.path.isfile(path):
                continue
            try:
                size = os.path.getsize(path)
                stamp = os.path.getmtime(path)
            except OSError:
                continue
            found.append((stamp, name, size, path))
        found.sort(reverse=True)
        if not found:
            QMessageBox.information(self, "補核對", "資料夾沒有 JPG。")
            return
        known = {self.table.item(row, 1).text() for row in range(self.table.rowCount()) if self.table.item(row, 1)}
        added = 0
        for stamp, name, size, path in found:
            if name in known:
                for row in range(self.table.rowCount()):
                    cell = self.table.item(row, 1)
                    if cell and cell.text() == name:
                        self.table.item(row, 4).setText("已核對")
                        break
                continue
            self.table.insertRow(0)
            values = [datetime.fromtimestamp(stamp).strftime("%H:%M:%S"), name, amount(size) + " / " + amount(size), "—", "已核對"]
            for column, text in enumerate(values):
                item = QTableWidgetItem(text)
                item.setFlags(Qt.ItemIsEnabled | Qt.ItemIsSelectable)
                item.setFont(font(9))
                if column == 0:
                    item.setData(Qt.UserRole, "done")
                self.table.setItem(0, column, item)
            self.got_count += 1
            self.verified_bytes += size
            added += 1
            known.add(name)
        self.table.show()
        self.empty.hide()
        self._set_count()
        newest = found[0]
        self._show_photo(newest[3], newest[1])
        self.state.setText("剛核對一張" if self.got_count else "可以接收")
        self.current.setText(newest[1])
        self.speed.setText(f"已補核對資料夾內 {len(found)} 張" + (f"，新增 {added} 筆" if added else ""))
        self._notify("補核對完成", f"資料夾內 {len(found)} 張 JPG")

    def _show_photo(self, path, name):
        if path == self.shown:
            return
        self.shown = path
        self.photo.show_photo(path, name)

    def _show_latest(self):
        folder = self.folder.text().strip()
        if not folder or not os.path.isdir(folder):
            return
        newest = None
        newest_time = -1
        try:
            names = os.listdir(folder)
        except OSError:
            return
        for name in names:
            if not FILENAME.fullmatch(name):
                continue
            path = os.path.join(folder, name)
            try:
                stamp = os.path.getmtime(path)
            except OSError:
                continue
            if stamp >= newest_time:
                newest_time = stamp
                newest = (path, name)
        if newest:
            self._show_photo(newest[0], newest[1])

    def _set_count(self):
        self.received[1].setText(str(self.got_count))
        self.active[1].setText(str(self.busy_count))
        self.verified[1].setText(f"{self.verified_bytes / 1048576.0:.1f}")
        count = self.table.rowCount()
        self.file_count.setText(f"共 {count} 個檔案")
        self.table.setVisible(count > 0)
        self.empty.setVisible(count == 0)

    def _show_pair(self, host, pairing, print_text, payload):
        self.pair_host, self.pair_code, self.pair_print = host, pairing, print_text
        if not payload:
            self.pair_visible = False
        self.modules = qr_modules(payload) if payload else None
        self._apply_pair()
        if self.qr_window is not None:
            self.qr_window.close()
            self.qr_window = None

    def _reveal(self):
        if self.modules is None:
            return
        self.pair_visible = not self.pair_visible
        self._apply_pair()

    def _apply_pair(self):
        live = self.modules is not None
        show = (not live) or self.pair_visible
        values = (
            (self.address, self.pair_host or "開始接收後顯示", font(12, True), font(9)),
            (self.code, self.pair_code or "—", font(16, True, "Consolas"), font(9)),
            (self.finger, self.pair_print or "與手機畫面上的 16 位比對", font(12, False, "Consolas"), font(9)),
        )
        for label, text, live_font, quiet_font in values:
            label.setText(text if show else "點擊顯示")
            label.setStyleSheet(f"color:{INK if show else GRAY};")
            label.setFont(live_font if show and live else quiet_font)
            label.setCursor(Qt.PointingHandCursor if live else Qt.ArrowCursor)

    def _open_qr(self):
        if self.modules is None:
            QMessageBox.information(self, "配對 QR", "請先按「開始接收」。")
            return
        if self.qr_window is not None and self.qr_window.isVisible():
            self.qr_window.activateWindow()
            return
        self.qr_window = QrDialog(self.modules, self.pair_code, self.pair_print, self)
        self.qr_window.show()

    def _browse(self):
        path = QFileDialog.getExistingDirectory(self, "選擇儲存 Cam Link 原圖的資料夾", self.folder.text())
        if path:
            self.folder.setText(path)

    def _open_folder(self):
        try:
            path = self.folder.text().strip()
            if not path:
                raise OSError("請先選擇收相資料夾")
            os.makedirs(path, exist_ok=True)
            os.startfile(path)
        except Exception as exc:
            QMessageBox.warning(self, "無法開啟資料夾", str(exc))

    def _stop(self):
        if self.qr_window is not None:
            self.qr_window.close()
            self.qr_window = None
        if self.receiver is not None:
            self.receiver.close()
            self.receiver = None
        self.run.setText("開始接收")
        self.run.setProperty("running", False)
        self._polish(self.run)
        self.ips.setEnabled(True)
        self.folder.setEnabled(True)
        self.browse.setEnabled(True)
        self.auto_start.setEnabled(True)
        self._show_pair("開始接收後顯示", "—", "與手機畫面上的 16 位比對", None)
        self.state.setText("接收已停止" if self.got_count else "")
        self.current.setText("已停止。已核對的 JPG 留在資料夾。" if self.got_count else "照片會出現在左邊")
        self.speed.setText("")
        self.meter.setValue(0)
        if self.got_count > 0:
            self._notify("接收已停止", f"已核對 {self.got_count} 張")

    def _polish(self, widget):
        widget.style().unpolish(widget)
        widget.style().polish(widget)
        widget.update()

    def closeEvent(self, event):
        self._stop()
        super().closeEvent(event)


def gui():
    QGuiApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    app = QApplication([])
    app.setStyle("Fusion")
    app.setFont(font(10))
    app.setStyleSheet(QSS)
    window = Window()
    window.show()
    return app.exec()


def self_test():
    import sys
    import tempfile as _temp

    root = Path(_temp.mkdtemp(prefix="camlink-self-"))
    server = Receiver("127.0.0.1", str(root / "inbox"), str(root / "profile"), lambda _text: None)
    try:
        body = b"fixture-original"
        digest = hashlib.sha256(body).hexdigest()
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE

        def put(payload, sha, password, expect):
            sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
            tls = context.wrap_socket(sock, server_hostname="camlink")
            header = (
                "PUT /inbox/photo.JPG HTTP/1.1\r\n"
                f"Content-Length: {len(payload)}\r\n"
                f"X-CamLink-SHA256: {sha}\r\n"
                "Authorization: Basic " + base64.b64encode(b"camlink:" + password.encode()).decode("ascii") + "\r\n"
                "Connection: close\r\n\r\n"
            )
            tls.write(header.encode("ascii") + payload)
            status = tls.recv(128).decode("ascii", "replace")
            tls.close()
            code = int(status.split(" ", 2)[1])
            if code != expect:
                raise SystemExit(f"status {code} want {expect}")

        put(body, digest, "wrong", 401)
        put(body, digest, server.password, 201)
        put(body, digest, server.password, 201)
        put(b"different", digest, server.password, 422)
        put(b"new", hashlib.sha256(b"new").hexdigest(), server.password, 409)
        stored = (root / "inbox" / "photo.JPG").read_bytes()
        if stored != body:
            raise SystemExit("original changed")
        modules = qr_modules("camlink://pair?ip=192.168.1.20&code=ab12cd34ef56")
        if len(modules) != 33 or not modules[0][0] or modules[1][1] or not modules[2][2]:
            raise SystemExit("qr mismatch")
        if sys.stdout is not None:
            print("PASS")
        return 0
    finally:
        server.close()
        sys.stdout.flush()


def main(argv):
    if len(argv) >= 1 and argv[0] == "--qr":
        payload = argv[1] if len(argv) >= 2 else "camlink://pair?ip=192.168.50.86&code=4c07d5bc1cc8"
        path = argv[2] if len(argv) >= 3 else str(Path(tempfile.gettempdir()) / "camlink-pair-qr.png")
        save_qr(payload, path)
        return 0
    if len(argv) == 3 and argv[0] == "--fixture":
        return fixture(argv[1], argv[2])
    if len(argv) == 1 and argv[0] == "--self-test":
        return self_test()
    return gui()


if __name__ == "__main__":
    import sys

    raise SystemExit(main(sys.argv[1:]))
