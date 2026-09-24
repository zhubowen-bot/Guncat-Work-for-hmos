# 生成测试 PNG(无 PIL 依赖): 160x120 纯色, 输出 base64 到 stdout
import zlib, struct, base64, sys

def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)

def make_png(w, h, rgb):
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
    return base64.b64encode(png).decode()

if __name__ == '__main__':
    sys.stdout.write(make_png(160, 120, (26, 115, 232)))
