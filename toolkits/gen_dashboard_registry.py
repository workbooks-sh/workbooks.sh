#!/usr/bin/env python3
"""Generate the dashboard's built-in Toolkits catalog FROM the registry.

Source of truth: toolkits/*/manifest.html. A toolkit surfaces in the cloud dashboard's "Toolkits"
group iff its <work-ref> carries a data-dashboard="<card blurb>" attribute. This regenerates the
standalone_catalog/0 block in dogfood/cloud/integrations.work (between the GENERATED markers).

Run from repo root:  python3 toolkits/gen_dashboard_registry.py
"""
import re, html, glob

def attr(tag, name):
    m = re.search(name + r'="([^"]*)"', tag)
    return html.unescape(m.group(1)) if m else None

entries = []
for p in glob.glob('toolkits/*/manifest.html'):
    tid = p.split('/')[1]
    m = re.search(r'<work-ref\b[^>]*>', open(p).read(), re.S)
    if not m: continue
    tag = m.group(0)
    dash = attr(tag, 'data-dashboard')
    if not dash: continue
    entries.append({'id': tid, 'name': (attr(tag, 'name') or tid).replace('-', ' ').title(),
                    'blurb': dash, 'detail': attr(tag, 'tagline') or dash,
                    'kind': attr(tag, 'data-kind') or 'skill',
                    'requires': [c for c in (attr(tag, 'data-requires') or '').split() if c],
                    'recommends': attr(tag, 'data-recommends')})

order = ['presentation', 'video', 'research', 'toolkit-forge']
entries.sort(key=lambda e: (order.index(e['id']) if e['id'] in order else 99, e['name']))

esc = lambda x: x.replace('\\', '\\\\').replace('"', '\\"')
def row(e):
    reqs = '[' + ', '.join('"%s"' % r for r in e['requires']) + ']'
    rec = '"%s"' % esc(e['recommends']) if e['recommends'] else 'nil'
    return ('      %%{id: "%s", name: "%s", status: "ready", default: true,\n'
            '        cap_kind: "%s", requires: %s, recommends: %s,\n'
            '        blurb: "%s",\n        detail: "%s"}'
            % (e['id'], esc(e['name']), e['kind'], reqs, rec, esc(e['blurb']), esc(e['detail'])))
rows = ',\n'.join(row(e) for e in entries)
block = ('  # >>> GENERATED toolkit registry — DO NOT EDIT BY HAND.\n'
         '  # Source of truth: toolkits/*/manifest.html with a `data-dashboard="<blurb>"` attr.\n'
         '  # Regenerate: python3 toolkits/gen_dashboard_registry.py\n'
         '  def standalone_catalog do\n    [\n' + rows + '\n    ]\n  end\n'
         '  # <<< GENERATED\n')

f = 'dogfood/cloud/integrations.work'
src = open(f).read()
src = re.sub(r'  (?:# >>> GENERATED.*?\n)?  ?def standalone_catalog do\n.*?\n  end\n(?:  # <<< GENERATED\n)?',
             block, src, count=1, flags=re.S)
open(f, 'w').write(src)
print('regenerated:', [e['id'] for e in entries])
