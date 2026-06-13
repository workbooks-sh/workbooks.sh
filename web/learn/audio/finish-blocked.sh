#!/bin/bash
# Finish the 20 ElevenLabs-quota-blocked library lessons once credits reset.
# Renders narration + cues, composes episodes, flips catalog live, deploys.
# Idempotent: re-run safely; only missing artifacts are produced.
# Usage: XI_API_KEY=… CLOUDFLARE_ACCOUNT_ID=… bash finish-blocked.sh
set -eu
cd "$(dirname "$0")"
REPO="$(cd ../../.. && pwd)"

BLOCKED="signatures the-dock telemetry secrets tokens trust verification tangling the-kernel todos tags spawning the-ledger the-seam validations waves worlds upgrades volumes vectors"

echo "── 1 · narration (ElevenLabs TTS) ──"
node generate.mjs $BLOCKED

echo "── 2 · music cues ──"
node cues.mjs $BLOCKED

echo "── 3 · compose episodes ──"
node compose.mjs $BLOCKED

echo "── 4 · OG cards ──"
( cd "$REPO/web" && python3 og/build.py $BLOCKED )

echo "── 5 · flip catalog live ──"
python3 - <<PY
import json, datetime
p="$REPO/web/learn/lessons.json"
ready="$BLOCKED".split()
cat=json.load(open(p)); today=datetime.date.today().isoformat(); n=0
for t in cat["tiers"]:
  for l in t["lessons"]:
    for s in l.get("sublessons",[]):
      if s["slug"] in ready and s["status"]=="planned":
        s["status"]="live"; s["audio"]=True; s["added"]=today; n+=1
open(p,"w").write(json.dumps(cat,indent=1)+"\n")
print("flipped",n,"live")
PY

echo "── 6 · ship ──"
cd "$REPO"
git add web/learn/ web/og/
git commit -m "feat(learn): final 20 library lessons live — all 74 deep dives complete"
git pull --rebase --autostash
git push
bash web/deploy.sh
echo "DONE — all 74 deep-dive lessons live."
