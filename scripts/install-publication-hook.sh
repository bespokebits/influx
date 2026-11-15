#!/usr/bin/env bash
# Optional: a pre-commit hook that runs scripts/check-publication.py on what
# is staged, so a private term stops a commit before it is made. Run it once
# per clone if you want it; nothing installs it for you. It writes one file
# in this clone's hooks directory (core.hooksPath when that is set) and
# changes no git configuration. Remove the file to uninstall.
set -euo pipefail
cd "$(dirname "$0")/.."

hooks="$(git rev-parse --git-path hooks)"
hook="$hooks/pre-commit"
marker="From scripts/install-publication-hook.sh"

if [[ -e "$hook" ]] && ! grep -qF "$marker" "$hook"; then
  echo "$hook already exists and is not this hook. Add this line to it instead:" >&2
  echo '  python3 "$(git rev-parse --show-toplevel)/scripts/check-publication.py" --staged || exit 1' >&2
  exit 1
fi

mkdir -p "$hooks"
cat >"$hook" <<'HOOK'
#!/bin/sh
# From scripts/install-publication-hook.sh: nothing private in what is staged.
exec python3 "$(git rev-parse --show-toplevel)/scripts/check-publication.py" --staged
HOOK
chmod +x "$hook"
echo "installed $hook"
