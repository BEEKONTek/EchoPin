"""Tiny slide toolkit: one layout spec, two renderers.

- PowerPoint (python-pptx) with entrance/emphasis animations, slide
  transitions (including Morph) and speaker notes.
- HTML mirror of each slide's final state, used only to check layout.

Units are inches on a 13.333 x 7.5 (16:9) slide.
"""

from __future__ import annotations

import html
from dataclasses import dataclass, field

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.oxml import parse_xml
from pptx.oxml.ns import qn
from pptx.util import Emu, Inches, Pt

W, H = 13.333, 7.5
FONT = "Arial"

# EchoPin palette (matches the app's dark theme)
BG, SURF, SURF2, LINE = "0E1016", "1A1D26", "242836", "323849"
ACCENT, BLUE, RED, AMBER = "8FA8FF", "2563EB", "EF4444", "F59E0B"
GREEN, TEAL, PURPLE = "22C55E", "2DD4BF", "A78BFA"
TEXT, MUTED = "F3F5F9", "A0A7B5"


# ── Layout spec ────────────────────────────────────────────────────────────

@dataclass
class Run:
    text: str
    size: float = 18
    color: str = TEXT
    bold: bool = False


@dataclass
class El:
    kind: str                     # rect | round | oval | text | image | arrow | group
    x: float = 0
    y: float = 0
    w: float = 1
    h: float = 1
    fill: str | None = None
    alpha: float = 1.0            # fill opacity
    line: str | None = None
    line_w: float = 1.5
    radius: float = 0.18          # rounded-rect corner, fraction of short side
    paras: list[list[Run]] = field(default_factory=list)
    align: str = "l"              # l | c | r
    anchor: str = "t"             # t | m | b
    pad: float = 0.0
    line_spacing: float = 1.0
    src: str | None = None
    children: list["El"] = field(default_factory=list)
    name: str | None = None
    rot: float = 0
    key: str | None = None        # handle for animations
    shape: object = None          # filled in by the pptx renderer


def text(x, y, w, h, *paras, align="l", anchor="t", key=None, spacing=1.0):
    """paras: each a Run, a list of Runs, or a str."""
    ps = []
    for p in paras:
        if isinstance(p, str):
            p = [Run(p)]
        elif isinstance(p, Run):
            p = [p]
        ps.append(p)
    return El("text", x, y, w, h, paras=ps, align=align, anchor=anchor, key=key, line_spacing=spacing)


def box(kind, x, y, w, h, fill=None, line=None, key=None, alpha=1.0, radius=0.18,
        paras=(), align="c", anchor="m", pad=0.15, line_w=1.5, name=None, rot=0):
    ps = []
    for p in paras:
        if isinstance(p, str):
            p = [Run(p)]
        elif isinstance(p, Run):
            p = [p]
        ps.append(p)
    return El(kind, x, y, w, h, fill=fill, line=line, key=key, alpha=alpha, radius=radius,
              paras=ps, align=align, anchor=anchor, pad=pad, line_w=line_w, name=name, rot=rot)


@dataclass
class Slide:
    els: list[El]
    notes: str = ""
    transition: str = "fade"      # fade | push | wipe | cover | zoom | morph | split
    anim: list = field(default_factory=list)   # groups, see Fx below


# Animation spec: a slide's `anim` is a list of groups:
#   ("auto" | "click", [substep, substep, ...])
# each substep is a list of Fx that start together; substeps run one after
# another ("after previous").
@dataclass
class Fx:
    key: str
    effect: str = "fade"          # fade | float | zoom | wipe | fly | spin | pulse | appear
    dur: int = 500
    delay: int = 0
    repeat: str | None = None     # "indefinite" or a count


# ── PowerPoint renderer ────────────────────────────────────────────────────

def _rgb(h):
    return RGBColor.from_string(h)


def _strip_style(shape):
    st = shape._element.find(qn("p:style"))
    if st is not None:
        shape._element.remove(st)


def _fill(shape, color, alpha):
    if color is None:
        shape.fill.background()
        return
    shape.fill.solid()
    shape.fill.fore_color.rgb = _rgb(color)
    if alpha < 1:
        clr = shape.fill._xPr.find(qn("a:solidFill")).find(qn("a:srgbClr"))
        a = clr.makeelement(qn("a:alpha"), {"val": str(int(alpha * 100000))})
        clr.append(a)


def _line(shape, color, width):
    if color is None:
        shape.line.fill.background()
    else:
        shape.line.color.rgb = _rgb(color)
        shape.line.width = Pt(width)


def _text(shape, el: El):
    tf = shape.text_frame
    tf.word_wrap = True
    for side in ("left", "right", "top", "bottom"):
        setattr(tf, f"margin_{side}", Inches(el.pad))
    tf.vertical_anchor = {"t": MSO_ANCHOR.TOP, "m": MSO_ANCHOR.MIDDLE, "b": MSO_ANCHOR.BOTTOM}[el.anchor]
    for i, runs in enumerate(el.paras):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = {"l": PP_ALIGN.LEFT, "c": PP_ALIGN.CENTER, "r": PP_ALIGN.RIGHT}[el.align]
        p.line_spacing = el.line_spacing
        for r in runs:
            run = p.add_run()
            run.text = r.text
            f = run.font
            f.name, f.size, f.bold = FONT, Pt(r.size), r.bold
            f.color.rgb = _rgb(r.color)


SHAPES = {"rect": MSO_SHAPE.RECTANGLE, "round": MSO_SHAPE.ROUNDED_RECTANGLE,
          "oval": MSO_SHAPE.OVAL, "arrow": MSO_SHAPE.RIGHT_ARROW, "text": MSO_SHAPE.RECTANGLE}


def _add(shapes, el: El, keys: dict):
    x, y, w, h = Inches(el.x), Inches(el.y), Inches(el.w), Inches(el.h)
    if el.kind == "image":
        shp = shapes.add_picture(el.src, x, y, w, h)
    elif el.kind == "group":
        shp = shapes.add_group_shape()
        for c in el.children:
            _add(shp.shapes, c, keys)
    else:
        shp = shapes.add_shape(SHAPES[el.kind], x, y, w, h)
        _strip_style(shp)
        if el.kind == "round":
            shp.adjustments[0] = el.radius
        _fill(shp, el.fill if el.kind != "text" else None, el.alpha)
        _line(shp, el.line if el.kind != "text" else None, el.line_w)
        if el.paras:
            _text(shp, el)
        if el.rot:
            shp.rotation = el.rot
    if el.name:
        shp.name = el.name
    el.shape = shp
    if el.key:
        keys[el.key] = shp


# Slide transitions. Morph needs PowerPoint 2019/365; everything else falls
# back to a fade there and in other apps.
def _transition_xml(kind):
    ns = 'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"'
    simple = {
        "fade": "<p:fade/>", "push": '<p:push dir="u"/>', "pushl": '<p:push dir="l"/>',
        "wipe": '<p:wipe dir="r"/>', "cover": '<p:cover dir="l"/>', "zoom": "<p:zoom/>",
        "split": '<p:split orient="vert" dir="out"/>', "wheel": '<p:wheel spokes="4"/>',
    }
    if kind == "morph":
        return (
            '<mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">'
            '<mc:Choice xmlns:p159="http://schemas.microsoft.com/office/powerpoint/2015/09/main" '
            'xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main" Requires="p159">'
            f'<p:transition {ns} spd="slow" p14:dur="1600"><p159:morph option="byObject"/></p:transition>'
            '</mc:Choice><mc:Fallback>'
            f'<p:transition {ns} spd="slow"><p:fade/></p:transition>'
            '</mc:Fallback></mc:AlternateContent>'
        )
    return f'<p:transition {ns} spd="med">{simple[kind]}</p:transition>'


class _Ids:
    def __init__(self):
        self.n = 2

    def next(self):
        self.n += 1
        return self.n


def _tgt(spid):
    return f'<p:tgtEl><p:spTgt spid="{spid}"/></p:tgtEl>'


def _set_visible(ids, spid):
    return (f'<p:set><p:cBhvr><p:cTn id="{ids.next()}" dur="1" fill="hold"><p:stCondLst>'
            f'<p:cond delay="0"/></p:stCondLst></p:cTn>{_tgt(spid)}<p:attrNameLst>'
            '<p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr>'
            '<p:to><p:strVal val="visible"/></p:to></p:set>')


def _anim_prop(ids, spid, attr, frm, to, dur):
    return (f'<p:anim calcmode="lin" valueType="num"><p:cBhvr additive="base">'
            f'<p:cTn id="{ids.next()}" dur="{dur}" fill="hold"/>{_tgt(spid)}<p:attrNameLst>'
            f'<p:attrName>{attr}</p:attrName></p:attrNameLst></p:cBhvr><p:tavLst>'
            f'<p:tav tm="0"><p:val><p:strVal val="{frm}"/></p:val></p:tav>'
            f'<p:tav tm="100000"><p:val><p:strVal val="{to}"/></p:val></p:tav></p:tavLst></p:anim>')


def _fade(ids, spid, dur, filt="fade"):
    return (f'<p:animEffect transition="in" filter="{filt}"><p:cBhvr>'
            f'<p:cTn id="{ids.next()}" dur="{dur}"/>{_tgt(spid)}</p:cBhvr></p:animEffect>')


# effect -> (presetClass, presetID, presetSubtype, grpId)
PRESETS = {"appear": ("entr", 1, 0, 0), "fade": ("entr", 10, 0, 0), "float": ("entr", 42, 0, 0),
           "zoom": ("entr", 53, 16, 0), "wipe": ("entr", 22, 8, 0), "fly": ("entr", 2, 4, 0),
           "spin": ("emph", 8, 0, 1), "pulse": ("emph", 26, 0, 1)}


def _effect(ids, fx: Fx, spid, node_type):
    cls, pid, sub, grp = PRESETS[fx.effect]
    d = fx.dur
    if fx.effect == "appear":
        body = _set_visible(ids, spid)
    elif fx.effect == "fade":
        body = _set_visible(ids, spid) + _fade(ids, spid, d)
    elif fx.effect == "float":
        body = (_set_visible(ids, spid) + _fade(ids, spid, d)
                + _anim_prop(ids, spid, "ppt_x", "#ppt_x", "#ppt_x", d)
                + _anim_prop(ids, spid, "ppt_y", "#ppt_y+0.08", "#ppt_y", d))
    elif fx.effect == "zoom":
        body = (_set_visible(ids, spid) + _fade(ids, spid, d)
                + _anim_prop(ids, spid, "ppt_w", "0", "#ppt_w", d)
                + _anim_prop(ids, spid, "ppt_h", "0", "#ppt_h", d))
    elif fx.effect == "wipe":
        body = _set_visible(ids, spid) + _fade(ids, spid, d, "wipe(left)")
    elif fx.effect == "fly":
        body = (_set_visible(ids, spid)
                + _anim_prop(ids, spid, "ppt_x", "#ppt_x", "#ppt_x", d)
                + _anim_prop(ids, spid, "ppt_y", "1+#ppt_h/2", "#ppt_y", d))
    elif fx.effect == "spin":
        body = (f'<p:animRot by="21600000"><p:cBhvr><p:cTn id="{ids.next()}" dur="{d}" fill="hold"/>'
                f'{_tgt(spid)}<p:attrNameLst><p:attrName>r</p:attrName></p:attrNameLst>'
                '</p:cBhvr></p:animRot>')
    elif fx.effect == "pulse":
        body = (f'<p:animScale><p:cBhvr><p:cTn id="{ids.next()}" dur="{d}" autoRev="1" fill="hold"/>'
                f'{_tgt(spid)}</p:cBhvr><p:by x="112000" y="112000"/></p:animScale>')
    else:
        raise ValueError(fx.effect)
    rep = f' repeatCount="{fx.repeat if fx.repeat == "indefinite" else int(fx.repeat) * 1000}"' if fx.repeat else ""
    return (f'<p:par><p:cTn id="{ids.next()}" presetID="{pid}" presetClass="{cls}" presetSubtype="{sub}"'
            f' fill="hold" grpId="{grp}" nodeType="{node_type}"{rep}><p:stCondLst><p:cond delay="{fx.delay}"/>'
            f'</p:stCondLst><p:childTnLst>{body}</p:childTnLst></p:cTn></p:par>')


def _timing_xml(groups, keys):
    ids = _Ids()
    out, builds = [], {}
    for trigger, substeps in groups:
        group_id = ids.next()
        start = ('<p:cond delay="indefinite"/><p:cond evt="onBegin" delay="0"><p:tn val="2"/></p:cond>'
                 if trigger == "auto" else '<p:cond delay="indefinite"/>')
        parts, t = [], 0
        for si, step in enumerate(substeps):
            effects = []
            for ei, fx in enumerate(step):
                shp = keys[fx.key]
                if si == 0 and ei == 0:
                    nt = "afterEffect" if trigger == "auto" else "clickEffect"
                elif ei == 0:
                    nt = "afterEffect"
                else:
                    nt = "withEffect"
                effects.append(_effect(ids, fx, shp.shape_id, nt))
                cls, _, _, grp = PRESETS[fx.effect]
                if shp.__class__.__name__ == "Shape":     # autoshapes with text bodies
                    builds[(shp.shape_id, grp)] = True
            parts.append(f'<p:par><p:cTn id="{ids.next()}" fill="hold"><p:stCondLst><p:cond delay="{t}"/>'
                         f'</p:stCondLst><p:childTnLst>{"".join(effects)}</p:childTnLst></p:cTn></p:par>')
            t += max(fx.dur * (1 if not fx.repeat or fx.repeat == "indefinite" else int(fx.repeat)) + fx.delay
                     for fx in step)
        out.append(f'<p:par><p:cTn id="{group_id}" fill="hold"><p:stCondLst>{start}</p:stCondLst>'
                   f'<p:childTnLst>{"".join(parts)}</p:childTnLst></p:cTn></p:par>')
    bld = "".join(f'<p:bldP spid="{s}" grpId="{g}" animBg="1"/>' for (s, g) in builds)
    return ('<p:timing xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
            '<p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never" nodeType="tmRoot"><p:childTnLst>'
            '<p:seq concurrent="1" nextAc="seek"><p:cTn id="2" dur="indefinite" nodeType="mainSeq">'
            f'<p:childTnLst>{"".join(out)}</p:childTnLst></p:cTn>'
            '<p:prevCondLst><p:cond evt="onPrev" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst>'
            '<p:nextCondLst><p:cond evt="onNext" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst>'
            '</p:seq></p:childTnLst></p:cTn></p:par></p:tnLst>'
            + (f'<p:bldLst>{bld}</p:bldLst>' if bld else '') + '</p:timing>')


def build_pptx(slides: list[Slide], path: str):
    prs = Presentation()
    prs.slide_width, prs.slide_height = Inches(W), Inches(H)
    blank = prs.slide_layouts[6]
    for s in slides:
        sl = prs.slides.add_slide(blank)
        bg = sl.background.fill
        bg.solid()
        bg.fore_color.rgb = _rgb(BG)
        keys = {}
        for el in s.els:
            _add(sl.shapes, el, keys)
        root = sl._element
        root.append(parse_xml(_transition_xml(s.transition)))
        if s.anim:
            root.append(parse_xml(_timing_xml(s.anim, keys)))
        if s.notes:
            sl.notes_slide.notes_text_frame.text = s.notes
    prs.save(path)


# ── HTML mirror (layout check only) ───────────────────────────────────────

def _css_color(h, a=1.0):
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return f"rgba({r},{g},{b},{a})"


def _html_el(el: El, dpi):
    st = [f"left:{el.x*dpi}px", f"top:{el.y*dpi}px", f"width:{el.w*dpi}px", f"height:{el.h*dpi}px"]
    if el.rot:
        st.append(f"transform:rotate({el.rot}deg)")
    if el.kind == "image":
        return f'<img src="{el.src}" style="position:absolute;{";".join(st)};object-fit:cover">'
    if el.kind == "group":
        return "".join(_html_el(c, dpi) for c in el.children)
    if el.fill and el.kind != "text":
        st.append(f"background:{_css_color(el.fill, el.alpha)}")
    if el.line and el.kind != "text":
        st.append(f"box-shadow: inset 0 0 0 {el.line_w*dpi/72}px #{el.line}")
    if el.kind == "round":
        st.append(f"border-radius:{min(el.w, el.h)*el.radius*dpi}px")
    if el.kind == "oval":
        st.append("border-radius:50%")
    if el.kind == "arrow":
        st.append("clip-path:polygon(0 25%,60% 25%,60% 0,100% 50%,60% 100%,60% 75%,0 75%)")
    jc = {"t": "flex-start", "m": "center", "b": "flex-end"}[el.anchor]
    ta = {"l": "left", "c": "center", "r": "right"}[el.align]
    inner = ""
    for runs in el.paras:
        spans = "".join(
            f'<span style="font-size:{r.size*dpi/72}px;color:#{r.color};font-weight:{700 if r.bold else 400}">'
            f'{html.escape(r.text).replace(chr(10), "<br>")}</span>' for r in runs)
        inner += f'<div style="text-align:{ta};line-height:{1.2*el.line_spacing}">{spans}</div>'
    st += ["display:flex", "flex-direction:column", f"justify-content:{jc}",
           f"padding:{el.pad*dpi if el.paras else 0}px", "box-sizing:border-box", "overflow:visible"]
    return f'<div style="position:absolute;{";".join(st)}">{inner}</div>'


def build_html(slides: list[Slide], path: str, dpi=96):
    pages = []
    for i, s in enumerate(slides, 1):
        body = "".join(_html_el(el, dpi) for el in s.els)
        pages.append(f'<section id="s{i}" style="position:relative;width:{W*dpi}px;height:{H*dpi}px;'
                     f'background:#{BG};overflow:hidden;margin:0 0 20px 0">{body}</section>')
    with open(path, "w") as f:
        f.write('<!doctype html><meta charset="utf-8"><body style="margin:0;background:#000;'
                f'font-family:Arial,\'Liberation Sans\',sans-serif">{"".join(pages)}</body>')
