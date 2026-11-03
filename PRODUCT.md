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

This milestone covers personal login items, metadata search, folder filtering, direct username/password/authenticator-code copy, manual sync/lock, clipboard clearing and automatic lock. Favorites filter existing Bitwarden stars; the app does not edit them. No server writes, biometric unlock or global shortcut yet. Master password and Session are never persisted or logged. Authenticator seeds stay out of the metadata index. Raw CLI output is never exposed as an error.

## Brand Commitments

WardenBar is an independent community client. The approved design uses native macOS controls and a compact MenuBarExtra window. Product facts derive from the conversation and workspace docs/design.md; this file does not introduce a new visual direction.

## Product Principles

- Safety state and failure reporting remain explicit.
- Fast local search over transient metadata.
- Native platform behavior before visual novelty.
- Tests, builds, user-reported CLI execution and GUI operation are separate evidence.

## Open Decisions

Public distribution, supported CLI-version matrix and expanded item types remain future work. Initial 5-minute inactivity and 30-second clipboard expiry are implementation defaults.
