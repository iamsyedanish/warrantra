#!/bin/zsh
# Puts the Firebase push key into backend/.env and copies it for Railway.
# Usage: ./scripts/set-fcm-env.sh [path-to-service-account.json]
# Without a path it uses the newest *firebase-adminsdk*.json in ~/Downloads.
# It never prints the key, and deletes the downloaded file when done.
set -e
cd "$(dirname "$0")/.."

FILE="${1:-$(ls -t ~/Downloads/*firebase-adminsdk*.json 2>/dev/null | head -1)}"
if [[ -z "$FILE" || ! -f "$FILE" ]]; then
  echo "No Firebase key file found. Click 'Generate new private key' in Firebase first."
  exit 1
fi

python3 - "$FILE" <<'PY'
import json, re, sys, pathlib
key = json.load(open(sys.argv[1]))
if key.get("type") != "service_account" or "private_key" not in key:
    sys.exit("That file is not a Firebase service-account key.")
one_line = json.dumps(key, separators=(",", ":"))
env = pathlib.Path(".env")
text = env.read_text()
values = {
    "PUSH_PROVIDER": "fcm",
    "FCM_PROJECT_ID": key["project_id"],
    "FCM_SERVICE_ACCOUNT_JSON": "'" + one_line + "'",
}
for name, value in values.items():
    line = f"{name}={value}"
    pattern = re.compile(rf"^#?\s*{name}=.*$", re.M)
    text = pattern.sub(lambda _m: line, text, count=1) if pattern.search(text) else text.rstrip("\n") + "\n" + line + "\n"
env.write_text(text)
pathlib.Path("/tmp/.warrantra-fcm-oneline").write_text(one_line)
print(f"backend/.env updated for project {key['project_id']} (key not shown).")
PY

pbcopy < /tmp/.warrantra-fcm-oneline
rm -f /tmp/.warrantra-fcm-oneline
rm -f "$FILE"
echo "The one-line key is on your clipboard. Paste it into Railway as FCM_SERVICE_ACCOUNT_JSON."
echo "Deleted the downloaded key file."
