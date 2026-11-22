import sys, os, json
from tree_sitter_language_pack import get_parser
p = get_parser('swift')
root = sys.argv[1]; out = {}
for dp, dn, fn in os.walk(root):
    for f in fn:
        if not f.endswith('.swift'): continue
        path = os.path.join(dp, f); src = open(path, 'rb').read()
        t = p.parse(src); errs = []
        def walk(n):
            if n.is_error or n.is_missing: errs.append(n.start_point[0] + 1)
            if n.has_error:
                for c in n.children: walk(c)
        walk(t.root_node)
        if errs: out[os.path.relpath(path, root)] = sorted(set(errs))[:8]
json.dump(out, sys.stdout, indent=0, sort_keys=True)
