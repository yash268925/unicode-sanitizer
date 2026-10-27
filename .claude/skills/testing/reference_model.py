"""usan の判定規則(.claude/skills/filter-rules/SKILL.md)の参照モデル。仕様検証用で、ビルド・表生成には使わない。

行単位・非ストリーミングの簡易版であり、正規の仕様は .claude/skills/filter-rules/SKILL.md である。

使い方:
  python3 -I .claude/skills/testing/reference_model.py <UCD_DIR> <corpus.txt> <emoji-test.txt>
UCD_DIR には .claude/skills/ucd-tables/SKILL.md の「入力ファイル」の UCD ファイルを平置きする。
"""
import sys, os, collections, bisect
D = sys.argv[1]
def parse(fn):
    for line in open(os.path.join(D, fn), encoding='utf-8'):
        line = line.split('#',1)[0].strip()
        if line: yield [x.strip() for x in line.split(';')]
def rng(s):
    a,_,b = s.partition('..'); return int(a,16), int(b or a,16)
def merge(rs):
    out=[]
    for a,b in sorted(tuple(x) for x in rs):
        if out and a <= out[-1][1]+1: out[-1][1]=max(out[-1][1],b)
        else: out.append([a,b])
    return out
def sub(rs, cut):
    s=set()
    for a,b in rs: s.update(range(a,b+1))
    for a,b in cut: s.difference_update(range(a,b+1))
    return merge([(c,c) for c in s])
class T:
    def __init__(s, rs): s.rs=rs; s.lo=[a for a,b in rs]
    def __contains__(s,c):
        i=bisect.bisect_right(s.lo,c)-1
        return i>=0 and s.rs[i][0]<=c<=s.rs[i][1]
prop=lambda fn,n: merge([rng(f[0]) for f in parse(fn) if f[1]==n])
DI=prop('DerivedCoreProperties.txt','Default_Ignorable_Code_Point')
EP=T(prop('emoji-data.txt','Extended_Pictographic'))
srs=collections.defaultdict(list)
for f in parse('Scripts.txt'): srs[f[1]].append(rng(f[0]))
allsc=sorted((a,b,s) for s,rs in srs.items() for a,b in rs); los=[x[0] for x in allsc]
def script(c):
    i=bisect.bisect_right(los,c)-1
    return allsc[i][2] if i>=0 and allsc[i][0]<=c<=allsc[i][1] else 'Unknown'
TR=T(merge(srs['Inherited']+prop('emoji-data.txt','Emoji_Modifier')))
js=set(); jchars=[]
for f in parse('DerivedJoiningType.txt'):
    if f[1] in 'DLRC':
        a,b=rng(f[0]); js.add(script(a)); jchars.append((a,b))
for f in parse('DerivedCombiningClass.txt'):
    if f[1]=='9':
        a,b=rng(f[0]); js.update(script(c) for c in range(a,b+1))
js-= {'Common','Inherited','Unknown'}
JS=T(sub(merge([r for s in js for r in srs[s]]+jchars), DI))
UI=T(prop('PropList.txt','Unified_Ideograph'))
pairs=set()
for f in parse('StandardizedVariants.txt'):
    b,v=[int(x,16) for x in f[0].split()]; pairs.add((b,v))
for f in parse('emoji-variation-sequences.txt'):
    b,v=[int(x,16) for x in f[0].split()]; pairs.add((b,v))
DIT=T(DI)
RTL=T(sub(merge([rng(f[0]) for f in parse('DerivedBidiClass.txt') if f[1] in ('R','AL')]), DI))
PARA={0x0A,0x0D,0x1C,0x1D,0x1E,0x85,0x2029}
MARKS={0x200E,0x200F,0x061C}
JOINERS={0x200C,0x200D}
def is_vs(c): return 0xFE00<=c<=0xFE0F or 0xE0100<=c<=0xE01EF or c in (0x180B,0x180C,0x180D,0x180F)
def is_tag(c): return 0xE0020<=c<=0xE007F
CONTEXTUAL=lambda c: c in MARKS or c in JOINERS or is_vs(c) or is_tag(c) or c in (0x115F,0x1160,0x180E)
def clean(text, first=True):
    # phase 1
    s=[]
    for i,ch in enumerate(text):
        c=ord(ch)
        if c==0xFEFF and first and i==0: s.append(c); continue
        if c in DIT and not CONTEXTUAL(c): continue
        s.append(c)
    # phase 2 (non-streaming model; prev = output, next = phase-1 stream)
    out=[]; i=0
    def last_base():
        for c in reversed(out):
            if c not in TR: return c
        return None
    rtl_seen=False
    while i<len(s):
        c=s[i]; nxt=s[i+1] if i+1<len(s) else None; prev=out[-1] if out else None
        if out:
            if out[-1] in PARA: rtl_seen=False
            elif out[-1] in RTL: rtl_seen=True
        if c in MARKS:
            if prev not in MARKS and (rtl_seen or (nxt is not None and nxt in RTL)): out.append(c)
            i+=1; continue
        if c in JOINERS:
            keep=False
            if prev not in JOINERS:
                lb=last_base()
                if lb is not None and lb in JS: keep=True
                elif nxt is not None and nxt in JS: keep=True
                elif c==0x200D and lb is not None and lb in EP and nxt is not None and nxt in EP: keep=True
            if keep: out.append(c)
            i+=1; continue
        if is_vs(c):
            if prev is not None and ((0xE0100<=c<=0xE01EF and prev in UI) or (prev,c) in pairs): out.append(c)
            i+=1; continue
        if c==0x115F:
            if nxt is not None and (0x1161<=nxt<=0x11A7 or 0xD7B0<=nxt<=0xD7C6): out.append(c)
            i+=1; continue
        if c==0x1160:
            if prev is not None and (0x1100<=prev<=0x115E or 0xA960<=prev<=0xA97C): out.append(c)
            i+=1; continue
        if c==0x180E:
            if prev is not None and 0x1800<=prev<=0x18AF and nxt in (0x1820,0x1821): out.append(c)
            i+=1; continue
        if is_tag(c):
            j=i; run=[]
            while j<len(s) and is_tag(s[j]):
                run.append(s[j]); j+=1
                if run[-1]==0xE007F: break
            spec=''.join(chr(x-0xE0000) for x in run[:-1])
            import re
            ok = prev==0x1F3F4 and run[-1]==0xE007F and re.fullmatch(r'(?:[a-z]{2}|[0-9]{3})[a-z0-9]{1,4}', spec)
            if ok: out.extend(run)
            i=j; continue
        out.append(c); i+=1
    return ''.join(map(chr,out))
if __name__=='__main__':
    print('JS ranges',len(JS.rs),'TR',len(TR.rs),'pairs',len(pairs))
    corpus=open(sys.argv[2],encoding='utf-8').read().split('\n')
    for ln in corpus:
        r=clean(ln, False)
        if r!=ln: print('CHANGED', ln[:2], repr(r))
    bad=0; total=0
    for line in open(sys.argv[3],encoding='utf-8'):
        if line.startswith('#') or ';' not in line: continue
        seq=''.join(chr(int(x,16)) for x in line.split(';')[0].split()); total+=1
        if clean(seq,False)!=seq:
            bad+=1
            if bad<10: print('EMOJI CHANGED', line.strip()[:90])
    print('emoji-test sequences',total,'changed',bad)
    samples={
     'persian ZWNJ':'می‌خواهم','devanagari ZWJ':'क्‍ष','bengali ra-zwj-virama':'র‍্য',
     'sinhala':'ශ්‍රී','malayalam chillu':'ണ്‍','arabic word-end ZWJ':'ه‍ ','arabic harakat ZWJ':'بَ‍ب',
     'kannada':'ರ‍್ಕ','IVS':'葛\U000E0100','CJK compat SVS':'㒞︀','keycap':'#️⃣',
     'mongolian fvs':'ᠠ᠋','mongolian mvs':'ᠨ᠎ᠠ','latin zwnj':'Auf‌lage',
     'smuggle':'ه‍‌‍‌ب','double zwj emoji':'👩‍‍💻','leading bom':'﻿abc',
     'flag+fe0f+tags':'🏴️\U000E0067\U000E0062\U000E0073\U000E0063\U000E0074\U000E007F',
     'tag too long':'🏴'+''.join(chr(0xE0000+ord(x)) for x in 'gbabcdefg')+'\U000E007F',
     'hangul filler pair':'ᅟᅠ','old hangul':'ᅟᅡ','vs after vs':'❤️️',
     'thai zwsp':'สวัสดี​ครับ', 'zwj before thai':'a‍ก',
    }
    for k,v in samples.items():
        r=clean(v, k=='leading bom')
        print(f'{k:24}', 'same' if r==v else 'CHANGED -> '+' '.join('%04X'%ord(c) for c in r))
