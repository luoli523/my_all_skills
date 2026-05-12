#!/usr/bin/env bash
set -euo pipefail

# Skills Manager for my_claude_skills
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

# --- Parse config for bash (repos list + clone_dir only) ---
eval "$(python3 -c "
import yaml

with open('$CONFIG_FILE') as f:
    cfg = yaml.safe_load(f)

def repo_enabled(rcfg):
    value = rcfg.get('enabled', True)
    if isinstance(value, str):
        return value.strip().lower() not in ('false', 'no', 'off', '0')
    return bool(value)

clone_dir = cfg.get('clone_dir', '.repos')
print(f'CLONE_DIR=\"{clone_dir}\"')

repos = cfg.get('repos', {})
repo_lines = []
for name, rcfg in repos.items():
    url = rcfg.get('url', '')
    branch = rcfg.get('branch', 'main')
    enabled = 'true' if repo_enabled(rcfg) else 'false'
    repo_lines.append(f'{name}|{url}|{branch}|{enabled}')
print(f'REPO_ENTRIES=\"{chr(10).join(repo_lines)}\"')
")"

CLONE_DIR_ABS="$SCRIPT_DIR/$CLONE_DIR"

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

# Repo skills
for repo_name, rcfg in cfg.get('repos', {}).items():
    enabled = repo_enabled(rcfg)
    label = f"Repo: {repo_name}" if enabled else f"Repo: {repo_name} (disabled)"
    print(f"{GREEN}{label}{NC}")
    single_skill = rcfg.get('single_skill', False)
    prefix = rcfg.get('prefix', '')
    repo_dir = os.path.join(clone_dir, repo_name)

    if not enabled:
        print("  (disabled - clone/update remains managed; symlink creation is skipped)")
        if os.path.isdir(repo_dir):
            print(f"  clone cache kept: {repo_dir}")
    elif not os.path.isdir(repo_dir):
        print("  (not cloned yet - run install first)")
    elif single_skill:
        skill_name = prefix + repo_name
        print(f"  {skill_name} [{status(skill_name, repo_dir)}] -> {repo_dir}")
    else:
        skills_path = rcfg.get('skills_path', '.')
        scan_dir = os.path.join(repo_dir, skills_path) if skills_path != '.' else repo_dir
        found = False
        if os.path.isdir(scan_dir):
            for entry in sorted(os.listdir(scan_dir)):
                skill_dir = os.path.join(scan_dir, entry)
                if os.path.isdir(skill_dir) and os.path.isfile(os.path.join(skill_dir, 'SKILL.md')):
                    found = True
                    skill_name = prefix + entry
                    print(f"  {skill_name} [{status(skill_name, skill_dir)}] -> {skill_dir}")
        if not found:
            print("  (no skills found)")
    print()
PYEOF
    exit 0
fi

# --- Phase 1: Clone or update repos ---
echo -e "${BLUE}=== Phase 1: Clone/update repos ===${NC}"
mkdir -p "$CLONE_DIR_ABS"

IFS=$'\n'
for entry in $REPO_ENTRIES; do
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
    if not repo_enabled(rcfg):
        print(f"  {YELLOW}Disabled repo:{NC} {repo_name} (skipped)")
        continue

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
            if skill_name in skill_sources:
                conflicts[skill_name] = f"{skill_repos[skill_name]} + {repo_name}"
            else:
                skill_sources[skill_name] = repo_dir
                skill_repos[skill_name] = repo_name
        continue

    skills_path = rcfg.get('skills_path', '.')
    include = rcfg.get('include', [])
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
        if include and entry not in include:
            continue

        skill_name = prefix + entry
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

    configured_repos = set(cfg.get('repos', {}).keys())
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
