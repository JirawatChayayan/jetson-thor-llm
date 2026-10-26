#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname -- "$(readlink -f -- "$0")")"
ENV_FILE=".env"
ENV_EXAMPLE=".env.example"
command -v openssl >/dev/null || { echo "ERROR: openssl is required." >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 is required." >&2; exit 1; }
[[ -f "$ENV_EXAMPLE" ]] || { echo "ERROR: $ENV_EXAMPLE not found." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || cp "$ENV_EXAMPLE" "$ENV_FILE"

python3 - <<'PY'
from pathlib import Path
import subprocess

example = Path('.env.example').read_text().splitlines()
env_path = Path('.env')
lines = env_path.read_text().splitlines()

def parse(lines):
    result = {}
    for idx, line in enumerate(lines):
        if line and not line.lstrip().startswith('#') and '=' in line:
            key, value = line.split('=', 1)
            if key.replace('_', '').isalnum():
                result[key] = (idx, value)
    return result

current = parse(lines)
for line in example:
    if not line or line.lstrip().startswith('#') or '=' not in line:
        continue
    key, default = line.split('=', 1)
    if not key.replace('_', '').isalnum():
        continue
    if key not in current:
        lines.append(line)
        current[key] = (len(lines) - 1, default)

for key, (idx, value) in list(current.items()):
    marker = next((m for m in ('REPLACE_WITH_RANDOM_SECRET', 'CHANGE_ME', 'REPLACE_ME') if m in value), None)
    if marker:
        prefix = value.split(marker, 1)[0]
        secret = subprocess.check_output(['openssl', 'rand', '-hex', '32'], text=True).strip()
        lines[idx] = f'{key}={prefix}{secret}'
        print(f'Generated secret: {key}')

env_path.write_text('\n'.join(lines) + '\n')
PY

chmod 600 "$ENV_FILE"
echo
echo "Environment file ready: $ENV_FILE"
echo "LiteLLM UI username: $(sed -n 's/^UI_USERNAME=//p' "$ENV_FILE" | tail -n 1)"
echo "LiteLLM UI password and API keys are stored in .env (not printed)."
echo
echo "Next: docker compose config"
echo "Then: docker compose up -d postgres litellm"
