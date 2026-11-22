#!/usr/bin/env python3
"""Generate Zera's voice line with ElevenLabs and save zera-vo.mp3 next to this script.

Run on your Mac (not inside Claude):   python3 make_zera_voice.py
Optional:  python3 make_zera_voice.py "Voice Name or voice_id"
           python3 make_zera_voice.py --list           (show your voices)
The API key is read from the .env below; it is never printed.
"""
import json, os, re, sys, urllib.request, urllib.error

ENV_FILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".env"))
TEXT = 'It\'s deploying on a Friday... <break time="1.3s" /> ...and nothing breaks.'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zera-vo.mp3")
API = "https://api.elevenlabs.io/v1"
# Stock ElevenLabs voices to fall back on if the key is not allowed to list voices.
STOCK = [("Gigi", "jBpfuIE2acCO8z3wKNLl"), ("Mimi", "zrHiDhphv9ZnVXBqCzjH"),
         ("Sarah", "EXAVITQu4vr4xnSDxMaL"), ("Rachel", "21m00Tcm4TlvDq8ikWAM")]

key = None
for line in open(ENV_FILE, encoding="utf-8"):
    m = re.match(r"\s*(?:export\s+)?([A-Za-z0-9_]+)\s*=\s*(.*)", line)
    if m and re.search(r"ELEVEN|XI_API", m.group(1), re.I):
        key = m.group(2).split(" #")[0].strip().strip("\"'")
        break
if not key:
    sys.exit("No ElevenLabs key found in %s." % ENV_FILE)

def call(path, body=None):
    req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body else None,
                                 headers={"xi-api-key": key, "Content-Type": "application/json"})
    try:
        return urllib.request.urlopen(req, timeout=120).read(), None
    except urllib.error.HTTPError as e:
        return None, "HTTP %s: %s" % (e.code, e.read().decode("utf-8", "replace")[:400])

arg = sys.argv[1] if len(sys.argv) > 1 else None
data, err = call("/voices")
voices = [(v["name"], v["voice_id"]) for v in json.loads(data)["voices"]] if data else []
if err:
    print("Could not list voices (%s)\n-> trying stock voices instead." % err)
if arg == "--list":
    print("\n".join(n for n, _ in voices) or "(no voice list available)")
    sys.exit()
if arg and re.fullmatch(r"[A-Za-z0-9]{20}", arg):
    order = [(arg, arg)]
else:
    picked = [v for v in voices if arg and arg.lower() in v[0].lower()]
    order = picked + ([] if picked else voices[:1]) + STOCK

for name, vid in order:
    audio, err = call("/text-to-speech/%s?output_format=mp3_44100_128" % vid, {
        "text": TEXT, "model_id": "eleven_multilingual_v2",
        "voice_settings": {"stability": 0.35, "similarity_boost": 0.75, "style": 0.4}})
    if audio:
        open(OUT, "wb").write(audio)
        print("Used voice: %s\nSaved %s" % (name, OUT))
        break
    print("Voice %s failed: %s" % (name, err))
else:
    sys.exit("\nNo voice worked. Paste the lines above back to Claude (they contain no key).")
