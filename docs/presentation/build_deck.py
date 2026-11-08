"""Builds the EchoPin v0.4 update deck, its HTML preview and SPEECH.md.

    python build_deck.py            # needs: pip install python-pptx

The speech lives here (SPEECH below) so the speaker notes in the deck and
SPEECH.md always say the same thing. [CLICK] marks where to advance.
"""

import math
import os
import sys

from deck_lib import (ACCENT, AMBER, BG, BLUE, GREEN, LINE, MUTED, PURPLE, RED, SURF,
                      SURF2, TEAL, TEXT, El, Fx, Run, Slide, W, H, box, build_html,
                      build_pptx, text)

HERE = os.path.dirname(os.path.abspath(__file__))
A = lambda name: os.path.join(HERE, "assets", name)


# ── Reusable pieces ────────────────────────────────────────────────────────

def pinwheel(cx, cy, r, key="pin"):
    """EchoPin's radar motif: rings, you in the middle, friends around."""
    kids = []
    for i, f in enumerate((1.0, 0.68, 0.36)):
        kids.append(box("oval", cx - r * f, cy - r * f, 2 * r * f, 2 * r * f,
                        fill=ACCENT, alpha=0.05 + 0.04 * i, line=ACCENT, line_w=1.2))
    kids.append(box("oval", cx - r * 0.1, cy - r * 0.1, r * 0.2, r * 0.2, fill=ACCENT))
    for ang, col, d in ((35, GREEN, 0.68), (140, AMBER, 0.95), (220, TEAL, 0.5), (310, RED, 0.85)):
        a = math.radians(ang)
        px, py = cx + math.cos(a) * r * d, cy - math.sin(a) * r * d
        kids.append(box("oval", px - r * 0.07, py - r * 0.07, r * 0.14, r * 0.14, fill=col))
    return El("group", children=kids, name="!!pinwheel", key=key)


def heading(kicker, title, color=ACCENT):
    return [
        text(0.7, 0.45, 9, 0.4, Run(kicker.upper(), 14, color, True), key="kicker"),
        text(0.7, 0.8, 11.5, 1.0, Run(title, 36, TEXT, True), key="title"),
    ]


def card(x, y, w, h, title, body, color=ACCENT, key=None, title_size=20, body_size=15, spacing=1.0):
    return El("group", key=key, children=[
        box("round", x, y, w, h, fill=SURF, line=LINE, radius=0.08),
        box("rect", x, y + 0.25, 0.08, h - 0.5, fill=color),
        text(x + 0.3, y + 0.22, w - 0.5, 0.6, Run(title, title_size, TEXT, True)),
        text(x + 0.3, y + 0.22 + title_size / 72 * 1.35 + 0.08, w - 0.5, h - 0.9, Run(body, body_size, MUTED),
             spacing=spacing),
    ])


def stat(x, y, w, h, number, label, color, key):
    return El("group", key=key, children=[
        box("round", x, y, w, h, fill=SURF, line=color, radius=0.1, line_w=2),
        text(x, y + 0.25, w, 1.4, Run(number, 72, color, True), align="c"),
        text(x + 0.2, y + h - 0.95, w - 0.4, 0.8, Run(label, 16, TEXT), align="c"),
    ])


def chip(x, y, w, label, color, key=None, size=13):
    return box("round", x, y, w, 0.38, fill=color, alpha=0.18, line=color, line_w=1, radius=0.5,
               paras=[Run(label, size, color, True)], key=key, pad=0.02)


def glow(x, y, d, color, a=0.07):
    return box("oval", x, y, d, d, fill=color, alpha=a)


def floats(*keys, gap=0, dur=450):
    return [[Fx(k, "float", dur, gap)] for k in keys]


# ── Slides ────────────────────────────────────────────────────────────────

slides: list[Slide] = []

# 1. Title
slides.append(Slide(transition="zoom", els=[
    glow(8.2, -1.5, 7, BLUE, 0.10), glow(-2, 4.5, 5, PURPLE, 0.08),
    pinwheel(9.6, 3.75, 2.6),
    text(0.8, 1.55, 7, 0.45, Run("ECHOPIN · UPDATE v0.4", 16, ACCENT, True), key="kicker"),
    text(0.8, 2.05, 7.4, 2.2, Run("EchoPin grew up.", 60, TEXT, True), key="title"),
    text(0.8, 3.35, 6.1, 1.4, Run("Real accounts, sealed emergency records, a central console, "
                                  "and a security review that tested itself.", 22, MUTED), key="sub"),
    chip(0.8, 5.0, 2.0, "Still serverless", GREEN, key="c1"),
    chip(2.95, 5.0, 2.4, "Optional server", ACCENT, key="c2"),
    chip(5.5, 5.0, 2.3, "Tested for real", AMBER, key="c3"),
    text(0.8, 6.55, 6, 0.4, Run("November 2026", 14, MUTED), key="date"),
], anim=[("auto", [[Fx("pin", "zoom", 900)], [Fx("kicker", "fade", 300)],
                   [Fx("title", "float", 600)], [Fx("sub", "fade", 500)],
                   [Fx("c1", "zoom", 300)], [Fx("c2", "zoom", 300)], [Fx("c3", "zoom", 300)],
                   [Fx("date", "fade", 300), Fx("pin", "spin", 24000, repeat="indefinite")]])]))

# 2. Where we started
slides.append(Slide(transition="morph", els=[
    pinwheel(12.2, 0.95, 0.55),
    *heading("Where we started · v0.3", "Three promises we kept"),
    card(0.7, 2.3, 3.8, 3.6, "Relative, not absolute",
         "No coordinates exist anywhere. Distance comes from Bluetooth signal strength, "
         "measured on your own phone.", GREEN, key="a", body_size=17),
    card(4.75, 2.3, 3.8, 3.6, "No servers needed",
         "Phones talk directly over Bluetooth and Wi-Fi. Works on a mountain with no signal.",
         ACCENT, key="b", body_size=17),
    card(8.8, 2.3, 3.8, 3.6, "Encrypted and signed",
         "Every message sealed with XChaCha20-Poly1305 and signed with a per-session Ed25519 key.",
         PURPLE, key="c", body_size=17),
    text(0.7, 6.3, 12, 0.5, Run("None of this changed. Everything new sits on top.", 18, AMBER, True),
         key="foot"),
], anim=[("click", floats("a", "b", "c")), ("click", [[Fx("foot", "wipe", 600)]])]))

# 3. What was asked
asks = [("Real accounts", "Not IMEI numbers or serials", ACCENT),
        ("Emergency history", "For the right people, when it matters", RED),
        ("Reports", "And diagnostics from every phone, in one place", AMBER),
        ("Backups", "So nothing is lost", GREEN)]
els3 = [*heading("The brief", "What we were asked to build")]
for i, (t, b, c) in enumerate(asks):
    x = 0.7 + i * 3.08
    els3.append(El("group", key=f"t{i}", children=[
        box("round", x, 2.3, 2.85, 3.0, fill=SURF, line=c, line_w=2, radius=0.1),
        box("oval", x + 0.95, 2.6, 0.95, 0.95, fill=c, alpha=0.2, line=c,
            paras=[Run(str(i + 1), 28, c, True)], pad=0),
        text(x + 0.15, 3.8, 2.55, 0.5, Run(t, 20, TEXT, True), align="c"),
        text(x + 0.2, 4.35, 2.45, 0.9, Run(b, 15, MUTED), align="c"),
    ]))
els3.append(box("round", 0.7, 5.75, 11.95, 0.9, fill=SURF2, radius=0.3, key="q",
                paras=[Run("“More security than using the system's IMEI… and a report system that shows "
                           "user reports across all systems.”", 17, TEXT)], pad=0.2))
slides.append(Slide(transition="push", els=els3,
                    anim=[("click", [[Fx(f"t{i}", "zoom", 400)] for i in range(4)]),
                          ("click", [[Fx("q", "float", 500)]])]))

# 4. The big idea
nodes = [("Phones", "talk to each other\nexactly as before", GREEN, 0.7),
         ("Outbox", "stores & forwards\nwhen there's signal", AMBER, 3.85),
         ("Server", "accounts, records,\naudit, backups", ACCENT, 7.0),
         ("Console", "responders &\nadmins", PURPLE, 10.15)]
els4 = [*heading("The big idea", "An optional central server")]
for i, (t, b, c, x) in enumerate(nodes):
    els4.append(El("group", key=f"n{i}", children=[
        box("round", x, 2.45, 2.5, 2.3, fill=SURF, line=c, line_w=2.5, radius=0.12),
        text(x, 2.75, 2.5, 0.6, Run(t, 26, c, True), align="c"),
        text(x + 0.1, 3.5, 2.3, 1.1, Run(b, 15, MUTED), align="c"),
    ]))
    if i < 3:
        els4.append(box("arrow", x + 2.55, 3.35, 0.55, 0.5, fill=c, key=f"ar{i}"))
els4 += [
    box("round", 0.7, 5.3, 11.95, 1.25, fill=SURF2, radius=0.2, key="note", align="l", pad=0.3,
        paras=[[Run("No server address built into the app?  ", 18, AMBER, True),
                Run("It runs exactly like v0.3: local, offline, no account.", 18, TEXT)]]),
]
anim4 = [[Fx("n0", "float", 400)]]
for i in range(3):
    anim4 += [[Fx(f"ar{i}", "wipe", 300)], [Fx(f"n{i+1}", "float", 400)]]
slides.append(Slide(transition="wipe", els=els4,
                    anim=[("click", anim4), ("click", [[Fx("note", "float", 500)]])]))

# 5. Identity
rows = [("Readable by other apps?", "Yes", "No"), ("Can be copied and replayed?", "Yes", "No"),
        ("Available on modern phones?", "Rarely", "Always"), ("Can be revoked?", "No", "Yes, per device")]
els5 = [*heading("Identity", "A device key, not an IMEI"),
        text(5.6, 2.15, 3.2, 0.5, Run("IMEI / serial", 18, RED, True), align="c", key="h1"),
        text(9.0, 2.15, 3.6, 0.5, Run("EchoPin device key", 18, GREEN, True), align="c", key="h2")]
for i, (q, bad, good) in enumerate(rows):
    y = 2.8 + i * 0.85
    els5.append(El("group", key=f"r{i}", children=[
        box("round", 0.7, y, 11.95, 0.7, fill=SURF, radius=0.25),
        text(1.0, y + 0.17, 4.5, 0.4, Run(q, 17, TEXT)),
        chip(6.45, y + 0.16, 1.5, bad, RED, size=14),
        chip(10.0, y + 0.16, 1.9 if len(good) > 6 else 1.5, good, GREEN, size=14),
    ]))
els5.append(text(0.7, 6.35, 12, 0.6, [Run("Sign-in proves the key: ", 16, ACCENT, True),
                                      Run("an Ed25519 signature over “purpose | email | time”, checked within 5 minutes. "
                                          "A stolen refresh token is useless without the phone.", 16, MUTED)], key="foot"))
slides.append(Slide(transition="cover", els=els5,
                    anim=[("auto", [[Fx("h1", "fade", 300), Fx("h2", "fade", 300)]]),
                          *[("click", [[Fx(f"r{i}", "float", 400)]]) for i in range(4)],
                          ("click", [[Fx("foot", "fade", 500)]])]))

# 6. Two locks
els6 = [*heading("Sealed emergency records", "Two locks, two different people"),
        box("round", 0.9, 2.2, 6.4, 4.6, fill=ACCENT, alpha=0.08, line=ACCENT, line_w=2.5, radius=0.08,
            key="outer", anchor="t", align="l", pad=0.25,
            paras=[Run("OUTER LOCK · server's escrow key", 15, ACCENT, True)]),
        box("round", 1.55, 3.0, 5.1, 3.25, fill=PURPLE, alpha=0.12, line=PURPLE, line_w=2.5, radius=0.08,
            key="inner", anchor="t", align="l", pad=0.25,
            paras=[Run("INNER LOCK · custodian key (responders only)", 15, PURPLE, True)]),
        box("round", 2.25, 3.85, 3.7, 1.9, fill=SURF2, line=GREEN, line_w=2, radius=0.1, key="core",
            paras=[Run("The record", 22, TEXT, True), Run("who, when, SOS, check-ins", 14, MUTED),
                   Run("never coordinates", 14, GREEN, True)]),
        card(7.8, 2.2, 4.85, 1.35, "Server alone?", "Opens only its own layer. Can't read the record.",
             ACCENT, key="p1", body_size=14),
        card(7.8, 3.8, 4.85, 1.35, "Stolen database + keys?", "Still sealed: the custodian key isn't there.",
             RED, key="p2", body_size=14),
        card(7.8, 5.4, 4.85, 1.35, "Responder in an emergency?", "Server peels its layer (audited), "
             "console opens the rest.", GREEN, key="p3", body_size=14)]
slides.append(Slide(transition="fade", els=els6,
                    anim=[("click", [[Fx("core", "zoom", 500)]]),
                          ("click", [[Fx("inner", "zoom", 500)]]),
                          ("click", [[Fx("outer", "zoom", 500)]]),
                          ("click", floats("p1", "p2", "p3"))]))

# 7. Break-glass
steps = [("Give a reason", "10+ characters, plus a\ncase number if there is one", AMBER),
         ("Audit first", "grant written before\nanything is decrypted", ACCENT),
         ("Admins alerted", "every admin gets an\nemail straight away", RED),
         ("Opened locally", "custodian key on the\nresponder's own device", GREEN)]
els7 = [*heading("Break-glass", "Opening a record leaves a trail"),
        box("rect", 2.2, 3.42, 9.3, 0.07, fill=LINE, key="track")]
for i, (t, b, c) in enumerate(steps):
    x = 0.85 + i * 3.1
    els7.append(El("group", key=f"s{i}", children=[
        box("oval", x + 0.75, 2.85, 1.2, 1.2, fill=SURF2, line=c, line_w=3,
            paras=[Run(str(i + 1), 30, c, True)], pad=0),
        text(x, 4.3, 2.7, 0.5, Run(t, 21, TEXT, True), align="c"),
        text(x, 4.85, 2.7, 1.0, Run(b, 15, MUTED), align="c"),
    ]))
els7.append(text(0.7, 6.3, 12, 0.5, Run("Staff accounts must have two-step sign-in before the console answers them.",
                                        17, AMBER, True), key="foot"))
slides.append(Slide(transition="pushl", els=els7,
                    anim=[("auto", [[Fx("track", "wipe", 700)]]),
                          *[("click", [[Fx(f"s{i}", "zoom", 400)], [Fx(f"s{i}", "pulse", 250)]]) for i in range(4)],
                          ("click", [[Fx("foot", "fade", 500)]])]))

# 8. Numbers
slides.append(Slide(transition="zoom", els=[
    glow(4.2, 1.2, 5, RED, 0.06),
    *heading("We attacked our own code", "Two security reviews, then live testing", RED),
    stat(0.7, 2.3, 3.8, 3.3, "10", "faults found and fixed in the first review", ACCENT, "n1"),
    stat(4.75, 2.3, 3.8, 3.3, "11", "remaining risks closed in the second pass", PURPLE, "n2"),
    stat(8.8, 2.3, 3.8, 3.3, "5", "bugs only real, end-to-end testing caught", RED, "n3"),
    text(0.7, 6.05, 12, 0.6, Run("None of them let anyone read a sealed record.", 20, GREEN, True),
         align="c", key="foot"),
], anim=[("click", [[Fx("n1", "zoom", 450)], [Fx("n1", "pulse", 250)]]),
         ("click", [[Fx("n2", "zoom", 450)], [Fx("n2", "pulse", 250)]]),
         ("click", [[Fx("n3", "zoom", 450)], [Fx("n3", "pulse", 250)]]),
         ("click", [[Fx("foot", "float", 500)]])]))

# 9. Fix highlights
fixes = [("Spoofed IP addresses", "Read from the header the host overwrites, never the one the client writes",
          ACCENT),
         ("Account pre-hijacking", "Confirming an email needs the code and the sign-up password", RED),
         ("Lockout used as a weapon", "Your own registered phones skip the lock; strangers can't keep you out",
          AMBER),
         ("Who has an account?", "Same answer and same timing for every email address", PURPLE),
         ("Breached passwords", "Checked against Have I Been Pwned; only 5 hash characters leave", TEAL),
         ("Rewriting the audit log", "Keyed HMAC chain plus an anchor stored with every backup", GREEN)]
els9 = [*heading("Highlights", "What we fixed, in plain words")]
for i, (t, b, c) in enumerate(fixes):
    x, y = 0.7 + (i % 3) * 4.05, 2.2 + (i // 3) * 2.2
    els9.append(card(x, y, 3.85, 2.0, t, b, c, key=f"f{i}", title_size=18, body_size=14))
slides.append(Slide(transition="split", els=els9,
                    anim=[("click", floats("f0", "f1", "f2")), ("click", floats("f3", "f4", "f5"))]))

# 10. Tested for real
els10 = [*heading("Tested for real", "Not just unit tests", GREEN),
         stat(0.7, 2.25, 2.85, 2.9, "30/30", "live server checks", GREEN, "a"),
         stat(3.75, 2.25, 2.85, 2.9, "213", "app tests", ACCENT, "b"),
         stat(6.8, 2.25, 2.85, 2.9, "62", "server tests", PURPLE, "c"),
         stat(9.85, 2.25, 2.8, 2.9, "6", "protocol tests", TEAL, "d"),
         box("round", 0.7, 5.5, 11.95, 1.15, fill=SURF2, radius=0.2, key="how", align="l", pad=0.3,
             paras=[[Run("How: ", 17, AMBER, True),
                     Run("a real compiled server and database, a client signing genuine device proofs, and the "
                         "real app clicked through on a hidden virtual display.", 17, TEXT)]])]
for el in els10[2:6]:
    el.children[1].paras[0][0].size = 54
slides.append(Slide(transition="fade", els=els10,
                    anim=[("click", [[Fx(k, "float", 380)] for k in "abcd"]),
                          ("click", [[Fx("how", "wipe", 600)]])]))

# 11. Bugs found
bugs = ["The two-step setup dialog crashed on every platform",
        "The console crashed right after a record was opened",
        "One SOS showed up as three",
        "A real member could be branded a fake on a tie",
        "Test runs wrote into the app's real data folder"]
els11 = [*heading("Found by real testing", "Five bugs the test suites missed", AMBER)]
anim11 = []
for i, b in enumerate(bugs):
    y = 2.2 + i * 0.88
    els11 += [box("round", 0.7, y, 11.95, 0.72, fill=SURF, radius=0.25, key=f"row{i}", align="l", pad=0.25,
                  paras=[Run(b, 18, TEXT)]),
              chip(10.6, y + 0.17, 1.6, "BUG", RED, key=f"bug{i}"),
              chip(10.6, y + 0.17, 1.6, "FIXED", GREEN, key=f"ok{i}")]
    els11[-1].fill, els11[-1].alpha = SURF, 1.0   # opaque, so FIXED fully covers BUG
    anim11.append(("click", [[Fx(f"row{i}", "float", 350), Fx(f"bug{i}", "zoom", 350)],
                             [Fx(f"ok{i}", "zoom", 400, 250)]]))
slides.append(Slide(transition="cover", els=els11, anim=anim11))

# 12. Screens
shots = [(A("console-needs-two-step.png"), "Staff need two-step first"),
         (A("session-not-proven.png"), "Uploads from non-members are flagged"),
         (A("custodian-key.png"), "The custodian key stays on the device")]
els12 = [*heading("See it", "The real app, against the live server")]
for i, (src, cap) in enumerate(shots):
    x = 0.7 + i * 4.05
    els12.append(El("group", key=f"i{i}", children=[
        box("round", x - 0.06, 2.24, 3.97, 2.36, fill=LINE, radius=0.05),
        El("image", x, 2.3, 3.85, 2.166, src=src),
        text(x, 4.75, 3.85, 0.8, Run(cap, 16, TEXT, True), align="c"),
    ]))
els12.append(text(0.7, 6.1, 12, 0.6, Run("Screenshots from the end-to-end test run, unedited.", 15, MUTED),
                  align="c", key="foot"))
slides.append(Slide(transition="push", els=els12,
                    anim=[*[("click", [[Fx(f"i{i}", "zoom", 450)]]) for i in range(3)],
                          ("click", [[Fx("foot", "fade", 400)]])]))

# 13. Free hosting
hosts = [("GitHub", "code + keep-awake\nping every 10 min", MUTED),
         ("Render", "the server, Docker,\nFrankfurt", ACCENT),
         ("Supabase", "PostgreSQL +\nencrypted backups", GREEN),
         ("Brevo", "sign-in codes\nby email", AMBER)]
els13 = [*heading("Running it", "Hosted for free")]
for i, (t, b, c) in enumerate(hosts):
    x = 0.7 + i * 3.08
    els13.append(El("group", key=f"h{i}", children=[
        box("round", x, 2.35, 2.85, 2.4, fill=SURF, line=c, line_w=2, radius=0.12),
        text(x, 2.7, 2.85, 0.6, Run(t, 26, c, True), align="c"),
        text(x + 0.1, 3.45, 2.65, 1.1, Run(b, 15, MUTED), align="c"),
    ]))
els13 += [card(0.7, 5.15, 5.85, 1.5, "Keys never in the code", "One secret, ECHOPIN_KEYS, kept in a password "
               "manager. The server refuses to start without it.", PURPLE, key="k1", body_size=14),
          card(6.8, 5.15, 5.85, 1.5, "Data location", "Frankfurt today. The same image runs in a South "
               "African region if POPIA requires it.", AMBER, key="k2", body_size=14)]
slides.append(Slide(transition="wipe", els=els13,
                    anim=[("click", [[Fx(f"h{i}", "float", 350)] for i in range(4)]),
                          ("click", floats("k1", "k2"))]))

# 14. Limits and next steps
els14 = [pinwheel(12.2, 0.95, 0.55),
         *heading("Honest about what's left", "Limits and next steps", AMBER),
         card(0.7, 2.2, 5.85, 4.4, "Still on us",
              "• Create the custodian key before real use\n"
              "• Two-step on every hosting account\n"
              "• Test Bluetooth between real phones\n"
              "• Decide where the data lives", AMBER, key="l", body_size=20, spacing=1.5),
         card(6.8, 2.2, 5.85, 4.4, "Next",
              "• “Verified account” badges in sessions\n"
              "• Deploy to the free hosting stack\n"
              "• Field trial with a real group\n"
              "• Tune retention with the organisation", GREEN, key="r", body_size=20, spacing=1.5)]
slides.append(Slide(transition="fade", els=els14,
                    anim=[("click", [[Fx("l", "float", 450)]]), ("click", [[Fx("r", "float", 450)]])]))

# 15. Thanks
slides.append(Slide(transition="morph", els=[
    glow(3.2, 0.2, 7, BLUE, 0.08),
    pinwheel(W / 2, 2.85, 1.9),
    text(0.7, 5.05, 11.95, 1.0, Run("Thank you", 54, TEXT, True), align="c", key="t"),
    text(0.7, 6.05, 11.95, 0.6, Run("Questions? I can show any line of code behind any of this.", 20, MUTED),
         align="c", key="s"),
], anim=[("auto", [[Fx("t", "float", 600)], [Fx("s", "fade", 500),
                                             Fx("pin", "spin", 24000, repeat="indefinite")]])]))


# ── Speech ────────────────────────────────────────────────────────────────
# (title, minutes:seconds at the end of this slide, text with [CLICK] cues)

SPEECH = [
    ("Title", "0:45",
     "Good morning, everyone. The last time I stood here, I showed you EchoPin: an app that keeps a group "
     "together without GPS, without servers and without accounts. Today I want to tell you how EchoPin grew "
     "up, and why it is now safer, not less safe, even though it can talk to a server. Three things changed: "
     "real accounts, sealed emergency records, and a central console. And then we spent a lot of time "
     "trying to break all of it."),
    ("Where we started", "1:45",
     "First, what did not change. [CLICK] EchoPin still never knows where you are. There is no latitude or "
     "longitude anywhere in the code. Distance comes from Bluetooth signal strength, measured on your own "
     "phone. Phones still talk directly to each other, so it works on a mountain with no signal. And every "
     "message is still encrypted and signed. [CLICK] None of that changed. Everything I'm about to show "
     "you sits on top of it."),
    ("The brief", "2:30",
     "So why change anything? Because we were asked for four things. [CLICK] Real user accounts, with more "
     "security than identifying phones by their IMEI number. A history of sessions that the right people can "
     "check in an emergency. Reports and diagnostics from every phone in one place. And backups. [CLICK] In "
     "the words of the brief: more security than the system's IMEI, and reports across all systems."),
    ("The big idea", "3:30",
     "Here's how we did it. [CLICK] Phones still talk to each other exactly as before. When there's "
     "signal, an outbox on the phone forwards things to a central server: accounts, sealed session records, "
     "reports and diagnostics. Responders and admins see that in a console. The outbox is the clever bit: if "
     "you're offline, nothing is lost. It waits, and sends when it can. [CLICK] And the server is optional. If "
     "an organisation doesn't set one up, the app runs exactly like before: local, offline, no account."),
    ("Identity", "4:30",
     "Now, the IMEI question. Why not just identify phones by their IMEI? [CLICK] Because other apps can "
     "read it. [CLICK] Anyone who reads it can copy and replay it. [CLICK] Modern Android and iPhones mostly "
     "don't let apps see it at all. [CLICK] And you can't revoke it. Instead, every install makes its own "
     "device key. The private half never leaves the phone. [CLICK] When you sign in, the phone signs a "
     "short statement with that key, and the server checks it within five minutes. So if someone steals your "
     "refresh token, it's useless without your actual phone."),
    ("Two locks", "5:45",
     "The most sensitive thing we store is the emergency record of a session. [CLICK] The record says who "
     "was there, when someone pressed SOS, who checked in. Never coordinates. [CLICK] It's sealed inside a "
     "lock that only responders can open, using a custodian key that lives on their devices, never on the "
     "server. [CLICK] And that's sealed again inside a lock only the server can open. [CLICK] So the server "
     "on its own can't read a record. Someone who steals the database and the server's keys still can't read "
     "one. A responder in a real emergency can: the server opens its layer, and the console opens the rest."),
    ("Break-glass", "6:45",
     "Opening a record is what we call break-glass, like the fire alarm. [CLICK] You must give a reason. "
     "[CLICK] The server writes that reason into the audit log before it decrypts anything, so there's no "
     "way to read a record without leaving a trace. [CLICK] Every admin gets an email straight away. [CLICK] "
     "Then the responder's own device opens the inner lock. [CLICK] And staff accounts must turn on two-step "
     "sign-in before the console will even answer them."),
    ("We attacked our own code", "7:45",
     "Then we tried to break it. [CLICK] The first security review found ten faults and fixed every one. "
     "[CLICK] A second pass closed the eleven risks we had first accepted. [CLICK] And then testing the real "
     "app against a live server found five more bugs that no automated test had caught. [CLICK] The "
     "important part: none of them let anyone read a sealed record."),
    ("Highlights", "9:00",
     "A few highlights, in plain words. [CLICK] The server used to trust an IP address the client could "
     "simply make up, which let attackers dodge rate limits and fake the audit log. Fixed. Someone could "
     "register your email just after you did and have you activate their password. Fixed: confirming now "
     "needs your password too. Anyone could lock you out by typing wrong passwords. Now your own phones skip "
     "that lock. [CLICK] The server no longer reveals who has an account, not even through timing. Passwords "
     "that appear in public data breaches are refused, and only five characters of a hash leave the server to "
     "check. And the audit log is now signed with a secret key, so even someone with full database access "
     "can't rewrite history."),
    ("Tested for real", "9:45",
     "How do we know it works? [CLICK] Thirty out of thirty checks against a real running server, plus over "
     "two hundred and eighty automated tests across the app, the server and the shared protocol. [CLICK] "
     "And we didn't stop at unit tests: a real compiled server, a real database, and the real app, clicked "
     "through on a hidden screen."),
    ("Found by real testing", "10:45",
     "That last step paid off. Five bugs. [CLICK] The two-step setup dialog crashed on every platform. "
     "[CLICK] The console crashed right after a responder opened a record. [CLICK] One SOS was being "
     "counted three times, once per phone that saw it. [CLICK] With exactly one real member and one outsider, "
     "the membership check could brand the real member as the fake. [CLICK] And our own test runs were "
     "writing into the app's real data folder. Every one is fixed, and every one now has a test."),
    ("See it", "11:30",
     "Here's the real app. [CLICK] An admin without two-step is turned away. [CLICK] A session where "
     "someone uploaded a record without being in it: flagged, \"not proven a member\". [CLICK] And the "
     "custodian key, imported on a responder's device and never uploaded. [CLICK] These are straight from "
     "the test run."),
    ("Running it", "12:15",
     "Running it costs nothing. [CLICK] GitHub holds the code and keeps the server awake. Render runs the "
     "server. Supabase holds the database and the encrypted backups. Brevo sends the sign-in codes. [CLICK] "
     "The keys never go in the code; the server refuses to start without them. And the data sits in "
     "Frankfurt today, but the same image runs in a South African region if POPIA needs it."),
    ("Limits and next steps", "13:00",
     "I want to be honest about what's left. [CLICK] Before real use, we need to create the custodian key, "
     "turn on two-step for every account around the server, test Bluetooth between real phones, and decide "
     "where the data lives. [CLICK] Next, we'd like verified-account badges inside sessions, a real "
     "deployment, and a field trial with a real group."),
    ("Thank you", "13:30",
     "EchoPin still doesn't know where you are. Now it can also help the right people find out what "
     "happened, and only them, and only with a reason everyone can see. Thank you. I'm happy to take "
     "questions, including about any line of code behind this."),
]

assert len(SPEECH) == len(slides), (len(SPEECH), len(slides))


def clicks(s: Slide) -> int:
    return sum(1 for trigger, _ in s.anim if trigger == "click")


for s, (title, _, words) in zip(slides, SPEECH):
    n = words.count("[CLICK]")
    assert n == clicks(s), f"{title}: speech has {n} clicks, slide has {clicks(s)}"
    s.notes = words.replace("[CLICK]", "▶")


def write_speech(path):
    total = sum(len(w.split()) for _, _, w in SPEECH)
    lines = ["# EchoPin v0.4: update speech", "",
             f"About 13½ minutes ({total} words at a relaxed pace). The same words are in each slide's "
             "speaker notes, where ▶ means advance.", "",
             "**How to read this.** **[CLICK]** means advance the slide (each click starts the next "
             "animation). The time after each heading is where you should be when that slide ends. If you're "
             "running long, skip slide 12 (*See it*); it saves about 45 seconds.", "",
             "For code questions, use `CODE_REFERENCE.md`: every function mentioned here, with its file and "
             "line, and short answers to the questions you're most likely to get.", "", "---", ""]
    for i, (title, t, words) in enumerate(SPEECH, 1):
        lines += [f"## {i}. {title} (ends {t})", "", words.replace("[CLICK]", "**[CLICK]**"), ""]
    open(path, "w").write("\n".join(lines))


if __name__ == "__main__":
    out = HERE
    build_pptx(slides, os.path.join(out, "EchoPin_v0.4_Update.pptx"))
    write_speech(os.path.join(out, "SPEECH.md"))
    if "--preview" in sys.argv:
        build_html(slides, os.path.join(sys.argv[sys.argv.index("--preview") + 1], "preview.html"))
    print(f"{len(slides)} slides, {sum(clicks(s) for s in slides)} clicks")
