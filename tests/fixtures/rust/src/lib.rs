// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 The Linux Foundation

//! Fixture crate for the linting workflow's Rust toolchain self-test.

/// Adds two numbers; exists so rustfmt and clippy have code to check.
#[must_use]
pub fn add(left: u64, right: u64) -> u64 {
    left + right
}
