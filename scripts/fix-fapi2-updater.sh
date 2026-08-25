#!/usr/bin/env bash
set -euo pipefail

FILE="scripts/update-fapi2-status.sh"

[[ -f "$FILE" ]] || {
  echo "ERROR: Cannot find $FILE"
  exit 1
}

BACKUP="${FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp "$FILE" "$BACKUP"

echo
echo "Backup:"
echo "  $BACKUP"
echo

python3 - "$FILE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old = r'''    marker = '    if path == "/login":\n'
'''

new = r'''    # ------------------------------------------------
    # Find the first route inside the Portal application.
    #
    # Earlier versions of this updater assumed /login was
    # the first route. The Portal now contains several demo
    # routes before /login, so find the route dynamically.
    # ------------------------------------------------

    app_start = s.find("\ndef app(")

    if app_start < 0:
        app_start = s.find("def app(")

    if app_start < 0:
        raise SystemExit(
            "ERROR: Could not locate def app() in portal/app.py"
        )

    app_text = s[app_start:]

    route_match = re.search(
        r'(?m)^    if path\b[^\n]*:\s*$',
        app_text,
    )

    if not route_match:
        raise SystemExit(
            "ERROR: Could not locate any Portal route "
            "inside def app()"
        )

    marker = route_match.group(0) + "\n"

    print(
        "FAPI routes will be inserted before: "
        + route_match.group(0).strip()
    )
'''

if old not in s:
    raise SystemExit(
        "ERROR: Could not find the old /login route anchor "
        "inside update-fapi2-status.sh"
    )

s = s.replace(
    old,
    new,
    1,
)

p.write_text(s)

print()
print(f"Fixed {p}")
PY


echo
echo "Checking updater syntax..."

bash -n "$FILE"

echo "Updater syntax: OK"
echo


echo "======================================================"
echo " Re-running FAPI 2 Portal update"
echo "======================================================"
echo

./scripts/update-fapi2-status.sh
