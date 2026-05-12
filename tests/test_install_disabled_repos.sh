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
    cp "$ROOT_DIR/install.sh" "$project_dir/install.sh"
    bash "$project_dir/install.sh" >"$project_dir/install.log"
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

test_disabled_repo_is_cloned_but_not_linked
test_disabled_repo_updates_clone_but_removes_stale_link

echo "disabled repo installer tests passed"
