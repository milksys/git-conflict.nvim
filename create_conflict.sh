#!/bin/bash
# Creates ./conflict-test, a throwaway repo with a merge conflict in conflicted.lua
# Usage: ./create_conflict.sh [--diff3]
set -e
[ -d ./conflict-test/ ] && rm -rf ./conflict-test/
mkdir conflict-test
cd conflict-test
git init -q -b main
[ "$1" = "--diff3" ] && git config merge.conflictStyle diff3
echo "local value = 1 + 1" > conflicted.lua
git add conflicted.lua
git commit -qm 'initial'
git checkout -qb new_branch
echo "local value = 1 - 1" > conflicted.lua
git commit -qam 'first commit on new_branch'
git checkout -q main
cat > conflicted.lua << LUA
local value = 5 + 7
print(value)
print(string.format("value is %d", value))
LUA
git commit -qam 'second commit on main'
git merge new_branch || true
