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


# ============================================================
# Replace the old hard-coded route anchor:
#
#     marker = '    if path == "/login":\n'
#
# with dynamic route discovery inside def app().
# ============================================================

old = '''    marker = '    if path == "/login":\\n'
'''

new = r'''    # ------------------------------------------------
    # Dynamically locate the first route inside def app().
    #
    # The Portal now has many demo routes, so /login is no
    # longer a safe insertion anchor.
    # ------------------------------------------------

    app_match = re.search(
        r'(?m)^def app\([^)]*\):\s*$',
        s,
    )

    if not app_match:

        raise SystemExit(
            "ERROR: Could not locate def app() "
            "inside portal/app.py"
        )


    app_text = s[
        app_match.end():
    ]


    route_match = re.search(
        r'(?m)^    if path(?:\s*==|\s+in\b).*?:\s*$',
        app_text,
    )


    if not route_match:

        raise SystemExit(
            "ERROR: Could not locate any "
            "'if path ...' route inside def app()"
        )


    marker = (
        route_match.group(0)
        + "\n"
    )


    print(
        "FAPI routes will be inserted before:"
    )

    print(
        "  "
        + route_match.group(0).strip()
    )
'''


count = s.count(old)

print(
    "Old hard-coded route anchors found:",
    count,
)


if count == 0:

    # --------------------------------------------------------
    # More tolerant fallback in case whitespace differs.
    # --------------------------------------------------------

    import re

    pattern = re.compile(
        r'''(?m)^    marker\s*=\s*'''
        r'''['"]    if path == "/login":\\n['"]\s*$'''
    )


    matches = list(
        pattern.finditer(s)
    )


    print(
        "Fallback matches found:",
        len(matches),
    )


    if not matches:

        # ----------------------------------------------------
        # Show useful diagnostic information instead of
        # silently failing.
        # ----------------------------------------------------

        print()
        print(
            "Existing route-marker lines in updater:"
        )

        for line_no, line in enumerate(
            s.splitlines(),
            1,
        ):

            if (
                "marker =" in line
                and
                "path" in line
            ):

                print(
                    f"{line_no}: {line}"
                )


        raise SystemExit(
            "ERROR: Could not find the old route "
            "marker in update-fapi2-status.sh"
        )


    s = pattern.sub(
        new.rstrip(),
        s,
        count=1,
    )


else:

    s = s.replace(
        old,
        new,
        1,
    )


p.write_text(s)


print()
print(
    f"Patched {p}"
)

print()
print(
    "Remaining hard-coded /login anchors:",
    s.count(
        '''marker = '    if path == "/login":\\n' '''
            .strip()
    ),
)
PY


echo
echo "Checking updater shell syntax..."

bash -n "$FILE"

echo "Updater shell syntax: OK"
echo


echo "Checking that dynamic route discovery exists..."

grep -n \
  'FAPI routes will be inserted before' \
  "$FILE"


echo
echo "Checking that the old hard-coded marker is gone..."

if grep -nF \
  'marker = '\''    if path == "/login":\n'\''' \
  "$FILE"
then

  echo
  echo "ERROR:"
  echo "Old hard-coded marker still exists."
  exit 1

else

  echo "Old hard-coded route marker removed ✓"

fi


echo
echo "======================================================"
echo " Re-running FAPI 2 Portal updater"
echo "======================================================"
echo


bash -x ./scripts/update-fapi2-status.sh
