#!/bin/sh
# Runs every end-to-end test against the development stack (start it with bin/dev-up.sh).
d="$(dirname "$0")"
"$d/phase1.sh" && "$d/phase2.sh"
