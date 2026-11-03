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

Official CLI backend with an independent local authentication/data directory. First login uses a native server/account form backed by the CLI; daily unlock occurs in the native app. The app automatically prepares its isolated directory, offers US/EU/self-hosted servers, and guides email/master-password authentication plus known two-factor, new-device email and additional client-secret prompts. Advanced API-key/SSO/interactive terminal commands remain available in the same directory. Existing authenticated profiles start at unlock. Real read-only CLI integration has user-provided passing evidence in workspace docs/cli-foundation.md.

## Capabilities and Constraints

This milestone covers personal login, card, identity, secure-note and SSH-key records; metadata search combined with folder and type filters; read-only field details and copying; manual sync/lock, clipboard clearing and automatic lock. Login rows retain username/password/authenticator-code actions. Other rows copy the card number, email, note or public SSH key when available. Sensitive card/identity identifiers, passwords, private keys, notes and hidden custom fields are concealed until explicitly revealed in details. Notes and key whitespace are preserved. Attachments, linked custom fields, organization-owned, reprompt-protected, deleted and unknown record types are excluded. Existing Bitwarden stars are shown on entries; the app does not edit them or expose a separate favorites filter. No server writes, biometric unlock or global shortcut yet. Master password and Session are never persisted or logged. Authenticator seeds stay out of the metadata index. Raw CLI output is never exposed as an error.

The owner approved a desktop memory-snapshot trial on 2026-11-03: supported record fields and login authenticator seeds remain private to the vault actor during the unlocked session. Only the selected detail view receives SecretValue-wrapped fields; search/list metadata contains no full card numbers, private keys, notes, custom-field values or authenticator seeds. Navigation, sync and lock discard selected detail/reveal state, and stale field actions cannot target refreshed custom-field positions. Password copies and local HMAC code generation do not invoke the CLI. Lock and refresh revoke the snapshot; no plaintext persistence is introduced, and Swift does not guarantee complete memory zeroization. Snapshot protection reflects the last successful indexing, so server-side changes require sync. The diagnostic tool keeps login-only on-demand CLI reads and protection rechecks. Folder metadata may finish loading after copies become usable. Unlock and backend lock confirmation still require CLI operations.

The first-run input bridge recognizes supported CLI prompts and never renders raw process output. Email and verification responses use stdin; the master password uses a short-lived child environment variable, as for unlock. Cancellation/system lock invalidates UI intent and stops the login child before cleanup. A login that never yielded a usable Session may safely return to setup only after the CLI explicitly reports unauthenticated; authenticated or unknown states retain backend lock confirmation and failure protection. Login failures are retryable and a partial authenticated profile routes to unlock. HTTPS is required except loopback HTTP; credential-bearing, query-bearing and fragment-bearing server URLs are rejected. No credentials, codes, API secrets or Session keys are persisted by the app. CLI authentication state, encrypted vault data and server configuration remain in the isolated CLI directory.

The interactive flow is checked against the installed CLI 2026.10.1 prompt library and synthetic process fixtures. Supported login methods and prompts are bounded; unknown prompts/timeouts may require the terminal fallback. These checks do not establish a broad version compatibility matrix or real-server acceptance. Public DMG/signing/notarization tooling is still future work.

## Brand Commitments

WardenBar is an independent community client. The approved design uses native macOS controls and a compact MenuBarExtra window. Product facts derive from the conversation and workspace docs/design.md; this file does not introduce a new visual direction.

## Product Principles

- Safety state and failure reporting remain explicit.
- Fast local search over transient metadata.
- Native platform behavior before visual novelty.
- Tests, builds, user-reported CLI execution and GUI operation are separate evidence.

## Open Decisions

Public distribution and a supported CLI-version matrix remain future work. Auto-lock defaults to 5 minutes of vault inactivity and can be set to 1–1440 minutes or system-only. Both modes retain conservative locking on screen lock/sleep and session deactivation. The unlocked footer shows a monotonic countdown or system-only status. Only the numeric policy and popover width are persisted as display/security preferences. Clipboard expiry remains 30 seconds. The toolbar uses native Liquid Glass on supported macOS versions, with older-system and reduced-transparency fallbacks.
