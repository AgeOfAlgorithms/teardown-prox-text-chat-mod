"""Add a hollow box glyph (U+2B1A, the buffer range's mystery letter) to Pangolin, which has none.
Pangolin is SIL OFL 1.1 with no Reserved Font Name, so a modified copy may keep its name; the
modification is noted in fonts/OFL.txt.

    python tools/add_box_glyph.py Pangolin-Regular.ttf "mods/proximity chat/fonts/pangolin.ttf"
(the input is the original from github.com/google/fonts ofl/pangolin; needs fontTools)"""
import sys
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen

CODE, NAME = 0x2B1A, 'uni2B1A'
X0, X1, Y0, Y1, STROKE, ADVANCE = 45, 525, 0, 600, 80, 580       # (x-height 555, caps 720)


def box_glyph():
    pen = TTGlyphPen(None)
    for pts in (((X0, Y0), (X0, Y1), (X1, Y1), (X1, Y0)),       # outer, clockwise
                ((X0 + STROKE, Y0 + STROKE), (X1 - STROKE, Y0 + STROKE), (X1 - STROKE, Y1 - STROKE), (X0 + STROKE, Y1 - STROKE))):
        pen.moveTo(pts[0])
        for p in pts[1:]:
            pen.lineTo(p)
        pen.closePath()
    return pen.glyph()


def main(src, dst):
    f = TTFont(src)
    if CODE in f.getBestCmap():
        raise SystemExit('the font already has U+%04X' % CODE)
    order = f.getGlyphOrder() + [NAME]
    f.setGlyphOrder(order)
    f['glyf'].glyphs[NAME] = box_glyph()
    f['glyf'].glyphOrder = order
    f['hmtx'].metrics[NAME] = (ADVANCE, X0)
    for t in f['cmap'].tables:
        if t.isUnicode():
            t.cmap[CODE] = NAME
    f.save(dst)
    print('added U+%04X to' % CODE, dst)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
