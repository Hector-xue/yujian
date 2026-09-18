#!/usr/bin/env python3
"""桌面小部件的预览图（添加小部件面板里显示的那张）。照着 res/layout/widget_*.xml 画，改布局记得重跑。
用法：python3 scripts/gen_widget_previews.py   → res/drawable-nodpi/widget_preview_*.png
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'apps/yujian/android/app/src/main/res/drawable-nodpi'
FONT_DIR = '/usr/share/fonts/google-noto-cjk'
S = 2  # dp → px

BLUE = (0x1B, 0x6B, 0xC7)
GREEN = (0x2E, 0x9A, 0x5C)
INK = (0x1C, 0x24, 0x30)
MUTED = (0x6C, 0x75, 0x80)
WHITE = (255, 255, 255)


def font(size_sp, bold=False):
    f = f'{FONT_DIR}/NotoSansCJK-{"Bold" if bold else "Regular"}.ttc'
    return ImageFont.truetype(f, int(size_sp * S), index=2)  # index 2 = SC


def card(w_dp, h_dp, radius=22, gradient=None):
    w, h = w_dp * S, h_dp * S
    img = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if gradient:
        base = Image.new('RGBA', (w, h), (0, 0, 0, 0))
        g = ImageDraw.Draw(base)
        for x in range(w):
            t = x / max(1, w - 1)
            c = tuple(int(gradient[0][i] * (1 - t) + gradient[1][i] * t) for i in range(3))
            g.line([(x, 0), (x, h)], fill=c + (255,))
        mask = Image.new('L', (w, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=radius * S, fill=255)
        img.paste(base, (0, 0), mask)
    else:
        d.rounded_rectangle([0, 0, w - 1, h - 1], radius=radius * S, fill=(255, 255, 255, 242), outline=(0, 0, 0, 51), width=1)
    return img, ImageDraw.Draw(img)


def button(d, x, y, w, h, text, size=13):
    d.rounded_rectangle([x, y, x + w, y + h], radius=14 * S, fill=BLUE)
    f = font(size, True)
    tw = d.textlength(text, font=f)
    d.text((x + (w - tw) / 2, y + (h - f.size) / 2 - 2 * S), text, font=f, fill=WHITE)


def summary():
    img, d = card(280, 140)
    p = 18 * S
    d.text((p, 14 * S), '余额', font=font(12, True), fill=BLUE)
    f = font(12)
    d.text((280 * S - p - d.textlength('9 月', font=f), 14 * S), '9 月', font=f, fill=MUTED)
    d.text((p, 30 * S), '¥ 12,480.50', font=font(30, True), fill=BLUE)
    y = 78 * S
    d.text((p, y), '支出', font=font(11), fill=MUTED)
    d.text((p, y + 15 * S), '¥ 3,832', font=font(15, True), fill=INK)
    d.text((p + 78 * S, y), '收入', font=font(11), fill=MUTED)
    d.text((p + 78 * S, y + 15 * S), '¥ 8,000', font=font(15, True), fill=GREEN)
    button(d, 280 * S - p - 88 * S, y + 2 * S, 88 * S, 34 * S, '＋ 记一笔')
    d.text((p, 118 * S), '最近：美团外卖 −¥13.80 · 9/17', font=font(12), fill=MUTED)
    return img


def large():
    img, d = card(140, 140)
    p = 16 * S
    d.text((p, 14 * S), '今日支出', font=font(12, True), fill=BLUE)
    f = font(11)
    d.text((140 * S - p - d.textlength('9 月', font=f), 15 * S), '9 月', font=f, fill=MUTED)
    d.text((p, 30 * S), '¥ 22.80', font=font(26, True), fill=INK)
    d.text((p, 66 * S), '本月支出 ¥ 3,832.90', font=font(11), fill=MUTED)
    d.text((p, 82 * S), '余额 ¥ 12,480.50', font=font(11), fill=BLUE)
    button(d, p, 102 * S, 140 * S - 2 * p, 30 * S, '＋ 记一笔')
    return img


def compact():
    img, d = card(140, 70)
    p = 16 * S
    d.text((p, 10 * S), '余额', font=font(11, True), fill=BLUE)
    d.text((p, 25 * S), '¥ 9,480', font=font(18, True), fill=BLUE)
    d.text((p, 50 * S), '本月支出 ¥ 3,832', font=font(11), fill=MUTED)
    button(d, 140 * S - 12 * S - 40 * S, 20 * S, 40 * S, 30 * S, '＋记', size=12)
    return img


def mini():
    img, d = card(70, 70, gradient=(BLUE, GREEN))
    f = font(30, True)
    d.text(((70 * S - d.textlength('＋', font=f)) / 2, 6 * S), '＋', font=f, fill=WHITE)
    f2 = font(12, True)
    d.text(((70 * S - d.textlength('记一笔', font=f2)) / 2, 46 * S), '记一笔', font=f2, fill=WHITE)
    return img


RED = (0xD9, 0x53, 0x4F)
GREY = (0x9A, 0xA3, 0xAD)


def calendar():
    """4x4 日历：照 widget_calendar.xml + 代码铺的格子画（2026 年 9 月，周日开头）。"""
    W = 280
    img, d = card(W, W)
    p = 12 * S
    d.text((p + 4 * S, 12 * S), '9 月', font=font(15, True), fill=BLUE)
    d.text((p + 50 * S, 12 * S), '支出 ¥ 3,832.90', font=font(10), fill=MUTED)
    d.text((p + 50 * S, 25 * S), '收入 ¥ 8,000.00', font=font(10), fill=GREEN)
    button(d, W * S - p - 76 * S, 12 * S, 76 * S, 26 * S, '＋ 记一笔', size=12)
    top = 48 * S
    colw = (W * S - 2 * p) / 7
    f9 = font(9)
    for i, w in enumerate('日一二三四五六'):
        tw = d.textlength(w, font=f9)
        d.text((p + colw * i + (colw - tw) / 2, top), w, font=f9, fill=GREY)
    grid_top = top + 16 * S
    grid_h = W * S - 10 * S - grid_top
    leading, days, today = 2, 30, 18  # 2026-09-01 是周二
    rows = (leading + days + 6) // 7
    rowh = grid_h / rows
    exp = {1: 2000, 2: 3350, 3: 9000, 5: 6800, 8: 14000, 9: 1200, 11: 5000, 12: 3000, 15: 15000, 16: 1000, 17: 1380, 18: 2280, 22: 24000}
    inc = {5: 800000, 12: 500, 17: 9000}
    def short(minor):
        yuan = minor / 100
        if yuan >= 10000: return f'{yuan / 10000:.1f}w'
        if yuan >= 100: return f'{yuan:.0f}'
        return f'{yuan:.0f}' if yuan == int(yuan) else f'{yuan:.1f}'
    fd, fa = font(11), font(8, True)
    for r in range(rows):
        for c in range(7):
            n = r * 7 + c - leading + 1
            if n < 1 or n > days: continue
            x0, y0 = p + colw * c + 1 * S, grid_top + rowh * r + 1 * S
            x1, y1 = p + colw * (c + 1) - 1 * S, grid_top + rowh * (r + 1) - 1 * S
            e, i_ = exp.get(n, 0), inc.get(n, 0)
            # 和 CalendarWidget 同一规则：有账按净值上色（粉红 / 浅绿），今天加蓝框
            fill = None if not (e or i_) else ((0xE4, 0xF5, 0xEA, 255) if i_ >= e else (0xFF, 0xED, 0xEA, 255))
            if n == today:
                d.rounded_rectangle([x0, y0, x1, y1], radius=8 * S, fill=fill or (0xE8, 0xF0, 0xFB, 255), outline=BLUE, width=int(1.2 * S))
            elif fill:
                d.rounded_rectangle([x0, y0, x1, y1], radius=8 * S, fill=fill)
            lines = [('今' if n == today else str(n), fd, BLUE if n == today else INK)]
            if e: lines.append(('-' + short(e), fa, RED))
            if i_: lines.append(('+' + short(i_), fa, GREEN))
            th = sum(f.size for _, f, _ in lines) + (len(lines) - 1) * 1 * S
            y = y0 + ((y1 - y0) - th) / 2
            for text, f, col in lines:
                tw = d.textlength(text, font=f)
                d.text(((x0 + x1 - tw) / 2, y - 1 * S), text, font=f, fill=col)
                y += f.size + 1 * S
    return img


if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    for name, fn in [('summary', summary), ('large', large), ('compact', compact), ('mini', mini), ('calendar', calendar)]:
        fn().save(OUT / f'widget_preview_{name}.png')
        print('wrote', name)
