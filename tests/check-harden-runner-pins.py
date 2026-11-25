# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Check harden-runner pins across the files read by a plan test."""

import re
import sys
from pathlib import Path

ACTION = "step-security/harden-runner"
# This release fixes the westus2 DNS bypass.
MIN_VERSION = (2, 22, 3)

CALL = re.compile(
    r"""^(?P<key>[ \t]*(?:-[ \t]+)?uses:[ \t]+)"""
    + rf"""(?P<value>['"]?(?i:{ACTION})(?=@|['" \t]|$).*)""",
    re.MULTILINE,
)
PIN = re.compile(
    rf"""(?P<quote>['"]?)(?i:{ACTION})@(?P<sha>[0-9a-f]{{40}})(?P=quote)"""
    + r"\s+#\s*v(?P<version>[0-9]+(?:\.[0-9]+){2})\s*"
)


def version_tuple(version: str) -> tuple[int, ...]:
    return tuple(map(int, version.split(".")))


def pin_problem(calls: dict[str, str]) -> str:
    if not calls:
        return f"no {ACTION} calls found"
    shas: set[str] = set()
    for value in calls.values():
        pin = PIN.fullmatch(value)
        if pin is None:
            return f"expected a full lowercase SHA and a # vX.Y.Z comment for {ACTION}"
        if version_tuple(pin["version"]) < MIN_VERSION:
            minimum = ".".join(map(str, MIN_VERSION))
            return f"{ACTION} version must be at least v{minimum}"
        shas.add(pin["sha"])
    if len(shas) != 1:
        return f"{ACTION} calls must agree on one commit SHA"
    return ""


def workflow_calls(workflows: dict[str, str]) -> dict[str, str]:
    return {
        f"{path}:{line_no}": match["value"]
        for path, text in workflows.items()
        for line_no, line in enumerate(text.splitlines(), 1)
        if (match := CALL.match(line))
    }


def self_test(workflows: dict[str, str], calls: dict[str, str]) -> bool:
    versions = [
        version_tuple(pin["version"])
        for value in calls.values()
        if (pin := PIN.fullmatch(value)) is not None
    ]
    major, minor, patch = max(versions)
    newer = f"v{major}.{minor}.{patch + 1}"
    # Synthetic refs and version used only in the mutated call sites.
    sha, other_sha = "a" * 40, "b" * 40
    bumped = {
        path: CALL.sub(rf"\g<key>{ACTION}@{sha} # {newer}", text)
        for path, text in workflows.items()
    }
    if problem := pin_problem(workflow_calls(bumped)):
        print(f"uniform bump was rejected: {problem}", file=sys.stderr)
        return False

    path = next(path for path, text in bumped.items() if CALL.search(text))
    for label, replacement in (
        ("different SHA", f"{other_sha} # {newer}"),
        ("tag", f"{newer} # {newer}"),
        ("branch", f"main # {newer}"),
        ("short SHA", f"{sha[:12]} # {newer}"),
        ("uppercase SHA", f"{sha.upper()} # {newer}"),
        ("missing comment", sha),
        ("old version", f"{sha} # v0.0.0"),
    ):
        mutant = CALL.sub(rf"\g<key>{ACTION}@{replacement}", bumped[path], count=1)
        if mutant == bumped[path] or not pin_problem(
            workflow_calls(bumped | {path: mutant})
        ):
            print(f"{label} mutant did not fail the pin check: {path}", file=sys.stderr)
            return False
    return True


def main(paths: list[str]) -> int:
    workflows = {path: Path(path).read_text(encoding="utf-8") for path in paths}
    calls = workflow_calls(workflows)
    if problem := pin_problem(calls):
        print(problem, file=sys.stderr)
        for site, value in calls.items():
            print(f"  {site}: {value}", file=sys.stderr)
        return 1
    return 0 if self_test(workflows, calls) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
