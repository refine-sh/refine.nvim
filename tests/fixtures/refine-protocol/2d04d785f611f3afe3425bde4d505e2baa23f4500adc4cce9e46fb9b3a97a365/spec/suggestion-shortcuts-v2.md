# Suggestion shortcuts v2

Capability: `com.runjuu.refine.suggestion-shortcuts.v2`.

Clients MAY offer both v1 and v2. Servers MUST activate only the highest
mutually supported suggestion-shortcuts version, never both. The activated
set remains part of retained run identity. v1 and base behavior are unchanged.

When v2 is active, every presentation includes `applyShortcut` and
`dismissShortcut` conforming to `schema/suggestion-shortcuts-v2.schema.json`.
Each is tagged by `kind`: `keyCombination` has the v1 code, key, modifiers,
and label fields; `modifierChord` has keys and label; `modifierDoubleTap`
has key and label. Gesture keys are physical ControlLeft/Right, AltLeft/Right,
ShiftLeft/Right, or MetaLeft/Right. Fn and Caps Lock are excluded. Producers
canonicalize chord keys in that order. Duplicates are invalid. Labels contain
1–128 Unicode scalar values. Key combinations preserve all v1 validation.

A chord contains at least two distinct physical keys. All must overlap, in
any press order, with no other modifiers. It fires once when all are released.
A double-tap consists of two complete press/release cycles of the same physical
key, within 500 ms inclusive from first press to second release. Use a monotonic
clock. Pressing another key, an unexpected modifier, or a mouse button cancels
recognition. Repeats do not advance recognition. Composition input cancels it.
Focus loss, settings or action-owner changes, recording, and input-monitor
interruptions clear pending state; keys already held cannot start a new gesture.
A new attempt may start after the modifiers return to neutral.

Gesture recognition MUST preserve modifier press and release delivery to the
host. It MUST use the existing suggestion action ownership, current-source
validation, and busy-action deduplication. A gesture cannot transfer between
suggestion owners. Dismiss retains its existing card versus cursor meaning.
Identical gestures conflict. An existing standalone modifier action conflicts
with a gesture containing that exact physical key because it fires earlier.
Clients disable conflicting action bindings with actionable feedback. Ordinary
key combinations can coexist with gestures because typing cancels gestures.

The legacy applyKey and dismissKey remain required. For v1 sessions the server
sends the person's retained v1 bindings; for base sessions it sends the retained
single-key choices. A v2 session MUST use the v2 binding exclusively. No client
may remove modifiers, substitute a key, or fall back for an unsupported gesture.
Neovim accepts gesture bindings but leaves them unmapped and displays availability
feedback; explicit action commands remain usable. Existing key combinations
remain supported under v2. Settings identify fallback bindings for older clients.
