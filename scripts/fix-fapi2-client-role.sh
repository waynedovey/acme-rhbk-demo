#!/usr/bin/env bash
set -euo pipefail

FILE="scripts/configure-fapi2.sh"

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

bad_variants = [

    # Current broken form from the generated script
    '''"clients/'"$CLIENT_UUID"'/roles"''',

    # Possible equivalent forms
    """'clients/'"$CLIENT_UUID"'/roles'""",

    '''clients/'"$CLIENT_UUID"'/roles''',
]

replacement = '''"clients/$CLIENT_UUID/roles"'''

changed = False

for bad in bad_variants:

    if bad in s:

        print("Found malformed client-role path:")
        print(" ", bad)

        s = s.replace(
            bad,
            replacement,
        )

        changed = True


if not changed:

    # More targeted fallback.
    old = '''    "clients/'"$CLIENT_UUID"'/roles" \\
'''

    new = '''    "clients/$CLIENT_UUID/roles" \\
'''

    if old in s:

        s = s.replace(
            old,
            new,
            1,
        )

        changed = True


if not changed:

    print()
    print("Could not find exact malformed string.")
    print()
    print("Relevant lines currently in the script:")

    for number, line in enumerate(
        s.splitlines(),
        1,
    ):

        if (
            "CLIENT_UUID" in line
            and
            "roles" in line
        ):

            print(
                f"{number}: {line}"
            )

    raise SystemExit(
        "ERROR: No malformed client-role endpoint found"
    )


p.write_text(s)

print()
print("Fixed client-role endpoint.")
PY


echo
echo "Checking resulting client-role paths:"
echo

grep -n \
  'CLIENT_UUID.*roles\|clients/.*roles' \
  "$FILE" |
head -30


echo
echo "Checking for literal quote characters in client URLs..."

if grep -n \
  "clients/'" \
  "$FILE"
then

  echo
  echo "ERROR:"
  echo "A malformed clients/'... path still exists."
  exit 1

else

  echo "No malformed client paths found ✓"

fi


echo
echo "Checking shell syntax..."

bash -n "$FILE"

echo "Shell syntax: OK ✓"
echo


echo "======================================================"
echo " Re-running FAPI 2 configuration"
echo "======================================================"
echo

./scripts/configure-fapi2.sh
