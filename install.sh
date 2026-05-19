#!/usr/bin/env bash
set -euo pipefail

# Skills Manager for my_all_skills
# Clones repos defined in skills.yaml and creates symlinks to ~/.claude/skills/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/skills.yaml"

# --- Defaults ---
DRY_RUN=false
CLEANUP=true
LIST=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Skills Manager - clone repos and symlink skills to ~/.claude/skills/

Options:
  --dry-run   Show what would be done without making changes
  --cleanup   Remove stale managed symlinks and orphan repo clones (default)
  --no-cleanup
              Skip stale managed symlink and orphan repo cleanup
  --list      List all managed skills and their status
  -h, --help  Show this help message

Configuration: skills.yaml
EOF
    exit 0
}

# --- Parse CLI args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --cleanup)  CLEANUP=true; shift ;;
        --no-cleanup) CLEANUP=false; shift ;;
        --list)     LIST=true; shift ;;
        -h|--help)  usage ;;
        *)          echo "Unknown option: $1"; usage ;;
    esac
done

# --- Check config exists ---
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: $CONFIG_FILE not found${NC}"
    exit 1
fi

# --- Ensure PyYAML ---
ensure_pyyaml() {
    python3 -c "import yaml" 2>/dev/null && return 0
    echo -e "${YELLOW}PyYAML not found, attempting to install...${NC}"
    # Try matching pip to the active python3
    python3 -m pip install --user --break-system-packages pyyaml 2>/dev/null && return 0
    python3 -m pip install --user pyyaml 2>/dev/null && return 0
    pip3 install --user pyyaml 2>/dev/null && return 0
    echo -e "${RED}Error: Failed to install PyYAML. Install it manually:${NC}"
    echo -e "${RED}  python3 -m pip install --break-system-packages pyyaml${NC}"
    exit 1
}

ensure_pyyaml

# --- Parse config for bash (repos split by install_mode) ---
eval "$(python3 -c "
import yaml

with open('$CONFIG_FILE') as f:
    cfg = yaml.safe_load(f)

def repo_enabled(rcfg):
    value = rcfg.get('enabled', True)
    if isinstance(value, str):
        return value.strip().lower() not in ('false', 'no', 'off', '0')
    return bool(value)

def install_mode(rcfg):
    return str(rcfg.get('install_mode', 'symlink')).strip().lower()

clone_dir = cfg.get('clone_dir', '.repos')
plugin_state = cfg.get('plugin_state_file', '.plugin_state.json')
print(f'CLONE_DIR=\"{clone_dir}\"')
print(f'PLUGIN_STATE_FILE=\"{plugin_state}\"')

repos = cfg.get('repos', {})
symlink_lines = []
plugin_count = 0
for name, rcfg in repos.items():
    mode = install_mode(rcfg)
    if mode == 'plugin':
        plugin_count += 1
        continue
    url = rcfg.get('url', '')
    branch = rcfg.get('branch', 'main')
    enabled = 'true' if repo_enabled(rcfg) else 'false'
    symlink_lines.append(f'{name}|{url}|{branch}|{enabled}')
print(f'SYMLINK_REPO_ENTRIES=\"{chr(10).join(symlink_lines)}\"')
print(f'PLUGIN_REPO_COUNT={plugin_count}')
")"

CLONE_DIR_ABS="$SCRIPT_DIR/$CLONE_DIR"
PLUGIN_STATE_ABS="$SCRIPT_DIR/$PLUGIN_STATE_FILE"

# --- Phase: --list ---
if $LIST; then
    python3 - "$CONFIG_FILE" "$SCRIPT_DIR" "$CLONE_DIR_ABS" <<'PYEOF'
import yaml, os, sys

config_file, script_dir, clone_dir = sys.argv[1:4]

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

raw = cfg.get('skills_dir', '~/.claude/skills')
if isinstance(raw, str):
    raw = [raw]
skills_dirs = [os.path.expanduser(p) for p in raw]

BLUE, GREEN, YELLOW, NC = '\033[0;34m', '\033[0;32m', '\033[1;33m', '\033[0m'
print(f"{BLUE}=== Managed Skills ==={NC}")
print(f"Target skills dirs: {', '.join(skills_dirs)}\n")

def has_valid_frontmatter(skill_dir):
    skill_md = os.path.join(skill_dir, 'SKILL.md')
    if not os.path.isfile(skill_md):
        return False
    with open(skill_md, encoding='utf-8') as f:
        content = f.read()
    return content.startswith('---\n') and '\n---\n' in content[4:]

def status(skill_name, source_dir=None):
    """Return a compact per-dir link status string."""
    parts = []
    for d in skills_dirs:
        label = os.path.basename(os.path.dirname(d)) or d  # e.g. ".claude"
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

# Live state for plugin-mode display.
import json, subprocess
installed_plugin_ids = set()
try:
    out = subprocess.check_output(
        ['claude', 'plugin', 'list', '--json'], stderr=subprocess.DEVNULL
    )
    installed_plugin_ids = {p.get('id') for p in json.loads(out) if p.get('id')}
except Exception:
    pass

# Repo skills
for repo_name, rcfg in cfg.get('repos', {}).items():
    mode = str(rcfg.get('install_mode', 'symlink')).strip().lower()
    if mode == 'plugin':
        mkt = rcfg.get('marketplace', '?')
        plg = rcfg.get('plugin', '?')
        key = f"{plg}@{mkt}"
        state = 'installed' if key in installed_plugin_ids else 'pending'
        print(f"{GREEN}Repo: {repo_name} [plugin: {state}]{NC}")
        print(f"  {key}  url={rcfg.get('url', '?')}")
        print()
        continue
    enabled = repo_enabled(rcfg)
    enabled_skills = enabled_skill_names(rcfg)
    if enabled:
        label = f"Repo: {repo_name} [symlink]"
    elif enabled_skills:
        label = f"Repo: {repo_name} [symlink] (disabled, {len(enabled_skills)} enabled skill(s))"
    else:
        label = f"Repo: {repo_name} [symlink] (disabled)"
    print(f"{GREEN}{label}{NC}")
    single_skill = rcfg.get('single_skill', False)
    prefix = rcfg.get('prefix', '')
    repo_dir = os.path.join(clone_dir, repo_name)

    if not enabled and not enabled_skills:
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
        skills_path = rcfg.get('skills_path', '.')
        scan_dir = os.path.join(repo_dir, skills_path) if skills_path != '.' else repo_dir
        found = False
        if os.path.isdir(scan_dir):
            for entry in sorted(os.listdir(scan_dir)):
                skill_dir = os.path.join(scan_dir, entry)
                if os.path.isdir(skill_dir) and os.path.isfile(os.path.join(skill_dir, 'SKILL.md')):
                    skill_name = prefix + entry
                    if not enabled and entry not in enabled_skills and skill_name not in enabled_skills:
                        continue
                    found = True
                    print(f"  {skill_name} [{status(skill_name, skill_dir)}] -> {skill_dir}")
        if not found:
            print("  (no skills found)")
    print()
PYEOF
    exit 0
fi

# --- Phase 1: Clone or update symlink-mode repos ---
echo -e "${BLUE}=== Phase 1: Clone/update repos (symlink mode) ===${NC}"
mkdir -p "$CLONE_DIR_ABS"

if [[ -z "${SYMLINK_REPO_ENTRIES:-}" ]]; then
    echo "  (no symlink-mode repos configured)"
fi

IFS=$'\n'
for entry in $SYMLINK_REPO_ENTRIES; do
    repo_name="$(echo "$entry" | cut -d'|' -f1)"
    url="$(echo "$entry" | cut -d'|' -f2)"
    branch="$(echo "$entry" | cut -d'|' -f3)"
    enabled="$(echo "$entry" | cut -d'|' -f4)"
    repo_dir="$CLONE_DIR_ABS/$repo_name"
    deployment_note=""
    if [[ "$enabled" != "true" ]]; then
        deployment_note=" (symlinks disabled)"
    fi

    if [[ -d "$repo_dir/.git" ]]; then
        if ! $DRY_RUN; then
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

# --- Phase 1b: Plugin sync via `claude plugin` CLI ---
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

# Build desired state from yaml.
desired_marketplaces = {}   # mkt_name -> {'url': str, 'plugins': set()}
desired_plugins = {}        # 'plg@mkt' -> {'marketplace': str, 'plugin': str}

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

# Load previous managed state.
if os.path.isfile(state_file):
    with open(state_file) as f:
        prev_state = json.load(f)
else:
    prev_state = {'marketplaces': {}, 'plugins': {}}
prev_marketplaces = set((prev_state.get('marketplaces') or {}).keys())
prev_plugins = set((prev_state.get('plugins') or {}).keys())

# Need claude CLI for any action.
need_cli = bool(desired_marketplaces or prev_marketplaces or prev_plugins)
if need_cli and shutil.which('claude') is None:
    print(f"  {RED}Error:{NC} `claude` CLI not found in PATH. Install Claude Code first.")
    sys.exit(1)

# Live marketplace state from on-disk json (no --json flag on `marketplace list`).
known_mkt_path = os.path.expanduser('~/.claude/plugins/known_marketplaces.json')
if os.path.isfile(known_mkt_path):
    with open(known_mkt_path) as f:
        known_mkt = json.load(f)
else:
    known_mkt = {}

# Live installed-plugin set.
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

# Sync marketplaces: add new, update existing.
for mkt_name, info in desired_marketplaces.items():
    if mkt_name in known_mkt:
        run(['claude', 'plugin', 'marketplace', 'update', mkt_name],
            label='Update marketplace')
    else:
        run(['claude', 'plugin', 'marketplace', 'add', info['url']],
            label='Add marketplace')

# Sync plugins: install missing.
for key in desired_plugins:
    if key in installed_plugins:
        print(f"  {BLUE}Already installed:{NC} {key}")
    else:
        run(['claude', 'plugin', 'install', key], label='Install plugin')

# Cleanup plugins we previously managed but no longer want.
for key in sorted(prev_plugins - set(desired_plugins.keys())):
    if key in installed_plugins:
        run(['claude', 'plugin', 'uninstall', key], label='Uninstall plugin')
    else:
        print(f"  {YELLOW}Already gone:{NC} {key}")

# Cleanup marketplaces no longer referenced.
for mkt in sorted(prev_marketplaces - set(desired_marketplaces.keys())):
    if mkt in known_mkt:
        run(['claude', 'plugin', 'marketplace', 'remove', mkt],
            label='Remove marketplace')
    else:
        print(f"  {YELLOW}Already gone marketplace:{NC} {mkt}")

# Re-query reality so state reflects what actually exists, not what we asked for.
if not dry_run:
    try:
        out = subprocess.check_output(
            ['claude', 'plugin', 'list', '--json'], stderr=subprocess.DEVNULL
        )
        installed_now = {p.get('id') for p in json.loads(out) if p.get('id')}
    except Exception:
        installed_now = installed_plugins  # fall back to pre-op snapshot
    if os.path.isfile(known_mkt_path):
        with open(known_mkt_path) as f:
            known_mkt_now = json.load(f)
    else:
        known_mkt_now = {}

    new_state = {
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
        json.dump(new_state, f, indent=2, sort_keys=True)

if not ok:
    print(f"  {YELLOW}Plugin sync had errors. Continuing with symlink phases.{NC}",
          file=sys.stderr)
PYEOF
fi

# --- Phases 2-5: Discover, resolve conflicts, symlink, cleanup (all in Python) ---
python3 - "$CONFIG_FILE" "$SCRIPT_DIR" "$CLONE_DIR_ABS" "$DRY_RUN" "$CLEANUP" <<'PYEOF'
import yaml, os, sys

config_file, script_dir, clone_dir, dry_run_str, cleanup_str = sys.argv[1:6]
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

# skills_dir can be a string or a list of strings
raw = cfg.get('skills_dir', '~/.claude/skills')
if isinstance(raw, str):
    raw = [raw]
skills_dirs = [os.path.expanduser(p) for p in raw]

# Colors
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

skill_sources = {}   # skill_name -> source_path
skill_repos = {}     # skill_name -> repo_name
conflicts = {}       # skill_name -> description

for repo_name, rcfg in cfg.get('repos', {}).items():
    if str(rcfg.get('install_mode', 'symlink')).strip().lower() == 'plugin':
        continue
    enabled = repo_enabled(rcfg)
    enabled_skills = enabled_skill_names(rcfg)
    if not enabled and not enabled_skills:
        print(f"  {YELLOW}Disabled repo:{NC} {repo_name} (skipped)")
        continue
    if not enabled:
        print(f"  {YELLOW}Disabled repo:{NC} {repo_name} (installing enabled_skills only)")

    single_skill = rcfg.get('single_skill', False)
    prefix = rcfg.get('prefix', '')
    repo_dir = os.path.join(clone_dir, repo_name)

    if not os.path.isdir(repo_dir):
        if dry_run:
            print(f"  (would scan {repo_name} after cloning)")
        continue

    if single_skill:
        # Repo itself is the skill
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

    skills_path = rcfg.get('skills_path', '.')
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

# Discover local skills (override repo skills)
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
    if os.path.isdir(local_dir):
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

# --- Phase 4: Create symlinks (for each target dir) ---
print(f"{BLUE}=== Phase 4: Create symlinks ==={NC}")

for skills_dir in skills_dirs:
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

# --- Phase 5: Cleanup stale managed state ---
if cleanup:
    print(f"{BLUE}=== Phase 5: Cleanup stale managed state ==={NC}")

    for skills_dir in skills_dirs:
        print(f"  {BLUE}Target:{NC} {skills_dir}")
        removed = 0

        if os.path.isdir(skills_dir):
            for entry in sorted(os.listdir(skills_dir)):
                link = os.path.join(skills_dir, entry)
                if not os.path.islink(link):
                    continue
                target = os.readlink(link)
                target_path = resolve_link_target(link, target)
                # Only remove symlinks pointing into our project
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

    # Only symlink-mode repos own a clone under clone_dir.
    configured_repos = {
        name for name, rcfg in (cfg.get('repos') or {}).items()
        if str(rcfg.get('install_mode', 'symlink')).strip().lower() != 'plugin'
    }
    removed_repos = 0
    if os.path.isdir(clone_dir):
        print(f"  {BLUE}Clone cache:{NC} {clone_dir}")
        for entry in sorted(os.listdir(clone_dir)):
            repo_dir = os.path.join(clone_dir, entry)
            if entry in configured_repos:
                continue
            if not os.path.isdir(repo_dir):
                continue
            if not os.path.isdir(os.path.join(repo_dir, '.git')):
                continue
            print(f"    {RED}Remove orphan repo:{NC} {entry} -> {repo_dir}")
            if not dry_run:
                import shutil
                shutil.rmtree(repo_dir)
            removed_repos += 1

        if removed_repos == 0:
            print("    No orphan repo clones found")
        else:
            print(f"    Removed repos: {removed_repos}")

if dry_run:
    print(f"\n{YELLOW}(dry-run mode - no changes were made){NC}")

print(f"{GREEN}Done!{NC}")
PYEOF
