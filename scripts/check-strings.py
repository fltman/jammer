#!/usr/bin/env python3
"""Holds the string catalogue and the code that uses it to the series' rule on languages
(the-apps/SIBLINGS.md, "Språk"; docs/LANGUAGES.md).

  scripts/check-strings.py                 the checks; exit 1 with one line per fault
  scripts/check-strings.py --require sv    also: every key has that language (when the words are chosen)
  scripts/check-strings.py --self-test     plants each kind of fault and fails unless every one is caught

What it checks:
  1. every key has the source language (en);
  2. in one text, placeholders are all numbered (%1$@) or all plain (%@), never both; a text with more
     than one placeholder numbers them (so that a language can put them in another order);
  3. a translation has the same placeholders as its source, written the same way: %1$@ is not %@;
  4. a count has the plural forms `one` and `other`, each with exactly one number, and nothing else;
  5. every key the code asks for (L10n.text, L10n.count) is in the catalogue, counts are asked for with
     L10n.count and nothing else is, and no key in the catalogue is unused;
  6. a file listed in scripts/l10n-moved.txt (one path a line: files whose texts have all been moved to
     the catalogue) has no text for the user written in it.
"""
import json, re, sys, os, tempfile, shutil

PLACEHOLDER = re.compile(r'%(?:(\d+)\$)?(?:\.\d+)?(@|lld|ld|d|f|s)')
# Calls whose first argument is a text the user sees.
SHOWS_TEXT = re.compile(r'(?:\b(?:Text|Button|Toggle|Label|Picker|TextField|SecureField|Section|Menu)|\.(?:help|accessibilityLabel|accessibilityHint|accessibilityValue|navigationTitle))\(\s*"((?:[^"\\]|\\.)*)"')
ALSO = re.compile(r'(?:messageText|informativeText|stringValue|toolTip|title)\s*=\s*"((?:[^"\\]|\\.)*)"|addButton\(withTitle:\s*"((?:[^"\\]|\\.)*)"')

def units(loc):
    """Every (form, text) of one localization: ('', text) or ('one', text), ('other', text)."""
    if 'stringUnit' in loc: return [('', loc['stringUnit'].get('value', ''))]
    forms = loc.get('variations', {}).get('plural', {})
    return [(k, v.get('stringUnit', {}).get('value', '')) for k, v in forms.items()]

def shape(text):
    """The placeholders of a text as written: [(number or None, kind), …]."""
    return [(m.group(1), m.group(2)) for m in PLACEHOLDER.finditer(text.replace('%%', ''))]

def check(root, require=None):
    faults = []
    cat_path = os.path.join(root, 'App', 'Localizable.xcstrings')
    try: cat = json.load(open(cat_path, encoding='utf-8'))
    except Exception as e: return [f'the catalogue can\'t be read: {e}']
    source = cat.get('sourceLanguage', 'en')
    strings = cat.get('strings', {})
    counts = set()
    for key, entry in strings.items():
        locs = entry.get('localizations', {})
        if source not in locs: faults.append(f'{key}: no {source} text'); continue
        if require and require not in locs: faults.append(f'{key}: no {require} text')
        src = units(locs[source])
        is_count = any(form for form, _ in src)
        if is_count: counts.add(key)
        for lang, loc in locs.items():
            us = units(loc)
            forms = {f for f, _ in us}
            if is_count and not {'one', 'other'} <= forms: faults.append(f'{key} ({lang}): a count needs the forms one and other, has {sorted(forms) or "none"}')
            if not is_count and forms != {''}: faults.append(f'{key} ({lang}): has plural forms where {source} has none')
            for form, text in us:
                ph = shape(text)
                numbered = [n for n, _ in ph if n is not None]
                where = f'{key} ({lang}{", " + form if form else ""})'
                if numbered and len(numbered) != len(ph): faults.append(f'{where}: mixes numbered and plain placeholders: "{text}"')
                if len(ph) > 1 and not numbered: faults.append(f'{where}: more than one placeholder and none numbered: "{text}"')
                if is_count and [k for _, k in ph] != ['lld']: faults.append(f'{where}: a count has exactly one number (%lld) and nothing else: "{text}"')
                if not text.strip() and key != 'mixer.automation.separator' and not text: faults.append(f'{where}: empty')
            if lang != source and not is_count:
                a, b = sorted(shape(src[0][1]), key=str), sorted(shape(us[0][1]) if us else [], key=str)
                if a != b: faults.append(f'{key} ({lang}): placeholders {["%" + (n + "$" if n else "") + k for n, k in b]} are not the source\'s {["%" + (n + "$" if n else "") + k for n, k in a]} (%1$@ is not %@)')
    # The code.
    used = {}
    app = os.path.join(root, 'App')
    for name in sorted(os.listdir(app)):
        if not name.endswith('.swift'): continue
        code = open(os.path.join(app, name), encoding='utf-8').read()
        for m in re.finditer(r'L10n\.(text|count)\(\s*"([^"]+)"', code): used.setdefault(m.group(2), set()).add(m.group(1))
    for key, how in sorted(used.items()):
        if key not in strings: faults.append(f'the code asks for "{key}", which is not in the catalogue'); continue
        if key in counts and how != {'count'}: faults.append(f'{key} is a count and must be asked for with L10n.count')
        if key not in counts and 'count' in how: faults.append(f'{key} is not a count but is asked for with L10n.count')
    for key in sorted(set(strings) - set(used)): faults.append(f'{key} is in the catalogue and nothing uses it')
    # Files whose texts have all been moved.
    moved = os.path.join(root, 'scripts', 'l10n-moved.txt')
    if os.path.exists(moved):
        for line in open(moved, encoding='utf-8'):
            path = line.split('#')[0].strip()
            if not path: continue
            full = os.path.join(root, path)
            if not os.path.exists(full): faults.append(f'{path} is listed as moved and is not there'); continue
            for n, row in enumerate(open(full, encoding='utf-8'), 1):
                code = row.split('//')[0]
                for m in list(SHOWS_TEXT.finditer(code)) + list(ALSO.finditer(code)):
                    text = next((g for g in m.groups() if g), '')
                    if re.search(r'[A-Za-zÅÄÖåäö]{2}', re.sub(r'\\\([^)]*\)', '', text)):
                        faults.append(f'{path}:{n}: text for the user written in the code: "{text[:60]}"')
    faults += text_logic(root)
    faults += british(root, strings)
    return faults

# The interface's English is American, as Apple's (the-apps/SIBLINGS.md, "Språk"): Center, Color, Gray,
# Canceled. Looked for in the catalogue's English and in the texts written in the app's code. A literal
# that is one word of code (a key, a field of the agent API such as "analysedSeconds") is not a text.
BRITISH = re.compile(r'\b(centre|colour|grey|cancell(?:ed|ing)|behaviour|favour|normalis|organis|recognis|licence|analys(?:e|ed|ing)\b|catalogue|labelled|travell|programme|metre)', re.I)
def british(root, strings):
    faults = []
    for key, entry in sorted(strings.items()):
        loc = entry.get('localizations', {}).get('en', {})
        for _, text in units(loc):
            m = BRITISH.search(text)
            if m: faults.append(f'{key} (en): "{m.group(1)}" is the British form; the interface\'s English is American')
    app = os.path.join(root, 'App')
    for name in sorted(os.listdir(app)):
        if not name.endswith('.swift'): continue
        for n, row in enumerate(open(os.path.join(app, name), encoding='utf-8'), 1):
            for lit in re.findall(r'"((?:[^"\\]|\\.)*)"', row.split('//')[0]):
                if re.fullmatch(r'[A-Za-z][A-Za-z0-9_.\-]*', lit) and not lit[0].isupper(): continue
                m = BRITISH.search(re.sub(r'\\\([^)]*\)', '', lit))
                if m: faults.append(f'App/{name}:{n}: "{m.group(1)}" is the British form; the interface\'s English is American')
    return faults

# Logic must not hang on a text the user sees (the-apps/SIBLINGS.md, "Språk"): a status line, a title, a
# message or a default name is another language's words tomorrow, and a comparison with the English ones
# then quietly stops being true. A line that compares with something that only looks like such a text
# (a file format's own word, say) says so at its end: `// not a shown text: <what it is>`.
SHOWN = r'(?:status|title|message|errorDescription|localizedDescription|label|stringValue|toolTip|line|l)'
LOGIC = [re.compile(r'\b' + SHOWN + r'\??\s*(?:==|!=)\s*"([A-ZÅÄÖ][a-zåäö]+[^"]*)"'),
         re.compile(r'\b' + SHOWN + r'\??\.(?:hasPrefix|hasSuffix|contains)\(\s*"([A-ZÅÄÖ][a-zåäö]+[^"]*)"')]
def text_logic(root):
    faults = []
    for base in ('App', os.path.join('Packages', 'JammerKit', 'Sources')):
        for folder, _, names in os.walk(os.path.join(root, base)):
            for name in sorted(names):
                if not name.endswith('.swift'): continue
                full = os.path.join(folder, name)
                for n, row in enumerate(open(full, encoding='utf-8'), 1):
                    if 'not a shown text:' in row: continue
                    code = row.split('//')[0]
                    for rx in LOGIC:
                        for m in rx.finditer(code):
                            faults.append(f'{os.path.relpath(full, root)}:{n}: logic that hangs on a text the user sees: "{m.group(1)[:50]}"')
    return faults

def self_test(root):
    """Each planted fault must be caught, and the clean copy must pass."""
    tmp = tempfile.mkdtemp()
    try:
        def fresh():
            d = os.path.join(tmp, 'r'); shutil.rmtree(d, ignore_errors=True)
            os.makedirs(os.path.join(d, 'App')); os.makedirs(os.path.join(d, 'scripts'))
            cat = {'sourceLanguage': 'en', 'version': '1.0', 'strings': {
                'a.two': {'localizations': {'en': {'stringUnit': {'value': '%1$@ of %2$@'}}, 'sv': {'stringUnit': {'value': '%2$@ har %1$@'}}}},
                'a.one': {'localizations': {'en': {'stringUnit': {'value': 'Level %@'}}, 'sv': {'stringUnit': {'value': 'Nivå %@'}}}},
                'a.count': {'localizations': {'en': {'variations': {'plural': {'one': {'stringUnit': {'value': '%lld point'}}, 'other': {'stringUnit': {'value': '%lld points'}}}}},
                                              'sv': {'variations': {'plural': {'one': {'stringUnit': {'value': '%lld punkt'}}, 'other': {'stringUnit': {'value': '%lld punkter'}}}}}}}}}
            code = 'let a = L10n.text("a.two", x, y); let b = L10n.text("a.one", x); let c = L10n.count("a.count", n)\n'
            return d, cat, code
        def run(mutate, moved=None, extra=''):
            d, cat, code = fresh()
            if mutate: mutate(cat['strings'])
            json.dump(cat, open(os.path.join(d, 'App', 'Localizable.xcstrings'), 'w'))
            open(os.path.join(d, 'App', 'Code.swift'), 'w').write(code + extra)
            if moved is not None: open(os.path.join(d, 'scripts', 'l10n-moved.txt'), 'w').write(moved)
            return check(d, require='sv')
        def sv(s, key, value): s[key]['localizations']['sv']['stringUnit']['value'] = value
        plants = {
            'a translation with %@ where the source has %1$@': (lambda s: sv(s, 'a.two', '%@ har %@'), None, ''),
            'numbered and plain placeholders in one text': (lambda s: sv(s, 'a.two', '%1$@ har %@'), None, ''),
            'a numbered placeholder where the source has a plain one': (lambda s: sv(s, 'a.one', 'Nivå %1$@'), None, ''),
            'a placeholder dropped in the translation': (lambda s: sv(s, 'a.one', 'Nivå'), None, ''),
            'a count without the form other': (lambda s: s['a.count']['localizations']['sv']['variations']['plural'].pop('other'), None, ''),
            'a count with a text beside the number': (lambda s: s['a.count']['localizations']['en']['variations']['plural']['one']['stringUnit'].update(value='%lld point on %@'), None, ''),
            'a key without the required language': (lambda s: s['a.one']['localizations'].pop('sv'), None, ''),
            'a key the code asks for that is not there': (None, None, 'let d = L10n.text("a.missing")\n'),
            'a key nothing uses': (lambda s: s.update({'a.spare': {'localizations': {'en': {'stringUnit': {'value': 'Spare'}}, 'sv': {'stringUnit': {'value': 'Extra'}}}}}), None, ''),
            'a count asked for as a text': (None, None, 'let e = L10n.text("a.count", 2)\n'),
            'user text in a file listed as moved': (None, 'App/Code.swift\n', 'Text("Hello there")\n'),
            'an alert text in a file listed as moved': (None, 'App/Code.swift\n', 'alert.messageText = "Send it?"\n'),
            'a British form in the catalogue': (lambda s: s['a.one']['localizations']['en']['stringUnit'].update(value='Centre %@'), None, ''),
            'a British form in a text in the code': (None, None, 'note("Cancelled; nothing changed.")\n'),
            'a colour chosen by a line\'s first word': (None, None, 'let c = line.hasPrefix("Warning") ? red : green\n'),
            'a decision made on the status line\'s words': (None, None, 'if session.status == "Uploading the files" { ask() }\n'),
        }
        bad = []
        clean = run(None, 'App/Code.swift\n', 'Text(L10n.text("a.one", x)); Text("\\(n)")\nif title == "Fcpxml" { } // not a shown text: the format\'s own word\nif op.name == "limit" { }\nlet f = info["analysedSeconds"]\n')
        if clean: bad.append('the clean copy was faulted: ' + '; '.join(clean))
        for name, (mutate, moved, extra) in plants.items():
            if not run(mutate, moved, extra): bad.append('not caught: ' + name)
        return bad, len(plants)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

if __name__ == '__main__':
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    if '--self-test' in sys.argv:
        bad, n = self_test(root)
        for b in bad: print('check-strings self-test:', b)
        if not bad: print(f'check-strings self-test: every planted fault caught ({n} kinds), and a clean catalogue passes')
        sys.exit(1 if bad else 0)
    require = sys.argv[sys.argv.index('--require') + 1] if '--require' in sys.argv else None
    faults = check(root, require)
    for f in faults: print('check-strings:', f)
    if not faults:
        n = len(json.load(open(os.path.join(root, 'App', 'Localizable.xcstrings'), encoding='utf-8'))['strings'])
        print(f'check-strings: {n} keys, as the rule says' + (f', each with {require}' if require else ' (no second language required yet)'))
    sys.exit(1 if faults else 0)
