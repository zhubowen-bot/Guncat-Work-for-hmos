# 检查 PowerShell 重写后 WorkToolRunner.ets 的编码完整性(红线: PowerShell 可能引入 BOM/GBK 乱码)
import os

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                    '..', 'entry', 'src', 'main', 'ets', 'service', 'WorkToolRunner.ets')
data = open(path, 'rb').read()
lines = []
lines.append('BOM: ' + str(data[:3] == b'\xef\xbb\xbf'))
try:
    t = data.decode('utf-8')
    lines.append('UTF-8 decode: OK')
    lines.append('imageResolver(context, root) count: ' + str(t.count('imageResolver(context, root)')))
    ok = ('生成演示文稿失败' in t) and ('非法路径' in t) and ('SVG 解码失败' in t)
    lines.append('zh strings intact: ' + str(ok))
    lines.append('GBK mojibake present: ' + str('锟斤拷' in t or 'æ' in t))
except UnicodeDecodeError as e:
    lines.append('UTF-8 decode: FAIL ' + str(e))
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), '_check.txt')
open(out, 'w', encoding='utf-8').write('\n'.join(lines))
