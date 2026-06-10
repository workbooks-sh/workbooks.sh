#!/bin/sh
# compile the page: page.tpl.html (human shell, NEVER edited by the agent) +
# sections/*.html (the agent's source partials, filename order = page order)
# -> index.html (build artifact, NEVER edited by hand) -> public site dir.
set -e
tmp=$(mktemp)
ls sections/*.html 2>/dev/null | sort | xargs cat 2>/dev/null > "$tmp" || true
awk -v inc="$tmp" '
  /<div id="grown"><\/div>/ {
    print "  <div id=\"grown\">"
    while ((getline line < inc) > 0) print line
    print "  </div>"
    next
  }
  { print }
' page.tpl.html > index.html
rm -f "$tmp"
cp -f index.html /data/build/public/wb-lander-live/index.html
if [ -d blog ]; then
  mkdir -p /data/build/public/wb-lander-live/blog
  cp -f blog/*.html /data/build/public/wb-lander-live/blog/ 2>/dev/null || true
fi
echo "built index.html ($(wc -c < index.html) bytes) and deployed"
