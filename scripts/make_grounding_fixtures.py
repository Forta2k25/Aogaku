#!/usr/bin/env python3
"""grounding_eval.cjs --suite 用の合成画像を作る(macOS のフォント前提)。実物の写真ではないが、失敗の型(創作・抽象化・盲信・見切れ・遠距離・図と文の矛盾)を再現する。
  python3 scripts/make_grounding_fixtures.py <出力フォルダ>
"""
import sys, os, random
from PIL import Image, ImageDraw, ImageFont, ImageFilter
out = sys.argv[1] if len(sys.argv) > 1 else "grounding-fixtures"
os.makedirs(out, exist_ok=True)
JP = "/System/Library/Fonts/Hiragino Sans GB.ttc"
UNI = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
def font(path, n): return ImageFont.truetype(path, n)
def paper(size=(1000, 1100)): return Image.new("RGB", size, (250, 248, 240))
def save(im, name, rot=0):
    if rot: im = im.rotate(rot, expand=True, fillcolor=(250, 248, 240))
    im.save(os.path.join(out, name), quality=85)

def worksheet(draw_q3=False):
    im = paper(); d = ImageDraw.Draw(im); y = 60
    for t, n in [("課題12 無意識の文法 日本語との比較", 36), ("", 20),
                 ("問1 次のA・Bのうち、日本語として自然な文はどちらか。", 28),
                 ("A. 我が社はこのたび、佐藤氏を営業部長として採用する。", 26),
                 ("B. 鈴木氏はこの春から、代官山を拠点として活動する。", 26), ("", 20),
                 ("問2 次の例文のうち、日本語ではOKだが英語ではダメな", 28), ("文を選び、理由を述べなさい。", 28),
                 ("・この美しい街並み", 26), ("・私は昨日、友達に会った。", 26)]:
        d.text((60, y), t, font=font(JP, n), fill=(20, 20, 20)); y += n + 26
    if draw_q3:
        d.text((620, 300), "問3 次の文を英語にしなさい。", font=font(JP, 28), fill=(20, 20, 20))
        d.text((620, 360), "(1) 彼は先生であり、", font=font(JP, 26), fill=(20, 20, 20))
    return im
save(worksheet(), "t1_worksheet.jpg", rot=2)                       # 具体的な設問がある
c = worksheet(draw_q3=True); save(c.crop((0, 0, 760, c.size[1])), "t2_cut.jpg")   # 右側が見切れる(問3が途中)

def board(lines, size=(1100, 600), fontpath=UNI, fs=44, bg=(250, 248, 240), fg=(20, 20, 20)):
    im = Image.new("RGB", size, bg); d = ImageDraw.Draw(im); y = 40
    for t in lines: d.text((50, y), t, font=font(fontpath, fs), fill=fg); y += fs + 34
    return im
# 数式の誤りあり: 2f(3x-1) を y 軸で反射すると 2f(-3x-1) のはずだが、板書は 2f(-3x+1)
save(board(["f(x) = x³", "g(x) = 2f(3x − 1)", "reflect in the y-axis:", "h(x) = 2f(−3x + 1)"]), "t4_wrong_math.jpg", rot=-1)
# 正しい資料(過剰に疑わないことの確認)
save(board(["f(x) = x³", "g(x) = 2f(3x − 1)", "reflect in the y-axis:", "h(x) = 2f(−3x − 1)"]), "t5_correct_math.jpg", rot=-1)
# テーマは読めるが設問は読めない: 見出しは大きく、設問はぼかして判読不能に
im = paper(); d = ImageDraw.Draw(im)
d.text((60, 60), "課題7 経済学入門 需要と供給", font=font(JP, 44), fill=(20, 20, 20))
body = Image.new("RGB", (900, 600), (250, 248, 240)); bd = ImageDraw.Draw(body); y = 10
for t in ["問1 次の需要関数と供給関数から均衡価格を求めよ。", "  D: Q = 100 − 2P    S: Q = 20 + 2P", "問2 価格が25のとき、超過供給はいくらか。"]:
    bd.text((0, y), t, font=font(JP, 28), fill=(20, 20, 20)); y += 60
body = body.filter(ImageFilter.GaussianBlur(9)); im.paste(body, (60, 220)); save(im, "t6_theme_only.jpg")
# 遠距離の黒板: 小さい手書き風の文字、暗い背景、ノイズ・ぼかし
random.seed(1)
im = board(["g(x) = a f(bx − c) + d", "a : vertical stretch / reflection", "b : horizontal squeeze", "c : horizontal shift"],
           size=(1400, 900), fs=34, bg=(38, 62, 52), fg=(235, 235, 225))
px = im.load()
for _ in range(60000):
    x, y = random.randrange(im.size[0]), random.randrange(im.size[1]); v = random.randint(-25, 25); r, g, b = px[x, y]; px[x, y] = (max(0, min(255, r + v)),) * 3
im = im.filter(ImageFilter.GaussianBlur(1.1)).rotate(3, expand=True, fillcolor=(38, 62, 52)); save(im, "t7_far_board.jpg")
# 図・文・式の混在で、図と文が食い違う: 文は y = 2x、図の点 B は (3, 5)
im = paper((1100, 800)); d = ImageDraw.Draw(im)
d.text((50, 40), "Line L passes through the origin and A(1, 2).", font=font(UNI, 32), fill=(20, 20, 20))
d.text((50, 90), "Its equation is y = 2x, so at x = 3 we get y = 6.", font=font(UNI, 32), fill=(20, 20, 20))
ox, oy, k = 150, 700, 70
d.line((ox, oy, ox + 600, oy), fill=(0, 0, 0), width=3); d.line((ox, oy, ox, oy - 500), fill=(0, 0, 0), width=3)
for (px_, py_, label) in [(1, 2, "A(1, 2)"), (3, 5, "B(3, 5)")]:
    cx, cy = ox + px_ * k, oy - py_ * k; d.ellipse((cx - 6, cy - 6, cx + 6, cy + 6), fill=(200, 30, 30)); d.text((cx + 12, cy - 30), label, font=font(UNI, 28), fill=(200, 30, 30))
d.line((ox, oy, ox + 4 * k, oy - 8 * k), fill=(30, 30, 200), width=3)
save(im, "t8_mixed.jpg")
# 別記号で各項の説明漏れ・ラベル欠落と式欠落の混同を確認するdevelopment variation。
save(board(["y = p h(qx + r) + s", "p : vertical scale / reflection", "q : horizontal scale", "r : horizontal shift"], size=(1200, 680), fs=40, bg=(38, 62, 52), fg=(235, 235, 225)), "t9_parameters.jpg", rot=-2)
print("作成:", out, sorted(os.listdir(out)))
