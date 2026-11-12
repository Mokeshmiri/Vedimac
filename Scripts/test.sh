#!/bin/bash
# Runs the fixture checks. They only touch copies of the files in Tests/Fixtures, inside a
# temporary folder. They never read the system plist and never restart the Mac.
# Works with the Command Line Tools alone (no XCTest).
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Vedimac version $(tr -d '[:space:]' < VERSION)"
swift run gaugecheck Tests/Fixtures
