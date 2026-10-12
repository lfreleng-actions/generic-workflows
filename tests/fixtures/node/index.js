// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 The Linux Foundation

// Fixture for the linting workflow's Node.js toolchain self-test: the
// prettier hook checks this file, which it can only do once the
// executor has installed the project's pinned prettier. Indented to
// the repository's .editorconfig, which prettier honours.
export function add(left, right) {
    return left + right;
}
