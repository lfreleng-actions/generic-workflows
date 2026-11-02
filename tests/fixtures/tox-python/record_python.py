# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Fail a tox environment unless it ran on the Pythons the leg expects.

Usage: record_python.py <environment Python> <tox Python> [<override>]

The tox-verify self-test calls this from its fixture environments, so a
passing leg proves which interpreters it used, not merely that tox ran:

* the environment's own interpreter is <environment Python>;
* the Python setup-python set up last, which tox-run-action runs tox
  on, is <tox Python>; setup-python exports its location as
  pythonLocation;
* TOX_OVERRIDE equals <override>, or is empty when none is given.

Each version is major.minor, such as 3.10.
"""

import os
import subprocess
import sys


def version_of(python: str) -> str:
    """Return the major.minor version of the interpreter at python."""
    result = subprocess.run(
        [python, "-c", "import sys; print('%d.%d' % sys.version_info[:2])"],
        capture_output=True,
        check=True,
        text=True,
    )
    return result.stdout.strip()


def main(argv: list[str]) -> int:
    """Compare the interpreters and override against argv."""
    if len(argv) not in (3, 4):
        _ = sys.stderr.write(__doc__ or "")
        return 2
    want_env, want_tox = argv[1], argv[2]
    want_override = argv[3] if len(argv) == 4 else ""
    errors: list[str] = []

    actual_env = "{}.{}".format(*sys.version_info[:2])
    _ = sys.stdout.write(f"Environment Python: {sys.version} ({sys.executable})\n")
    if actual_env != want_env:
        errors.append(f"environment ran on {actual_env}, expected {want_env}")

    location = os.environ.get("pythonLocation", "")
    if not location:
        errors.append("pythonLocation is unset; pass it through pass_env")
    else:
        actual_tox = version_of(os.path.join(location, "bin", "python"))
        _ = sys.stdout.write(f"tox Python: {actual_tox} ({location})\n")
        if actual_tox != want_tox:
            errors.append(f"tox ran on {actual_tox}, expected {want_tox}")

    actual_override = os.environ.get("TOX_OVERRIDE", "")
    _ = sys.stdout.write(f"TOX_OVERRIDE: {actual_override!r}\n")
    if actual_override != want_override:
        errors.append(
            f"TOX_OVERRIDE is {actual_override!r}, expected {want_override!r}"
        )

    for error in errors:
        _ = sys.stderr.write(f"{error}\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
