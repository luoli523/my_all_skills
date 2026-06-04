#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

make_skill_repo() {
    local repo_dir="$1"
    local skill_name="$2"

    mkdir -p "$repo_dir/skills/$skill_name"
    cat >"$repo_dir/skills/$skill_name/SKILL.md" <<EOF
---
name: $skill_name
description: Test skill
---

# $skill_name
EOF
    git -C "$repo_dir" init --initial-branch=main --quiet
    git -C "$repo_dir" add .
    git -C "$repo_dir" -c user.name="Test User" -c user.email="test@example.com" commit --quiet -m "add $skill_name"
}

make_multi_skill_repo() {
    local repo_dir="$1"
    shift

    for skill_name in "$@"; do
        mkdir -p "$repo_dir/skills/$skill_name"
        cat >"$repo_dir/skills/$skill_name/SKILL.md" <<EOF
---
name: $skill_name
description: Test skill
---

# $skill_name
EOF
    done
    git -C "$repo_dir" init --initial-branch=main --quiet
    git -C "$repo_dir" add .
    git -C "$repo_dir" -c user.name="Test User" -c user.email="test@example.com" commit --quiet -m "add test skills"
}

write_config() {
    local project_dir="$1"
    local skills_dir="$2"
    local enabled_remote="$3"
    local disabled_remote="$4"

    cat >"$project_dir/skills.yaml" <<EOF
clone_dir: .repos
skills_dir: $skills_dir
repos:
  enabled-repo:
    url: $enabled_remote
    branch: main
    skills_path: skills
  disabled-repo:
    enabled: false
    url: $disabled_remote
    branch: main
    skills_path: skills
local: []
EOF
}

assert_exists() {
    if [[ ! -e "$1" ]]; then
        echo "Expected path to exist: $1" >&2
        exit 1
    fi
}

assert_not_exists() {
    if [[ -e "$1" || -L "$1" ]]; then
        echo "Expected path to be absent: $1" >&2
        exit 1
    fi
}

run_install_in_project() {
    local project_dir="$1"
    shift || true
    cp "$ROOT_DIR/install.sh" "$project_dir/install.sh"
    bash "$project_dir/install.sh" "$@" >"$project_dir/install.log"
}

make_fake_codex() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    cat >"$bin_dir/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_CODEX_LOG:?}"

if [[ "${1:-}" == "plugin" && "${2:-}" == "marketplace" && "${3:-}" == "list" ]]; then
    printf 'MARKETPLACE             ROOT\n'
    exit 0
fi

if [[ "${1:-}" == "plugin" && "${2:-}" == "list" ]]; then
    printf '{"installed":[],"available":[]}\n'
    exit 0
fi

exit 0
EOF
    chmod +x "$bin_dir/codex"
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"

    if ! grep -Fq "$pattern" "$file"; then
        echo "Expected $file to contain: $pattern" >&2
        exit 1
    fi
}

commit_skill_change() {
    local repo_dir="$1"
    local skill_name="$2"
    local message="$3"

    printf '\n%s\n' "$message" >>"$repo_dir/skills/$skill_name/SKILL.md"
    git -C "$repo_dir" add .
    git -C "$repo_dir" -c user.name="Test User" -c user.email="test@example.com" commit --quiet -m "$message"
}

assert_git_head() {
    local repo_dir="$1"
    local expected_sha="$2"
    local actual_sha

    actual_sha="$(git -C "$repo_dir" rev-parse HEAD)"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        echo "Expected $repo_dir HEAD to be $expected_sha but got $actual_sha" >&2
        exit 1
    fi
}

test_disabled_repo_is_cloned_but_not_linked() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local project_dir="$tmp/project"
    local skills_dir="$tmp/skills"
    mkdir -p "$project_dir" "$skills_dir" "$tmp/remotes/enabled" "$tmp/remotes/disabled"

    make_skill_repo "$tmp/remotes/enabled" "enabled-skill"
    make_skill_repo "$tmp/remotes/disabled" "disabled-skill"
    write_config "$project_dir" "$skills_dir" "$tmp/remotes/enabled" "$tmp/remotes/disabled"

    run_install_in_project "$project_dir"

    assert_exists "$project_dir/.repos/enabled-repo/.git"
    assert_exists "$skills_dir/enabled-skill"
    assert_exists "$project_dir/.repos/disabled-repo/.git"
    assert_not_exists "$skills_dir/disabled-skill"
}

test_disabled_repo_updates_clone_but_removes_stale_link() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local project_dir="$tmp/project"
    local skills_dir="$tmp/skills"
    mkdir -p "$project_dir/.repos" "$skills_dir" "$tmp/remotes/enabled" "$tmp/remotes/disabled"

    make_skill_repo "$tmp/remotes/enabled" "enabled-skill"
    make_skill_repo "$tmp/remotes/disabled" "disabled-skill"
    write_config "$project_dir" "$skills_dir" "$tmp/remotes/enabled" "$tmp/remotes/disabled"

    git clone --quiet "$tmp/remotes/disabled" "$project_dir/.repos/disabled-repo"
    ln -s "$project_dir/.repos/disabled-repo/skills/disabled-skill" "$skills_dir/disabled-skill"
    commit_skill_change "$tmp/remotes/disabled" "disabled-skill" "update disabled skill"
    local remote_sha
    remote_sha="$(git -C "$tmp/remotes/disabled" rev-parse HEAD)"

    run_install_in_project "$project_dir"

    assert_exists "$project_dir/.repos/disabled-repo/.git"
    assert_git_head "$project_dir/.repos/disabled-repo" "$remote_sha"
    assert_not_exists "$skills_dir/disabled-skill"
}

test_disabled_repo_installs_enabled_skills_only() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local project_dir="$tmp/project"
    local skills_dir="$tmp/skills"
    mkdir -p "$project_dir" "$skills_dir" "$tmp/remotes/disabled"

    make_multi_skill_repo "$tmp/remotes/disabled" "alpha" "beta" "gamma"

    cat >"$project_dir/skills.yaml" <<EOF
clone_dir: .repos
skills_dir: $skills_dir
repos:
  disabled-repo:
    enabled: false
    url: $tmp/remotes/disabled
    branch: main
    skills_path: skills
    enabled_skills:
      - alpha
      - gamma
local: []
EOF

    run_install_in_project "$project_dir"

    assert_exists "$project_dir/.repos/disabled-repo/.git"
    assert_exists "$skills_dir/alpha"
    assert_not_exists "$skills_dir/beta"
    assert_exists "$skills_dir/gamma"
}

test_enabled_repo_installs_all_skills_even_with_filters() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local project_dir="$tmp/project"
    local skills_dir="$tmp/skills"
    mkdir -p "$project_dir" "$skills_dir" "$tmp/remotes/enabled"

    make_multi_skill_repo "$tmp/remotes/enabled" "alpha" "beta" "gamma"

    cat >"$project_dir/skills.yaml" <<EOF
clone_dir: .repos
skills_dir: $skills_dir
repos:
  enabled-repo:
    enabled: true
    url: $tmp/remotes/enabled
    branch: main
    skills_path: skills
    include:
      - alpha
    enabled_skills:
      - alpha
local: []
EOF

    run_install_in_project "$project_dir"

    assert_exists "$skills_dir/alpha"
    assert_exists "$skills_dir/beta"
    assert_exists "$skills_dir/gamma"
}

test_codex_adapter_generates_marketplace_plugin() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local project_dir="$tmp/project"
    local skills_dir="$tmp/skills"
    local fake_bin="$tmp/bin"
    local codex_log="$tmp/codex.log"
    mkdir -p "$project_dir" "$skills_dir" "$tmp/remotes/adapter"

    make_multi_skill_repo "$tmp/remotes/adapter" "alpha" "beta"
    make_fake_codex "$fake_bin"

    cat >"$project_dir/skills.yaml" <<EOF
clone_dir: .repos
codex_adapter_dir: .codex-adapters
plugin_state_file: .plugin_state.json
skills_dir:
  claude: $tmp/claude-skills
  codex: $skills_dir
repos:
  adapter-repo:
    install_mode: plugin
    url: $tmp/remotes/adapter
    branch: main
    marketplace: claude-marketplace
    plugin: claude-plugin
    codex:
      mode: adapter
      marketplace: adapter-repo
      plugin: adapter-plugin
      skills_path: skills
      prefix: pref-
local: []
EOF

    cp "$ROOT_DIR/install.sh" "$project_dir/install.sh"
    FAKE_CODEX_LOG="$codex_log" PATH="$fake_bin:$PATH" \
        bash "$project_dir/install.sh" --target codex --no-cleanup >"$project_dir/install.log"

    assert_exists "$project_dir/.repos/adapter-repo/.git"
    assert_exists "$project_dir/.codex-adapters/adapter-repo/.agents/plugins/marketplace.json"
    assert_exists "$project_dir/.codex-adapters/adapter-repo/plugins/adapter-plugin/.codex-plugin/plugin.json"
    assert_exists "$project_dir/.codex-adapters/adapter-repo/plugins/adapter-plugin/skills/pref-alpha/SKILL.md"
    assert_file_contains "$project_dir/.codex-adapters/adapter-repo/plugins/adapter-plugin/.codex-plugin/plugin.json" '"name": "adapter-plugin"'
    assert_file_contains "$project_dir/.codex-adapters/adapter-repo/.agents/plugins/marketplace.json" '"name": "adapter-repo"'
    assert_file_contains "$project_dir/.codex-adapters/adapter-repo/plugins/adapter-plugin/skills/pref-alpha/SKILL.md" "name: pref-alpha"
    assert_file_contains "$codex_log" "plugin marketplace add $project_dir/.codex-adapters/adapter-repo"
    assert_file_contains "$codex_log" "plugin add adapter-plugin@adapter-repo"
    assert_not_exists "$skills_dir/pref-alpha"
}

test_codex_marketplace_installs_without_clone() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local project_dir="$tmp/project"
    local skills_dir="$tmp/skills"
    local fake_bin="$tmp/bin"
    local codex_log="$tmp/codex.log"
    mkdir -p "$project_dir" "$skills_dir" "$tmp/remotes/guige"

    make_fake_codex "$fake_bin"

    cat >"$project_dir/skills.yaml" <<EOF
clone_dir: .repos
codex_adapter_dir: .codex-adapters
plugin_state_file: .plugin_state.json
skills_dir:
  claude: $tmp/claude-skills
  codex: $skills_dir
repos:
  guige-skills:
    install_mode: plugin
    url: $tmp/remotes/guige
    branch: main
    marketplace: guige-skills
    plugin: guige
    codex:
      mode: marketplace
      marketplace: guige-skills
      plugin: guige
local: []
EOF

    cp "$ROOT_DIR/install.sh" "$project_dir/install.sh"
    FAKE_CODEX_LOG="$codex_log" PATH="$fake_bin:$PATH" \
        bash "$project_dir/install.sh" --target codex --no-cleanup >"$project_dir/install.log"

    assert_not_exists "$project_dir/.repos/guige-skills"
    assert_file_contains "$codex_log" "plugin marketplace add $tmp/remotes/guige --ref main"
    assert_file_contains "$codex_log" "plugin add guige@guige-skills"
}

test_disabled_repo_is_cloned_but_not_linked
test_disabled_repo_updates_clone_but_removes_stale_link
test_disabled_repo_installs_enabled_skills_only
test_enabled_repo_installs_all_skills_even_with_filters
test_codex_adapter_generates_marketplace_plugin
test_codex_marketplace_installs_without_clone

echo "installer tests passed"
