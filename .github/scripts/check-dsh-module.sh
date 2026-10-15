#!/usr/bin/env bash
#
# Verify that the DSH agent module is present AND wired into the Xcode target.
#
# The module is compiled through a PBXFileSystemSynchronizedRootGroup rooted at
# src/ios/DSH. Two failure modes both surface as the same opaque Swift error
# ('cannot find dshSystemPrompt in scope') with no hint at the cause:
#
#   1. a file is missing from the group's directory;
#   2. the group is declared but not attached to the Minis target, or is attached
#      to a group whose own `path =` redirects it somewhere else.
#
# (2) is the subtle one: PBXFileSystemSynchronizedRootGroup.path resolves
# relative to its PARENT GROUP, not to the project root. Parent it anywhere with
# a `path =` and `path = DSH` silently resolves to the wrong directory.
#
# Check both up front so the build fails with a sentence instead of a puzzle.
#
# Usage: bash .github/scripts/check-dsh-module.sh

set -euo pipefail

cd "$(dirname "$0")/../.."

PBX="src/ios/Minis.xcodeproj/project.pbxproj"
GROUP_ID="D5A1000100000000000000D51"

expected=(
  DSHTypes.swift
  DSHSystemPrompt.swift
  DSHToolRegistry.swift
  DSHToolScheduler.swift
  DSHToolGate.swift
  DSHSession.swift
  DSHCompaction.swift
  DSHTurnDriver.swift
  DSHTurnDriverBridge.swift
  DSHTurnDriverAdapter.swift
  DSHTurnDriverRun.swift
  DSHToolHandlers.swift
  DSHToolHandlerImpl.swift
  DSHJSONSchema.swift
  DSHToolSchemaBridge.swift
  DSHToolDispatchBridge.swift
  DSHMinisPrompt.swift
  DSHMinisTools.swift
  DSHPromptAdapter.swift
  DSHToolBlockKind.swift
)

missing=0
for f in "${expected[@]}"; do
  if [ ! -f "src/ios/DSH/$f" ]; then
    echo "MISSING: src/ios/DSH/$f"
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "DSH agent module is incomplete — check the DSH synchronized group."
  exit 1
fi
echo "DSH agent module: ${#expected[@]} files present"

if [ ! -f "$PBX" ]; then
  echo "ERROR: $PBX not found"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "::warning::python3 unavailable — skipping the project-structure check"
  exit 0
fi

python3 - "$PBX" "$GROUP_ID" <<'PY'
import re
import sys

pbx_path, group_id = sys.argv[1], sys.argv[2]
text = open(pbx_path, encoding="utf-8").read()

failures = []

# Top-level entries look like:
#     <id> /* <name> */ = {
#         ...
#     };
entries = re.findall(
    r"\n\t\t([0-9A-Fa-f]{10,24}) /\* (.*?) \*/ = \{\n(.*?)\n\t\t\};", text, re.S
)

# 1. The group must be declared as a synchronized root group.
group = [e for e in entries if e[0] == group_id]
if not group:
    failures.append(
        f"the DSH synchronized group ({group_id}) is not declared in project.pbxproj"
    )
else:
    body = group[0][2]
    if "isa = PBXFileSystemSynchronizedRootGroup" not in body:
        failures.append(f"{group_id} is not a PBXFileSystemSynchronizedRootGroup")
    if "path = DSH" not in body:
        failures.append(f"{group_id} does not carry 'path = DSH'")
    else:
        print("DSH synchronized group is declared with path = DSH")

    # 2. Its parent group must not redirect the resolution.
    child_ref = f"{group_id} /* DSH */,"
    parents = [
        e
        for e in entries
        if "isa = PBXGroup" in e[2] and child_ref in e[2]
    ]
    if not parents:
        failures.append(
            "the DSH group is not a child of any PBXGroup, so Xcode cannot "
            "resolve its path"
        )
    else:
        for pid, pname, pbody in parents:
            if re.search(r"^\s*path = ", pbody, re.M):
                failures.append(
                    f"parent group {pid} /* {pname} */ carries a 'path =', so "
                    f"'path = DSH' resolves relative to it instead of src/ios"
                )
            else:
                print(f"DSH group is parented by {pid} /* {pname} */ (no 'path =')")

# 3. The Minis app target must attach the group, or Xcode compiles nothing.
targets = [
    e for e in entries if "isa = PBXNativeTarget" in e[2]
]
minis = [t for t in targets if re.search(r"^\s*name = Minis;$", t[2], re.M)]
if not minis:
    failures.append("no PBXNativeTarget named Minis")
else:
    tbody = minis[0][2]
    if "fileSystemSynchronizedGroups" not in tbody:
        failures.append("the Minis target declares no fileSystemSynchronizedGroups")
    elif group_id not in tbody:
        failures.append(
            "the DSH group is not attached to the Minis target — Xcode would "
            "compile none of its sources"
        )
    else:
        print("DSH synchronized group is attached to the Minis target")

# 4. The DSH sources must not ALSO be listed individually in a Sources phase;
#    doing both produces duplicate-symbol link errors.
if re.search(re.escape(group_id) + r" /\* DSH \*/ in Sources", text):
    failures.append("the DSH group is also listed in a Sources build phase")

if failures:
    for f in failures:
        print(f"ERROR: {f}", file=sys.stderr)
    sys.exit(1)
PY

echo "DSH module wiring verified"
