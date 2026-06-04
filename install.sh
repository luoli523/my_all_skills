#!/usr/bin/env bash
set -euo pipefail

# Skills Manager for my_all_skills
# Clones repos defined in skills.yaml, then either:
#   - symlinks skills into ~/.claude/skills (claude target, symlink-mode repos)
#   - installs plugins via `claude plugin` CLI (claude target, plugin-mode repos)
#   - installs plugins via `codex plugin` CLI (codex target, plugin-mode repos)
#   - symlinks skills into ~/.codex/skills (codex target, symlink-mode repos)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/skills.yaml"

# --- Defaults ---
DRY_RUN=false
CLEANUP=true
LIST=false
TARGET=both

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Skills Manager - deploy skills to Claude Code and Codex (plugin or symlink).

Options:
  --target <t> Target: claude | codex | both (default: both)
                 claude: symlink symlink-mode repos to ~/.claude/skills +
                         install plugin-mode repos via \`claude plugin\` CLI.
                 codex:  symlink symlink-mode repos to ~/.codex/skills +
                         install plugin-mode repos via \`codex plugin\` CLI.
                 both:   run claude target then codex target.
  --dry-run    Show what would be done without making changes.
  --cleanup    Remove stale managed symlinks and orphan repo clones (default).
  --no-cleanup Skip stale managed symlink and orphan repo cleanup.
  --list       List all managed skills and their status across both targets.
  -h, --help   Show this help message.

Configuration: skills.yaml
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)     TARGET="$2"; shift 2 ;;
        --target=*)   TARGET="${1#--target=}"; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --cleanup)    CLEANUP=true; shift ;;
        --no-cleanup) CLEANUP=false; shift ;;
        --list)       LIST=true; shift ;;
        -h|--help)    usage ;;
        *)            echo "Unknown option: $1"; usage ;;
    esac
done

case "$TARGET" in
    claude|codex|both) ;;
    *) echo -e "${RED}Invalid --target: $TARGET (must be claude|codex|both)${NC}"; exit 1 ;;
esac

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: $CONFIG_FILE not found${NC}"
    exit 1
fi

ensure_pyyaml() {
    python3 -c "import yaml" 2>/dev/null && return 0
    echo -e "${YELLOW}PyYAML not found, attempting to install...${NC}"
    python3 -m pip install --user --break-system-packages pyyaml 2>/dev/null && return 0
    python3 -m pip install --user pyyaml 2>/dev/null && return 0
    pip3 install --user pyyaml 2>/dev/null && return 0
    echo -e "${RED}Error: Failed to install PyYAML. Install it manually:${NC}"
    echo -e "${RED}  python3 -m pip install --break-system-packages pyyaml${NC}"
    exit 1
}
ensure_pyyaml

# --- Parse config (clone_dir, target skills_dirs, repo entries with mode) ---
eval "$(python3 -c "
import os, yaml

with open('$CONFIG_FILE') as f:
    cfg = yaml.safe_load(f)

def repo_enabled(rcfg):
    value = rcfg.get('enabled', True)
    if isinstance(value, str):
        return value.strip().lower() not in ('false', 'no', 'off', '0')
    return bool(value)

def install_mode(rcfg):
    return str(rcfg.get('install_mode', 'symlink')).strip().lower()

print(f'CLONE_DIR=\"{cfg.get(\"clone_dir\", \".repos\")}\"')
print(f'CODEX_ADAPTER_DIR=\"{cfg.get(\"codex_adapter_dir\", \".codex-adapters\")}\"')
print(f'PLUGIN_STATE_FILE=\"{cfg.get(\"plugin_state_file\", \".plugin_state.json\")}\"')

sd = cfg.get('skills_dir') or {}
if isinstance(sd, dict):
    claude_dir = sd.get('claude', '~/.claude/skills')
    codex_dir  = sd.get('codex',  '~/.codex/skills')
elif isinstance(sd, list):
    claude_dir = sd[0] if len(sd) > 0 else '~/.claude/skills'
    codex_dir  = sd[1] if len(sd) > 1 else '~/.codex/skills'
elif isinstance(sd, str):
    claude_dir = sd
    codex_dir = sd
else:
    claude_dir, codex_dir = '~/.claude/skills', '~/.codex/skills'
print(f'CLAUDE_SKILLS_DIR=\"{os.path.expanduser(claude_dir)}\"')
print(f'CODEX_SKILLS_DIR=\"{os.path.expanduser(codex_dir)}\"')

repos = cfg.get('repos', {})
lines = []
plugin_count = 0
for name, rcfg in repos.items():
    mode = install_mode(rcfg)
    if mode == 'plugin':
        plugin_count += 1
    codex_cfg = rcfg.get('codex') or {}
    codex_mode = str(codex_cfg.get('mode', 'adapter' if mode == 'plugin' else 'symlink')).strip().lower()
    url = rcfg.get('url', '')
    branch = rcfg.get('branch', 'main')
    enabled = 'true' if repo_enabled(rcfg) else 'false'
    lines.append(f'{name}|{url}|{branch}|{enabled}|{mode}|{codex_mode}')
print(f'ALL_REPO_ENTRIES=\"{chr(10).join(lines)}\"')
print(f'PLUGIN_REPO_COUNT={plugin_count}')
")"

CLONE_DIR_ABS="$SCRIPT_DIR/$CLONE_DIR"
CODEX_ADAPTER_DIR_ABS="$SCRIPT_DIR/$CODEX_ADAPTER_DIR"
PLUGIN_STATE_ABS="$SCRIPT_DIR/$PLUGIN_STATE_FILE"

# --- Phase: --list (shows both targets in one shot) ---
if $LIST; then
    python3 - "$CONFIG_FILE" "$SCRIPT_DIR" "$CLONE_DIR_ABS" \
              "$CLAUDE_SKILLS_DIR" "$CODEX_SKILLS_DIR" "$CODEX_ADAPTER_DIR_ABS" <<'PYEOF'
import yaml, os, sys

config_file, script_dir, clone_dir, claude_dir, codex_dir, codex_adapter_dir = sys.argv[1:7]

with open(config_file) as f:
    cfg = yaml.safe_load(f)

def repo_enabled(rcfg):
    value = rcfg.get('enabled', True)
    if isinstance(value, str):
        return value.strip().lower() not in ('false', 'no', 'off', '0')
    return bool(value)

def enabled_skill_names(rcfg):
    value = rcfg.get('enabled_skills', [])
    if value is None:
        return set()
    if isinstance(value, str):
        return {value}
    return {str(item) for item in value}

skills_dirs = [claude_dir, codex_dir]

BLUE, GREEN, YELLOW, NC = '\033[0;34m', '\033[0;32m', '\033[1;33m', '\033[0m'
print(f"{BLUE}=== Managed Skills ==={NC}")
print(f"Target skills dirs: claude={claude_dir}, codex={codex_dir}\n")

def has_valid_frontmatter(skill_dir):
    skill_md = os.path.join(skill_dir, 'SKILL.md')
    if not os.path.isfile(skill_md):
        return False
    with open(skill_md, encoding='utf-8') as f:
        content = f.read()
    return content.startswith('---\n') and '\n---\n' in content[4:]

def status(skill_name, source_dir=None):
    parts = []
    for d in skills_dirs:
        label = os.path.basename(os.path.dirname(d)) or d
        link = os.path.join(d, skill_name)
        if os.path.islink(link):
            tgt = os.readlink(link)
            ok = (source_dir is None or tgt == source_dir)
            parts.append(f"{label}:{'ok' if ok else 'stale'}")
        else:
            parts.append(f"{label}:-")
    return " ".join(parts)

# Local skills
local_skills = cfg.get('local', [])
if local_skills:
    print(f"{GREEN}Local skills:{NC}")
    seen_local = set()
    for skill in local_skills:
        if skill in seen_local:
            print(f"  {skill} (duplicate entry)")
            continue
        seen_local.add(skill)
        source_dir = os.path.join(script_dir, skill)
        if os.path.isdir(source_dir) and has_valid_frontmatter(source_dir):
            print(f"  {skill} [{status(skill, source_dir)}] -> {source_dir}")
        elif os.path.isdir(source_dir):
            print(f"  {skill} (invalid SKILL.md frontmatter)")
        else:
            print(f"  {skill} (missing)")
    print()

# Live plugin install state
import json, subprocess
installed_claude_plugin_ids = set()
installed_codex_plugin_ids = set()
try:
    out = subprocess.check_output(
        ['claude', 'plugin', 'list', '--json'], stderr=subprocess.DEVNULL
    )
    installed_claude_plugin_ids = {p.get('id') for p in json.loads(out) if p.get('id')}
except Exception:
    pass
try:
    out = subprocess.check_output(
        ['codex', 'plugin', 'list', '--json'], stderr=subprocess.DEVNULL
    )
    data = json.loads(out)
    installed_codex_plugin_ids = {
        p.get('pluginId') for p in data.get('installed', []) if p.get('pluginId')
    }
except Exception:
    pass

# Repo skills
for repo_name, rcfg in cfg.get('repos', {}).items():
    mode = str(rcfg.get('install_mode', 'symlink')).strip().lower()
    enabled = repo_enabled(rcfg)
    enabled_skills = enabled_skill_names(rcfg)
    repo_dir = os.path.join(clone_dir, repo_name)
    codex_cfg = rcfg.get('codex') or {}
    codex_mode = str(codex_cfg.get('mode', 'adapter' if mode == 'plugin' else 'symlink')).strip().lower()
    single_skill = codex_cfg.get('single_skill', rcfg.get('single_skill', False))
    prefix = codex_cfg.get('prefix', rcfg.get('prefix', ''))

    if mode == 'plugin':
        mkt = rcfg.get('marketplace', '?')
        plg = rcfg.get('plugin', '?')
        claude_key = f"{plg}@{mkt}"
        claude_state = 'installed' if claude_key in installed_claude_plugin_ids else 'pending'
        codex_mkt = codex_cfg.get('marketplace', repo_name)
        codex_plg = codex_cfg.get('plugin', plg)
        codex_key = f"{codex_plg}@{codex_mkt}"
        codex_state = 'installed' if codex_key in installed_codex_plugin_ids else 'pending'
        print(f"{GREEN}Repo: {repo_name} [plugin]{NC}")
        print(f"  claude side: {claude_key} [{claude_state}]  url={rcfg.get('url', '?')}")
        if codex_mode in ('adapter', 'marketplace'):
            print(f"  codex side:  {codex_key} [{codex_state}, {codex_mode}]")
            if codex_mode == 'adapter':
                print(f"  adapter root: {os.path.join(codex_adapter_dir, str(codex_mkt))}")
            print()
            continue
        if codex_mode == 'none':
            print("  codex side:  skipped")
            print()
            continue
        if codex_mode == 'symlink':
            print("  codex side:  symlink fallback")
            enabled = True
    elif enabled:
        print(f"{GREEN}Repo: {repo_name} [symlink]{NC}")
    elif enabled_skills:
        print(f"{GREEN}Repo: {repo_name} [symlink] (disabled, {len(enabled_skills)} enabled skill(s)){NC}")
    else:
        print(f"{GREEN}Repo: {repo_name} [symlink] (disabled){NC}")

    # Codex side (or claude side for symlink mode): scan for skills
    if mode != 'plugin' and not enabled and not enabled_skills:
        print("  (disabled - clone/update remains managed; symlink creation is skipped)")
        if os.path.isdir(repo_dir):
            print(f"  clone cache kept: {repo_dir}")
    elif not os.path.isdir(repo_dir):
        print("  (not cloned yet - run install first)")
    elif single_skill:
        skill_name = prefix + repo_name
        if enabled or repo_name in enabled_skills or skill_name in enabled_skills:
            print(f"  {skill_name} [{status(skill_name, repo_dir)}] -> {repo_dir}")
        else:
            print("  (no enabled skills found)")
    else:
        skills_path = codex_cfg.get('skills_path', rcfg.get('skills_path', '.'))
        scan_dir = os.path.join(repo_dir, skills_path) if skills_path != '.' else repo_dir
        found = False
        if os.path.isdir(scan_dir):
            for entry in sorted(os.listdir(scan_dir)):
                skill_dir = os.path.join(scan_dir, entry)
                if not (os.path.isdir(skill_dir) and os.path.isfile(os.path.join(skill_dir, 'SKILL.md'))):
                    continue
                skill_name = prefix + entry
                if mode != 'plugin' and not enabled and entry not in enabled_skills and skill_name not in enabled_skills:
                    continue
                found = True
                print(f"  {skill_name} [{status(skill_name, skill_dir)}] -> {skill_dir}")
        if not found:
            print("  (no skills found)")
    print()
PYEOF
    exit 0
fi

# === run_target: run pipeline for one target (claude or codex) ===
run_target() {
    local target_name="$1"
    local skills_dir_abs
    local run_claude_plugin_sync
    local run_codex_plugin_sync

    case "$target_name" in
        claude)
            skills_dir_abs="$CLAUDE_SKILLS_DIR"
            run_claude_plugin_sync=true
            run_codex_plugin_sync=false
            ;;
        codex)
            skills_dir_abs="$CODEX_SKILLS_DIR"
            run_claude_plugin_sync=false
            run_codex_plugin_sync=true
            ;;
    esac

    echo
    echo -e "${BLUE}########## Target: $target_name (skills_dir=$skills_dir_abs) ##########${NC}"

    # --- Phase 1: Clone or update repos ---
    echo -e "${BLUE}=== Phase 1: Clone/update repos ===${NC}"
    mkdir -p "$CLONE_DIR_ABS"

    if [[ -z "${ALL_REPO_ENTRIES:-}" ]]; then
        echo "  (no repos configured)"
    fi

    IFS=$'\n'
    for entry in $ALL_REPO_ENTRIES; do
        local repo_name url branch enabled mode codex_mode repo_dir deployment_note
        repo_name="$(echo "$entry" | cut -d'|' -f1)"
        url="$(echo "$entry" | cut -d'|' -f2)"
        branch="$(echo "$entry" | cut -d'|' -f3)"
        enabled="$(echo "$entry" | cut -d'|' -f4)"
        mode="$(echo "$entry" | cut -d'|' -f5)"
        codex_mode="$(echo "$entry" | cut -d'|' -f6)"

        # Claude target: plugin-mode repos are handled by Phase 1b, not Phase 1.
        if [[ "$target_name" == "claude" && "$mode" == "plugin" ]]; then
            continue
        fi
        # Codex target: native marketplace plugins don't need the .repos clone.
        if [[ "$target_name" == "codex" && "$mode" == "plugin" && \
              ( "$codex_mode" == "marketplace" || "$codex_mode" == "none" ) ]]; then
            continue
        fi

        repo_dir="$CLONE_DIR_ABS/$repo_name"
        deployment_note=""
        if [[ "$enabled" != "true" ]]; then
            deployment_note=" (symlinks disabled)"
        fi

        if [[ -d "$repo_dir/.git" ]]; then
            if ! $DRY_RUN; then
                local local_sha remote_sha
                local_sha="$(git -C "$repo_dir" rev-parse HEAD)"
                git -C "$repo_dir" fetch origin "$branch" --quiet
                remote_sha="$(git -C "$repo_dir" rev-parse "origin/$branch")"
                if [[ "$local_sha" != "$remote_sha" ]]; then
                    echo -e "  ${GREEN}Updated${NC} $repo_name (${local_sha:0:7} -> ${remote_sha:0:7})$deployment_note"
                    git -C "$repo_dir" reset --hard "origin/$branch" --quiet
                else
                    echo -e "  ${BLUE}Up-to-date${NC} $repo_name (${local_sha:0:7})$deployment_note"
                fi
            else
                echo -e "  ${GREEN}Would update${NC} $repo_name$deployment_note"
            fi
        else
            echo -e "  ${GREEN}Cloning${NC} $repo_name...$deployment_note"
            if ! $DRY_RUN; then
                git clone --branch "$branch" --single-branch --quiet "$url" "$repo_dir"
            fi
        fi
    done
    unset IFS

    # --- Phase 1b: Plugin sync (claude target only) ---
    if $run_claude_plugin_sync; then
        if [[ "$PLUGIN_REPO_COUNT" -gt 0 || -f "$PLUGIN_STATE_ABS" ]]; then
            echo -e "${BLUE}=== Phase 1b: Plugin sync ===${NC}"
            python3 -u - "$CONFIG_FILE" "$PLUGIN_STATE_ABS" "$DRY_RUN" <<'PYEOF'
import json, os, shutil, subprocess, sys
import yaml

config_file, state_file, dry_run_str = sys.argv[1:4]
dry_run = dry_run_str == 'true'

RED, GREEN, YELLOW, BLUE, NC = (
    '\033[0;31m', '\033[0;32m', '\033[1;33m', '\033[0;34m', '\033[0m'
)

with open(config_file) as f:
    cfg = yaml.safe_load(f)

desired_marketplaces = {}
desired_plugins = {}

for repo_name, rcfg in (cfg.get('repos') or {}).items():
    mode = str(rcfg.get('install_mode', 'symlink')).strip().lower()
    if mode != 'plugin':
        continue
    mkt = rcfg.get('marketplace')
    plg = rcfg.get('plugin')
    url = rcfg.get('url')
    if not (mkt and plg and url):
        print(f"  {RED}Error:{NC} plugin repo '{repo_name}' missing url/marketplace/plugin field")
        sys.exit(1)
    desired_marketplaces.setdefault(mkt, {'url': url, 'plugins': set()})
    desired_marketplaces[mkt]['plugins'].add(plg)
    desired_plugins[f"{plg}@{mkt}"] = {'marketplace': mkt, 'plugin': plg}

if os.path.isfile(state_file):
    with open(state_file) as f:
        full_state = json.load(f)
else:
    full_state = {}
if 'claude' in full_state or 'codex' in full_state:
    full_state.setdefault('claude', {'marketplaces': {}, 'plugins': {}})
    full_state.setdefault('codex', {'marketplaces': {}, 'plugins': {}})
else:
    full_state = {
        'claude': {
            'marketplaces': full_state.get('marketplaces', {}),
            'plugins': full_state.get('plugins', {}),
        },
        'codex': {'marketplaces': {}, 'plugins': {}},
    }
prev_state = full_state['claude']
prev_marketplaces = set((prev_state.get('marketplaces') or {}).keys())
prev_plugins = set((prev_state.get('plugins') or {}).keys())

need_cli = bool(desired_marketplaces or prev_marketplaces or prev_plugins)
if need_cli and shutil.which('claude') is None:
    print(f"  {RED}Error:{NC} `claude` CLI not found in PATH. Install Claude Code first.")
    sys.exit(1)

known_mkt_path = os.path.expanduser('~/.claude/plugins/known_marketplaces.json')
if os.path.isfile(known_mkt_path):
    with open(known_mkt_path) as f:
        known_mkt = json.load(f)
else:
    known_mkt = {}

installed_plugins = set()
if need_cli:
    try:
        out = subprocess.check_output(
            ['claude', 'plugin', 'list', '--json'], stderr=subprocess.DEVNULL
        )
        installed_plugins = {p.get('id') for p in json.loads(out) if p.get('id')}
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError):
        pass

ok = True

def run(cmd, label):
    global ok
    print(f"  {GREEN}{label}:{NC} {' '.join(cmd)}")
    if dry_run:
        return True
    rc = subprocess.call(cmd)
    if rc != 0:
        print(f"  {RED}Command failed (rc={rc}):{NC} {' '.join(cmd)}")
        ok = False
        return False
    return True

for mkt_name, info in desired_marketplaces.items():
    if mkt_name in known_mkt:
        run(['claude', 'plugin', 'marketplace', 'update', mkt_name], label='Update marketplace')
    else:
        run(['claude', 'plugin', 'marketplace', 'add', info['url']], label='Add marketplace')

for key in desired_plugins:
    if key in installed_plugins:
        run(['claude', 'plugin', 'update', key], label='Update plugin')
    else:
        run(['claude', 'plugin', 'install', key], label='Install plugin')

for key in sorted(prev_plugins - set(desired_plugins.keys())):
    if key in installed_plugins:
        run(['claude', 'plugin', 'uninstall', key], label='Uninstall plugin')
    else:
        print(f"  {YELLOW}Already gone:{NC} {key}")

for mkt in sorted(prev_marketplaces - set(desired_marketplaces.keys())):
    if mkt in known_mkt:
        run(['claude', 'plugin', 'marketplace', 'remove', mkt], label='Remove marketplace')
    else:
        print(f"  {YELLOW}Already gone marketplace:{NC} {mkt}")

if not dry_run:
    try:
        out = subprocess.check_output(
            ['claude', 'plugin', 'list', '--json'], stderr=subprocess.DEVNULL
        )
        installed_now = {p.get('id') for p in json.loads(out) if p.get('id')}
    except Exception:
        installed_now = installed_plugins
    if os.path.isfile(known_mkt_path):
        with open(known_mkt_path) as f:
            known_mkt_now = json.load(f)
    else:
        known_mkt_now = {}

    full_state['claude'] = {
        'marketplaces': {
            m: {'url': info['url']}
            for m, info in desired_marketplaces.items()
            if m in known_mkt_now
        },
        'plugins': {
            k: v for k, v in desired_plugins.items() if k in installed_now
        },
    }
    with open(state_file, 'w') as f:
        json.dump(full_state, f, indent=2, sort_keys=True)

if not ok:
    print(f"  {YELLOW}Plugin sync had errors. Continuing with symlink phases.{NC}",
          file=sys.stderr)
PYEOF
        fi
    fi

    # --- Phase 1c: Codex plugin sync (codex target only) ---
    if $run_codex_plugin_sync; then
        if [[ "$PLUGIN_REPO_COUNT" -gt 0 || -f "$PLUGIN_STATE_ABS" ]]; then
            echo -e "${BLUE}=== Phase 1c: Codex plugin sync ===${NC}"
            python3 -u - "$CONFIG_FILE" "$PLUGIN_STATE_ABS" "$DRY_RUN" \
                      "$SCRIPT_DIR" "$CLONE_DIR_ABS" "$CODEX_ADAPTER_DIR_ABS" <<'PYEOF'
import json, os, shutil, subprocess, sys
import yaml

config_file, state_file, dry_run_str, script_dir, clone_dir, adapter_dir = sys.argv[1:7]
dry_run = dry_run_str == 'true'

RED, GREEN, YELLOW, BLUE, NC = (
    '\033[0;31m', '\033[0;32m', '\033[1;33m', '\033[0;34m', '\033[0m'
)

with open(config_file) as f:
    cfg = yaml.safe_load(f)

def repo_enabled(rcfg):
    value = rcfg.get('enabled', True)
    if isinstance(value, str):
        return value.strip().lower() not in ('false', 'no', 'off', '0')
    return bool(value)

def enabled_skill_names(rcfg):
    value = rcfg.get('enabled_skills', [])
    if value is None:
        return set()
    if isinstance(value, str):
        return {value}
    return {str(item) for item in value}

def compact_description(text, fallback):
    text = str(text or '').strip()
    if not text:
        return fallback
    return ' '.join(text.split())

def run(cmd, label):
    print(f"  {GREEN}{label}:{NC} {' '.join(cmd)}")
    if dry_run:
        return True
    rc = subprocess.call(cmd)
    if rc != 0:
        print(f"  {RED}Command failed (rc={rc}):{NC} {' '.join(cmd)}")
        return False
    return True

def read_json_command(cmd, default):
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True)
    except Exception:
        return default
    text = out.strip()
    if not text:
        return default
    start = min([idx for idx in (text.find('{'), text.find('[')) if idx >= 0], default=-1)
    if start > 0:
        text = text[start:]
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return default

def codex_marketplaces():
    try:
        out = subprocess.check_output(
            ['codex', 'plugin', 'marketplace', 'list'],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception:
        return {}
    result = {}
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith('WARNING:') or line.startswith('MARKETPLACE'):
            continue
        parts = line.split(None, 1)
        if len(parts) == 2:
            result[parts[0]] = parts[1]
    return result

def installed_codex_plugins():
    data = read_json_command(['codex', 'plugin', 'list', '--json'], {'installed': []})
    return {
        p.get('pluginId')
        for p in data.get('installed', [])
        if p.get('pluginId')
    }

def rewrite_skill_name(skill_dir, skill_name):
    skill_md = os.path.join(skill_dir, 'SKILL.md')
    try:
        with open(skill_md, encoding='utf-8') as f:
            content = f.read()
    except OSError:
        return
    if not content.startswith('---\n'):
        return
    end = content.find('\n---\n', 4)
    if end == -1:
        return
    frontmatter = content[4:end]
    rest = content[end:]
    lines = frontmatter.splitlines()
    replaced = False
    for idx, line in enumerate(lines):
        if line.startswith('name:'):
            lines[idx] = f'name: {skill_name}'
            replaced = True
            break
    if not replaced:
        lines.insert(0, f'name: {skill_name}')
    with open(skill_md, 'w', encoding='utf-8') as f:
        f.write('---\n' + '\n'.join(lines) + rest)

def discover_adapter_skills(repo_name, rcfg, codex_cfg):
    repo_dir = os.path.join(clone_dir, repo_name)
    enabled = repo_enabled(rcfg)
    enabled_skills = enabled_skill_names(rcfg)
    prefix = str(codex_cfg.get('prefix', rcfg.get('prefix', '')))
    single_skill = codex_cfg.get('single_skill', rcfg.get('single_skill', False))

    if single_skill:
        if not os.path.isfile(os.path.join(repo_dir, 'SKILL.md')):
            return []
        skill_name = prefix + repo_name
        if not enabled and repo_name not in enabled_skills and skill_name not in enabled_skills:
            return []
        return [(skill_name, repo_dir)]

    skills_path = str(codex_cfg.get('skills_path', rcfg.get('skills_path', '.')))
    scan_dir = repo_dir if skills_path == '.' else os.path.join(repo_dir, skills_path)
    if not os.path.isdir(scan_dir):
        return []

    skills = []
    for entry in sorted(os.listdir(scan_dir)):
        skill_dir = os.path.join(scan_dir, entry)
        if not os.path.isdir(skill_dir):
            continue
        if not os.path.isfile(os.path.join(skill_dir, 'SKILL.md')):
            continue
        skill_name = prefix + entry
        if not enabled and entry not in enabled_skills and skill_name not in enabled_skills:
            continue
        skills.append((skill_name, skill_dir))
    return skills

def build_adapter(repo_name, rcfg, codex_cfg, marketplace, plugin):
    adapter_root = os.path.join(adapter_dir, marketplace)
    plugins_dir = os.path.join(adapter_root, 'plugins')
    plugin_root = os.path.join(plugins_dir, plugin)
    skills_root = os.path.join(plugin_root, 'skills')
    marketplace_dir = os.path.join(adapter_root, '.agents', 'plugins')
    marketplace_json = os.path.join(marketplace_dir, 'marketplace.json')

    skills = discover_adapter_skills(repo_name, rcfg, codex_cfg)
    if not skills:
        if dry_run:
            print(f"  {YELLOW}Would generate adapter:{NC} {plugin}@{marketplace} after clone")
            return adapter_root
        print(f"  {RED}Error:{NC} no skills found for adapter repo '{repo_name}'")
        return None

    description = compact_description(
        codex_cfg.get('description', rcfg.get('description')),
        f'Codex adapter for {repo_name}',
    )
    display_name = str(codex_cfg.get('display_name', plugin))
    category = str(codex_cfg.get('category', 'Productivity'))
    version = str(codex_cfg.get('version', '0.1.0'))

    print(f"  {GREEN}Generate adapter:{NC} {plugin}@{marketplace} ({len(skills)} skills)")
    if dry_run:
        return adapter_root

    if os.path.isdir(plugins_dir):
        shutil.rmtree(plugins_dir)
    os.makedirs(skills_root, exist_ok=True)
    os.makedirs(os.path.join(plugin_root, '.codex-plugin'), exist_ok=True)
    os.makedirs(marketplace_dir, exist_ok=True)

    for skill_name, source_dir in skills:
        dest_dir = os.path.join(skills_root, skill_name)
        shutil.copytree(source_dir, dest_dir, symlinks=True)
        rewrite_skill_name(dest_dir, skill_name)

    plugin_json = {
        'name': plugin,
        'version': version,
        'description': description,
        'skills': './skills/',
        'interface': {
            'displayName': display_name,
            'shortDescription': description[:128],
            'longDescription': description,
            'developerName': str(codex_cfg.get('developer_name', 'my_all_skills')),
            'category': category,
            'capabilities': codex_cfg.get('capabilities', ['Write']),
        },
    }
    with open(os.path.join(plugin_root, '.codex-plugin', 'plugin.json'), 'w', encoding='utf-8') as f:
        json.dump(plugin_json, f, indent=2, ensure_ascii=False)
        f.write('\n')

    marketplace_data = {
        'name': marketplace,
        'interface': {
            'displayName': str(codex_cfg.get('marketplace_display_name', marketplace)),
        },
        'plugins': [
            {
                'name': plugin,
                'source': {
                    'source': 'local',
                    'path': f'./plugins/{plugin}',
                },
                'policy': {
                    'installation': str(codex_cfg.get('install_policy', 'AVAILABLE')),
                    'authentication': str(codex_cfg.get('auth_policy', 'ON_INSTALL')),
                },
                'category': category,
            }
        ],
    }
    with open(marketplace_json, 'w', encoding='utf-8') as f:
        json.dump(marketplace_data, f, indent=2, ensure_ascii=False)
        f.write('\n')

    return adapter_root

if os.path.isfile(state_file):
    with open(state_file) as f:
        full_state = json.load(f)
else:
    full_state = {}
if 'claude' in full_state or 'codex' in full_state:
    full_state.setdefault('claude', {'marketplaces': {}, 'plugins': {}})
    full_state.setdefault('codex', {'marketplaces': {}, 'plugins': {}})
else:
    full_state = {
        'claude': {
            'marketplaces': full_state.get('marketplaces', {}),
            'plugins': full_state.get('plugins', {}),
        },
        'codex': {'marketplaces': {}, 'plugins': {}},
    }
prev_state = full_state['codex']
prev_marketplaces = set((prev_state.get('marketplaces') or {}).keys())
prev_plugins = set((prev_state.get('plugins') or {}).keys())

desired_marketplaces = {}
desired_plugins = {}
ok = True

for repo_name, rcfg in (cfg.get('repos') or {}).items():
    mode = str(rcfg.get('install_mode', 'symlink')).strip().lower()
    if mode != 'plugin':
        continue

    codex_cfg = rcfg.get('codex') or {}
    if not codex_cfg:
        print(f"  {YELLOW}Warning:{NC} plugin repo '{repo_name}' missing codex config; using adapter mode")
    codex_mode = str(codex_cfg.get('mode', 'adapter')).strip().lower()
    if codex_mode == 'none' or codex_mode == 'symlink':
        continue
    if codex_mode not in ('adapter', 'marketplace'):
        print(f"  {RED}Error:{NC} plugin repo '{repo_name}' has invalid codex.mode '{codex_mode}'")
        ok = False
        continue

    marketplace = str(codex_cfg.get('marketplace', repo_name))
    plugin = str(codex_cfg.get('plugin', rcfg.get('plugin', repo_name)))

    if codex_mode == 'adapter':
        source = build_adapter(repo_name, rcfg, codex_cfg, marketplace, plugin)
        if not source:
            ok = False
            continue
        source_type = 'local'
    else:
        source = str(codex_cfg.get('source', rcfg.get('url', '')))
        if not source:
            print(f"  {RED}Error:{NC} marketplace repo '{repo_name}' missing codex.source/url")
            ok = False
            continue
        source_type = 'git'

    desired_marketplaces[marketplace] = {
        'source': source,
        'mode': codex_mode,
        'source_type': source_type,
        'repo': repo_name,
        'ref': codex_cfg.get('ref', rcfg.get('branch')),
        'sparse': codex_cfg.get('sparse', []),
    }
    desired_plugins[f'{plugin}@{marketplace}'] = {
        'marketplace': marketplace,
        'plugin': plugin,
        'mode': codex_mode,
    }

need_cli = bool(desired_marketplaces or prev_marketplaces or prev_plugins)
if need_cli and shutil.which('codex') is None:
    print(f"  {RED}Error:{NC} `codex` CLI not found in PATH. Install Codex first.")
    sys.exit(1)

known_marketplaces = codex_marketplaces() if need_cli else {}
installed_plugins = installed_codex_plugins() if need_cli else set()

for marketplace, info in desired_marketplaces.items():
    source = info['source']
    mode = info['mode']
    if marketplace in known_marketplaces:
        root = os.path.abspath(os.path.expanduser(known_marketplaces[marketplace]))
        if mode == 'adapter' and root != os.path.abspath(source):
            print(
                f"  {YELLOW}Warning:{NC} marketplace '{marketplace}' already points to {root}, "
                f"expected {os.path.abspath(source)}"
            )
        if mode == 'marketplace':
            ok = run(['codex', 'plugin', 'marketplace', 'upgrade', marketplace],
                     label='Upgrade Codex marketplace') and ok
        else:
            print(f"  {BLUE}Codex marketplace present:{NC} {marketplace}")
        continue

    cmd = ['codex', 'plugin', 'marketplace', 'add', source]
    if mode == 'marketplace' and info.get('ref'):
        cmd.extend(['--ref', str(info['ref'])])
    sparse = info.get('sparse') or []
    if isinstance(sparse, str):
        sparse = [sparse]
    for path in sparse:
        cmd.extend(['--sparse', str(path)])
    ok = run(cmd, label='Add Codex marketplace') and ok

for key in desired_plugins:
    if key in installed_plugins:
        print(f"  {BLUE}Codex plugin installed:{NC} {key}")
    else:
        ok = run(['codex', 'plugin', 'add', key], label='Install Codex plugin') and ok

for key in sorted(prev_plugins - set(desired_plugins.keys())):
    if key in installed_plugins:
        ok = run(['codex', 'plugin', 'remove', key], label='Remove Codex plugin') and ok
    else:
        print(f"  {YELLOW}Already gone Codex plugin:{NC} {key}")

for marketplace in sorted(prev_marketplaces - set(desired_marketplaces.keys())):
    if marketplace in known_marketplaces:
        ok = run(['codex', 'plugin', 'marketplace', 'remove', marketplace],
                 label='Remove Codex marketplace') and ok
    else:
        print(f"  {YELLOW}Already gone Codex marketplace:{NC} {marketplace}")

if not dry_run:
    known_now = codex_marketplaces()
    installed_now = installed_codex_plugins()
    full_state['codex'] = {
        'marketplaces': {
            m: {
                'source': info['source'],
                'mode': info['mode'],
                'source_type': info['source_type'],
            }
            for m, info in desired_marketplaces.items()
            if m in known_now
        },
        'plugins': {
            k: v for k, v in desired_plugins.items() if k in installed_now
        },
    }
    with open(state_file, 'w') as f:
        json.dump(full_state, f, indent=2, sort_keys=True)

if not ok:
    print(f"  {YELLOW}Codex plugin sync had errors. Continuing with symlink phases.{NC}",
          file=sys.stderr)
PYEOF
        fi
    fi

    # --- Phases 2-4 + per-target symlink cleanup ---
    python3 - "$CONFIG_FILE" "$SCRIPT_DIR" "$CLONE_DIR_ABS" "$DRY_RUN" "$CLEANUP" \
              "$skills_dir_abs" "$target_name" <<'PYEOF'
import yaml, os, sys

config_file, script_dir, clone_dir, dry_run_str, cleanup_str, skills_dir, target_name = sys.argv[1:8]
dry_run = dry_run_str == "true"
cleanup = cleanup_str == "true"

with open(config_file) as f:
    cfg = yaml.safe_load(f)

def repo_enabled(rcfg):
    value = rcfg.get('enabled', True)
    if isinstance(value, str):
        return value.strip().lower() not in ('false', 'no', 'off', '0')
    return bool(value)

def enabled_skill_names(rcfg):
    value = rcfg.get('enabled_skills', [])
    if value is None:
        return set()
    if isinstance(value, str):
        return {value}
    return {str(item) for item in value}

RED, GREEN, YELLOW, BLUE, NC = (
    '\033[0;31m', '\033[0;32m', '\033[1;33m', '\033[0;34m', '\033[0m'
)

def has_valid_frontmatter(skill_dir):
    skill_md = os.path.join(skill_dir, 'SKILL.md')
    if not os.path.isfile(skill_md):
        return False
    with open(skill_md, encoding='utf-8') as f:
        content = f.read()
    return content.startswith('---\n') and '\n---\n' in content[4:]

def resolve_link_target(link, target):
    if os.path.isabs(target):
        return os.path.abspath(target)
    return os.path.abspath(os.path.join(os.path.dirname(link), target))

def is_under(path, root):
    path = os.path.abspath(path)
    root = os.path.abspath(root)
    try:
        return os.path.commonpath([path, root]) == root
    except ValueError:
        return False

# --- Phase 2: Discover skills ---
print(f"{BLUE}=== Phase 2: Discover skills ==={NC}")

skill_sources = {}
skill_repos = {}
conflicts = {}

for repo_name, rcfg in cfg.get('repos', {}).items():
    mode = str(rcfg.get('install_mode', 'symlink')).strip().lower()
    codex_cfg = rcfg.get('codex') or {}
    codex_mode = str(codex_cfg.get('mode', 'adapter' if mode == 'plugin' else 'symlink')).strip().lower()
    if mode == 'plugin':
        if target_name == 'claude':
            continue
        if codex_mode != 'symlink':
            continue
    enabled = repo_enabled(rcfg)
    enabled_skills = enabled_skill_names(rcfg)
    # Explicit Codex plugin symlink fallback keeps the old "install all" behavior.
    if mode == 'plugin':
        enabled = True
    if not enabled and not enabled_skills:
        print(f"  {YELLOW}Disabled repo:{NC} {repo_name} (skipped)")
        continue
    if not enabled:
        print(f"  {YELLOW}Disabled repo:{NC} {repo_name} (installing enabled_skills only)")

    single_skill = codex_cfg.get('single_skill', rcfg.get('single_skill', False))
    prefix = codex_cfg.get('prefix', rcfg.get('prefix', ''))
    repo_dir = os.path.join(clone_dir, repo_name)

    if not os.path.isdir(repo_dir):
        if dry_run:
            print(f"  (would scan {repo_name} after cloning)")
        continue

    if single_skill:
        if os.path.isfile(os.path.join(repo_dir, 'SKILL.md')):
            skill_name = prefix + repo_name
            if not enabled and repo_name not in enabled_skills and skill_name not in enabled_skills:
                continue
            if skill_name in skill_sources:
                conflicts[skill_name] = f"{skill_repos[skill_name]} + {repo_name}"
            else:
                skill_sources[skill_name] = repo_dir
                skill_repos[skill_name] = repo_name
        continue

    skills_path = codex_cfg.get('skills_path', rcfg.get('skills_path', '.'))
    scan_dir = repo_dir
    if skills_path != '.':
        scan_dir = os.path.join(scan_dir, skills_path)

    if not os.path.isdir(scan_dir):
        continue

    for entry in sorted(os.listdir(scan_dir)):
        skill_dir = os.path.join(scan_dir, entry)
        if not os.path.isdir(skill_dir):
            continue
        if not os.path.isfile(os.path.join(skill_dir, 'SKILL.md')):
            continue

        skill_name = prefix + entry
        if not enabled and entry not in enabled_skills and skill_name not in enabled_skills:
            continue
        if skill_name in skill_sources:
            conflicts[skill_name] = f"{skill_repos[skill_name]} + {repo_name}"
        else:
            skill_sources[skill_name] = skill_dir
            skill_repos[skill_name] = repo_name

# Local skills override
seen_local = set()
for skill in cfg.get('local', []):
    if skill in seen_local:
        print(f"  {YELLOW}Warning:{NC} duplicate local skill '{skill}' skipped")
        continue
    seen_local.add(skill)
    local_dir = os.path.join(script_dir, skill)
    if not os.path.isdir(local_dir):
        print(f"  {YELLOW}Warning:{NC} local skill '{skill}' directory not found")
        continue
    if not os.path.isfile(os.path.join(local_dir, 'SKILL.md')):
        print(f"  {YELLOW}Warning:{NC} local skill '{skill}' is missing SKILL.md")
        continue
    if not has_valid_frontmatter(local_dir):
        print(f"  {YELLOW}Warning:{NC} local skill '{skill}' has invalid YAML frontmatter")
        continue
    if skill in skill_sources:
        print(f"  {YELLOW}Local override:{NC} {skill} (replaces {skill_repos[skill]})")
    skill_sources[skill] = local_dir
    skill_repos[skill] = 'local'
    conflicts.pop(skill, None)

# --- Phase 3: Conflict detection ---
if conflicts:
    print(f"{BLUE}=== Phase 3: Conflict detection ==={NC}")
    for skill, desc in sorted(conflicts.items()):
        print(f"  {RED}Conflict:{NC} '{skill}' found in {desc} - skipping both")
        skill_sources.pop(skill, None)
        skill_repos.pop(skill, None)

print(f"  Found {len(skill_sources)} skills to install")

# --- Phase 4: Create symlinks into the single target skills_dir ---
print(f"{BLUE}=== Phase 4: Create symlinks ==={NC}")
print(f"  {BLUE}Target:{NC} {skills_dir}")
os.makedirs(skills_dir, exist_ok=True)

created = updated = skipped = 0
for skill in sorted(skill_sources):
    source_dir = skill_sources[skill]
    link = os.path.join(skills_dir, skill)

    if os.path.exists(link) and not os.path.islink(link):
        print(f"    {YELLOW}Skip:{NC} {skill} (target exists and is not a symlink)")
        skipped += 1
        continue

    if os.path.islink(link):
        current_target = os.readlink(link)
        if current_target == source_dir:
            skipped += 1
            continue
        print(f"    {GREEN}Update:{NC} {skill} -> {source_dir}")
        if not dry_run:
            os.remove(link)
            os.symlink(source_dir, link)
        updated += 1
    else:
        print(f"    {GREEN}Link:{NC} {skill} -> {source_dir}")
        if not dry_run:
            os.symlink(source_dir, link)
        created += 1

print(f"    Created: {created}, Updated: {updated}, Unchanged: {skipped}")

# --- Phase 5a: Stale symlink cleanup in this target's skills_dir ---
if cleanup:
    print(f"{BLUE}=== Phase 5a: Stale symlink cleanup ==={NC}")
    print(f"  {BLUE}Target:{NC} {skills_dir}")
    removed = 0
    if os.path.isdir(skills_dir):
        for entry in sorted(os.listdir(skills_dir)):
            link = os.path.join(skills_dir, entry)
            if not os.path.islink(link):
                continue
            target = os.readlink(link)
            target_path = resolve_link_target(link, target)
            if is_under(target_path, clone_dir) or is_under(target_path, script_dir):
                if entry not in skill_sources:
                    print(f"    {RED}Remove stale:{NC} {entry} -> {target}")
                    if not dry_run:
                        os.remove(link)
                    removed += 1
    if removed == 0:
        print("    No stale symlinks found")
    else:
        print(f"    Removed: {removed}")
PYEOF
}

# --- Run targets in order ---
case "$TARGET" in
    claude) TARGETS=(claude) ;;
    codex)  TARGETS=(codex)  ;;
    both)   TARGETS=(claude codex) ;;
esac

for t in "${TARGETS[@]}"; do
    run_target "$t"
done

# --- Phase 5b: Clone cache cleanup (after all targets, once) ---
if $CLEANUP; then
    echo
    echo -e "${BLUE}########## Phase 5b: Clone cache cleanup ##########${NC}"
    python3 - "$CONFIG_FILE" "$CLONE_DIR_ABS" "$DRY_RUN" "$TARGET" <<'PYEOF'
import yaml, os, sys, shutil

config_file, clone_dir, dry_run_str, target = sys.argv[1:5]
dry_run = dry_run_str == "true"

with open(config_file) as f:
    cfg = yaml.safe_load(f)

repos = cfg.get('repos') or {}

def needs_clone_for_codex(rcfg):
    mode = str(rcfg.get('install_mode', 'symlink')).strip().lower()
    if mode != 'plugin':
        return True
    codex_cfg = rcfg.get('codex') or {}
    codex_mode = str(codex_cfg.get('mode', 'adapter')).strip().lower()
    return codex_mode in ('adapter', 'symlink')

# Configured set depends on which targets ran:
#   - codex or both: keep symlink repos plus plugin repos that need adapter/symlink clone cache.
#   - claude only:   plugin-mode repos should not have a .repos clone (they
#                    aren't used in claude-only mode); only symlink-mode repos are kept.
if target in ('codex', 'both'):
    configured = {
        name for name, rcfg in repos.items()
        if needs_clone_for_codex(rcfg)
    }
else:  # claude
    configured = {
        name for name, rcfg in repos.items()
        if str(rcfg.get('install_mode', 'symlink')).strip().lower() != 'plugin'
    }

removed = 0
RED, GREEN, BLUE, NC = '\033[0;31m', '\033[0;32m', '\033[0;34m', '\033[0m'
print(f"  {BLUE}Clone cache:{NC} {clone_dir}")
if os.path.isdir(clone_dir):
    for entry in sorted(os.listdir(clone_dir)):
        repo_dir = os.path.join(clone_dir, entry)
        if entry in configured:
            continue
        if not os.path.isdir(repo_dir):
            continue
        if not os.path.isdir(os.path.join(repo_dir, '.git')):
            continue
        print(f"    {RED}Remove orphan repo:{NC} {entry} -> {repo_dir}")
        if not dry_run:
            shutil.rmtree(repo_dir)
        removed += 1

if removed == 0:
    print("    No orphan repo clones found")
else:
    print(f"    Removed repos: {removed}")
PYEOF
fi

if $DRY_RUN; then
    echo -e "\n${YELLOW}(dry-run mode - no changes were made)${NC}"
fi
echo -e "${GREEN}Done!${NC}"
