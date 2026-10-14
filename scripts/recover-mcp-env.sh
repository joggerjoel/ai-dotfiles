#!/usr/bin/env bash
# Recover saved MCP credentials without displaying their values.
set -euo pipefail

case "${1:-}" in
  ""|--dry-run) ;;
  *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "Too many arguments" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

python3 - "${1:-}" <<'PY'
import datetime
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sys
import tempfile


def main():
    dry_run = sys.argv[1] == '--dry-run'
    home = Path.home()
    target = home / '.claude/.env'
    servers = json.loads((home / '.claude.json').read_text())['mcpServers']
    mappings = {
        'MORPH_API_KEY': 'morphllm-fast-apply',
        'FIRECRAWL_API_KEY': 'firecrawl-mcp',
        'GITHUB_PERSONAL_ACCESS_TOKEN': 'github',
        'OPENROUTER_API_KEY': 'openrouterai',
        'APIFY_TOKEN': 'apify',
        'DIGITALOCEAN_API_TOKEN': 'digitalocean-mcp',
    }
    candidates = {
        key: servers.get(server, {}).get('env', {}).get(key, '')
        for key, server in mappings.items()
    }
    n8n = servers.get('n8n-mcp', {})
    auth = n8n.get('headers', {}).get('Authorization', '')
    candidates['N8N_JWT'] = auth[7:] if auth.lower().startswith('bearer ') else ''
    candidates['N8N_URL'] = n8n.get('url', '')

    def usable(value):
        return (isinstance(value, str) and bool(value.strip())
                and value != 'PLACEHOLDER' and '${' not in value
                and 'REPLACE-ME.invalid' not in value
                and not value.lower().startswith(('your_', 'your-', 'replace_', 'replace-')))

    original = target.read_text() if target.exists() else ''
    lines = original.splitlines(keepends=True)
    updates = {}
    for key, value in candidates.items():
        pattern = re.compile(r'^\s*(?:export\s+)?' + key + r'\s*=(.*)$')
        matches = [pattern.match(line) for line in lines]
        existing = [match.group(1).strip() for match in matches if match]
        # Preserve any existing nonempty assignment, including shell expressions.
        if existing and existing[-1] not in ('', "''", '""'):
            print(f'Kept {key}')
        elif usable(value):
            # setup.sh/preflight strip quotes and spaces when reading .env.
            if any(char.isspace() or char in "\"'" for char in value):
                raise ValueError('Credential format incompatible with the current env reader')
            updates[key] = value
            print(f'{"Would restore" if dry_run else "Restoring"} {key}')
        else:
            print(f'Missing {key}: no saved value to recover')

    if not updates or dry_run:
        print('No files changed.')
        return

    os.umask(0o077)
    backup_dir = home / '.claude/.backups/env'
    backup_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    if target.exists():
        backup = backup_dir / f'.env.{timestamp}'
        shutil.copy2(target, backup)
        backup.chmod(0o600)
        print(f'Backup: {backup}')

    assignment = re.compile(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=')
    kept = []
    for line in lines:
        match = assignment.match(line)
        if not match or match.group(1) not in updates:
            kept.append(line)
    content = ''.join(kept)
    if content and not content.endswith('\n'):
        content += '\n'
    content += ''.join(f'{key}={shlex.quote(value)}\n' for key, value in updates.items())
    fd, temporary = tempfile.mkstemp(prefix='.env.recovery.', dir=target.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            output.write(content)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    with (backup_dir.parent / 'CHANGELOG.md').open('a') as log:
        log.write(f'{datetime.datetime.now():%Y-%m-%d %H:%M} | {target} | '
                  'Recovered missing MCP variables from ~/.claude.json\n')
    print(f'Saved {len(updates)} variables to {target} with permissions 600.')


try:
    main()
except Exception as error:
    # Exception messages from parsers may include source contents.
    print(f'Recovery failed ({type(error).__name__}); secret values withheld.', file=sys.stderr)
    sys.exit(1)
PY
