# WardenBar

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Stack

Existing Swift package, SwiftUI, AppKit and the official Bitwarden CLI. Minimum macOS 13. Use ObservableObject for the presentation layer.

## Users

Initially the project owner, using a native menu bar password vault on their own Mac.

## Product Purpose

Quickly unlock, search and copy vault credentials without opening a full desktop password-manager window or occupying the Dock.

## Operating Context

Official CLI backend with an independent local authentication/data directory. First login occurs through the CLI; daily unlock occurs in the native app. Real read-only CLI integration has user-provided passing evidence in workspace docs/cli-foundation.md.

## Capabilities and Constraints

This milestone covers personal login items, metadata search, folder filtering, direct username/password/authenticator-code copy, manual sync/lock, clipboard clearing and automatic lock. Existing Bitwarden stars are shown on entries; the app does not edit them or expose a separate favorites filter. No server writes, biometric unlock or global shortcut yet. Master password and Session are never persisted or logged. Authenticator seeds stay out of the metadata index. Raw CLI output is never exposed as an error.

The owner approved a desktop memory-snapshot trial on 2026-11-03: supported login passwords and authenticator seeds remain private to the vault actor during the unlocked session. Password copies and local HMAC code generation do not invoke the CLI. Lock and refresh revoke the snapshot; no plaintext persistence is introduced, and Swift does not guarantee complete memory zeroization. Snapshot protection reflects the last successful indexing, so server-side changes require sync. The diagnostic tool keeps on-demand CLI reads and protection rechecks. Folder metadata may finish loading after copies become usable. Unlock and backend lock confirmation still require CLI operations.

## Brand Commitments

WardenBar is an independent community client. The approved design uses native macOS controls and a compact MenuBarExtra window. Product facts derive from the conversation and workspace docs/design.md; this file does not introduce a new visual direction.

## Product Principles

- Safety state and failure reporting remain explicit.
- Fast local search over transient metadata.
- Native platform behavior before visual novelty.
- Tests, builds, user-reported CLI execution and GUI operation are separate evidence.

## Open Decisions

Public distribution, supported CLI-version matrix and expanded item types remain future work. Auto-lock defaults to 5 minutes of vault inactivity and can be set to 1–1440 minutes or system-only. Both modes retain conservative locking on screen lock/sleep and session deactivation. The unlocked footer shows a monotonic countdown or system-only status. Only the numeric policy and popover width are persisted as display/security preferences. Clipboard expiry remains 30 seconds. The toolbar uses native Liquid Glass on supported macOS versions, with older-system and reduced-transparency fallbacks.
