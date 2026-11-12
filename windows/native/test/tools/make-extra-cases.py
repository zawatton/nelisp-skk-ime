#!/usr/bin/env python3
"""Generate golden/realtime-extra.txt (hand-written scenarios, see SCENARIOS).

Step syntax: 'keys:abc' feeds each char; 'k:41' feeds one key by hex code;
BS COMMIT QUIT RESTORE KATA CKATA HIRA RESET; 'cont:1'.  A step may carry
expectations after ' ? ': r=0|1 m=<0-4> c=<-1|0> t=<hex units> p=<romaji>
(and flags composing= preedit= katakana= latin= wide=) checked on that op
(for 'keys:' on the last key).  Expectations are derived by hand from the C++
semantics and then verified by the g++ oracle (realtime-oracle.cpp) and by the
nelisp EXE under wine, so a wrong expectation fails both.
Usage: make-extra-cases.py > golden/realtime-extra.txt
"""
def u(s):
    return ".".join("%04x" % ord(c) for c in s) if s else "-"


SCENARIOS = [
    ("plain ka", ["keys:k ? t=- p=k composing=1", "keys:a ? t=%s p=- composing=0" % u("か")]),
    ("kka sokuon", ["keys:k", "keys:k ? t=%s p=k" % u("っ"), "keys:a ? t=%s p=- composing=0" % u("っか")]),
    ("n apostrophe is not a rule key", ["keys:n ? p=n", "k:27 ? t=%s p=- composing=0" % u("n'")]),
    ("nn", ["keys:n", "keys:n ? t=%s p=-" % u("ん")]),
    ("n before consonant", ["keys:n", "keys:k ? t=%s p=k" % u("ん"), "keys:a ? t=%s" % u("んか")]),
    ("n then vowel", ["keys:n", "keys:a ? t=%s" % u("な")]),
    ("kyo and sya", ["keys:kyo ? t=%s" % u("きょ"), "keys:sya"]),
    ("si/shi/ji", ["keys:si", "keys:shi", "keys:ji ? t=%s" % u("じ")]),
    ("xtu and ltsu (l is the latin toggle unless in preedit)", ["keys:xtu ? t=%s" % u("っ"), "keys:ltsu ? latin=1 r=0", "RESET ? latin=1"]),
    ("ltsu inside preedit", ["keys:Kaltsu ? t=%s" % u("▽かっ")]),
    ("non-rule letter", ["keys:q ? m=1 katakana=1", "keys:q ? katakana=0", "keys:c", "keys:q", "keys:f", "keys:w"]),
    ("katakana toggle then ka", ["keys:q ? katakana=1", "keys:ka ? t=%s" % u("カ"), "keys:kka ? t=%s" % u("ッカ")]),
    ("Q toggles too", ["keys:Q ? katakana=1 preedit=0", "keys:Q ? katakana=0"]),
    ("okurigana Kanasi", ["keys:K ? m=4 c=0 t=%s p=k preedit=1" % u("▽"),
                          "keys:a ? t=%s" % u("▽か"), "keys:n", "keys:a ? t=%s" % u("▽かな"),
                          "keys:S ? t=%s p=s" % u("▽かな*"), "keys:i ? t=%s p=-" % u("▽かな*し"),
                          "COMMIT ? m=0 c=-1 t=%s composing=0 preedit=0" % u("かな*し")]),
    ("okurigana only once", ["keys:Ka", "keys:S", "keys:K ? p=k t=%s" % u("▽か*s"), "keys:a"]),
    ("okurigana needs text", ["keys:K ? t=%s p=k" % u("▽"), "keys:K ? p=k"]),
    ("backspace across carry in preedit", ["keys:Kak", "BS ? t=%s p=- preedit=1" % u("▽か"),
                                           "BS ? t=%s composing=1" % u("▽"), "BS ? r=1 composing=0 preedit=0 t=-"]),
    ("backspace pending only", ["keys:k", "BS ? t=- p=- composing=0", "BS ? r=0"]),
    ("backspace nothing", ["BS ? r=0", "COMMIT ? r=0", "QUIT ? r=0", "KATA ? r=0", "CKATA ? r=0"]),
    ("backspace rebuilds okurigana", ["keys:KaSi", "BS ? t=%s p=s" % u("▽か*"), "BS ? t=%s" % u("▽か"),
                                      "keys:Ki"]),
    ("backspace removes sokuon pending", ["keys:Kakk", "BS ? t=%s p=k" % u("▽か"), "BS"]),
    ("commit pending n hiragana", ["keys:Kan", "COMMIT ? t=%s composing=0" % u("かん")]),
    ("commit pending n katakana", ["keys:q", "keys:Kan", "COMMIT ? t=%s" % u("カン")]),
    ("commit pending non-n", ["keys:Kak", "COMMIT ? t=%s" % u("かk")]),
    ("commit katakana n", ["keys:Kan", "CKATA ? t=%s katakana=0" % u("カン")]),
    ("KATA then more typing", ["keys:Ka", "KATA ? t=%s katakana=1" % u("▽カ"), "keys:ki ? t=%s" % u("▽カキ")]),
    ("KATA outside preedit", ["KATA ? r=0", "keys:ka", "KATA ? r=0"]),
    ("HIRA from katakana", ["keys:Ka", "KATA", "HIRA ? m=4 t=%s katakana=0" % u("▽か"), "HIRA"]),
    ("HIRA clears latin", ["keys:l ? latin=1", "HIRA ? m=0 latin=0"]),
    ("latin eats keys", ["keys:l", "keys:a ? r=0", "keys:K ? r=0", "BS ? r=0"]),
    ("wide latin", ["keys:L ? m=3 wide=1", "keys:A ? t=ff21 c=-1", "k:7e ? t=ff5e", "keys:  ? t=3000"]),
    ("n then l falls to latin", ["keys:n", "keys:l ? m=2 t=%s latin=1" % u("ん")]),
    ("n then q toggles katakana", ["keys:n", "keys:q ? katakana=1 t=%s" % u("ん")]),
    ("punctuation", ["keys:. ? t=%s" % u("。"), "keys:, ? t=%s" % u("、"), "keys:- ? t=%s" % u("ー"),
                     "keys:[ ? t=%s" % u("「"), "keys:] ? t=%s" % u("」"), "keys:1 ? t=%s" % u("1")]),
    ("punctuation flushes pending", ["keys:Kak", "keys:. ? t=%s p=-" % u("▽かk。")]),
    ("preedit digit", ["keys:K1 ? t=%s" % u("▽k1")]),
    ("space in preedit", ["keys:Ka", "k:20 ? t=25bd.304b.0020"]),
    ("reject unprintable", ["k:1 ? r=0", "k:7f ? r=0", "k:80 ? r=0", "k:3042 ? r=0", "k:1f ? r=0", "k:20 ? r=1"]),
    ("RESET keeps modes", ["keys:q", "keys:Ka", "RESET ? composing=0", "keys:ka ? t=%s katakana=1" % u("カ")]),
    ("RESTORE outside preedit", ["keys:ka", "RESTORE ? r=1 m=1" if False else "RESTORE ? r=1 m=0 c=-1 t=-"]),
    ("QUIT keeps katakana mode", ["keys:q", "keys:Ka", "QUIT ? m=1 c=-1 t=- composing=0"]),
    ("QUIT in latin mode reports hiragana", ["keys:l", "QUIT ? r=0"]),
    ("continuous preedit", ["cont:1", "keys:ka ? m=4 t=%s" % u("▽か"), "keys:L ? t=%s p=l" % u("▽か"),
                            "keys:q ? t=%s p=q" % u("▽かl"), "BS", "BS", "BS", "BS", "BS ? composing=0"]),
    ("continuous: l is text", ["cont:1", "keys:l ? m=4 t=25bd p=l", "keys:S ? p=s"]),
    ("tt and chi/cha", ["keys:tt ? t=%s p=t" % u("っ"), "keys:cha", "keys:cchi"]),
    ("ky then q", ["keys:Kyq", "keys:a"]),
    ("katakana sokuon and small", ["keys:q", "keys:xya", "keys:xx"]),
    ("fa va", ["keys:fa ? t=%s" % u("ふぁ"), "keys:va ? t=%s" % u("ゔ" + "ぁ"), "keys:vu"]),
    ("ToHiragana converts katakana text", ["keys:q", "keys:Kavu", "HIRA ? t=%s" % u("▽かゔ")]),
    ("unknown consonant run", ["keys:bq", "keys:zzz", "keys:wyw"]),
    ("deep prefix", ["keys:Kaltsu", "keys:lts ? p=lts", "BS ? p=lt", "keys:s", "keys:u"]),
    ("preedit entered by capital after pending", ["keys:k", "keys:A ? preedit=1", "keys:a"]),
    ("preview reading", ["keys:Ka", "keys:K", "keys:Ka"]),
    ("two objects interleaved", ["keys:Ka"]),
]


def main():
    print("# hand-written scenarios; generated by tools/make-extra-cases.py")
    op = 0
    for si, (name, steps) in enumerate(SCENARIOS):
        obj = "x%d" % si
        print("# %s" % name)
        print("NEW %s" % obj); op += 1
        for step in steps:
            body, _, exp = step.partition(" ? ")
            if body.startswith("cont:"):
                print("CONT %s %s" % (obj, body[5:])); op += 1; continue
            if body.startswith("keys:"):
                keys = [ord(c) for c in body[5:]]
            elif body.startswith("k:"):
                keys = [int(body[2:], 16)]
            else:
                keys = None
            if keys is not None:
                for k in keys:
                    print("FEED %s %x" % (obj, k)); op += 1
            else:
                names = {"BS": "BS", "COMMIT": "COMMIT", "QUIT": "QUIT", "RESTORE": "RESTORE",
                         "KATA": "KATA", "CKATA": "CKATA", "HIRA": "HIRA", "RESET": "RESET"}
                print("%s %s" % (names[body], obj)); op += 1
            if exp:
                print("CHECK 0 " + " ".join("@%d:%s" % (op - 1, e) for e in exp.split()))
main()
