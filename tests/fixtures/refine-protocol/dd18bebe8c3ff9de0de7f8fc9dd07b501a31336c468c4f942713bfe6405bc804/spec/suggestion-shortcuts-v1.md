# Suggestion shortcuts v1

Capability: `com.runjuu.refine.suggestion-shortcuts.v1`.

The client offers this capability in hello; the server activates it only from
its published registry. Without activation, base Apply and Dismiss key behavior
is unchanged and extension fields are ignored after portable-JSON validation.

When activated, every presentation's `interaction.quickApply` MUST include
`applyShortcut` and `dismissShortcut`, each conforming to
`schema/suggestion-shortcuts.schema.json`. Both bindings replace the legacy
single-key bindings for card and cursor shortcut ownership. The legacy required
`applyKey` and `dismissKey` fields remain present and describe the person's
retained single-key choices for older clients; they MUST NOT also fire in an
activated session. The server MUST omit extension fields without activation.

A binding has `code` (a physical KeyboardEvent.code identifier), `key` (the
current-layout unmodified printable character, or the code for a special key),
`modifiers` (a duplicate-free set of control, option, shift, command), and
`label` (localized display text). Modifier order is insignificant; producers
use control, option, shift, command order. Caps Lock, numeric-pad and incidental
function flags are ignored. Left and right modifiers are equivalent within a
combination. Existing standalone ShiftLeft/Right, AltLeft/Right and
ControlLeft/Right use an empty modifier array and fire only on their own press.
Media keys, Fn, Caps Lock, and standalone Command are outside this version.

Printable Key*, Digit*, Intl*, Numpad* and punctuation codes require at least
one of control, option, or command. Standalone modifier codes MUST have no
additional modifiers. A shortcut MUST match its complete modifier set exactly.
An identical pair or a standalone modifier that prefixes the other action's
combination is a conflict: clients retain the configuration but disable both
shortcut actions and show actionable conflict feedback. Pointer actions remain
available. No client may silently remove modifiers or substitute a shortcut.

Ownership, source validation, Apply receipts, busy-action deduplication,
composition handling and mapping restoration remain unchanged. A key without
an owning action propagates. Neovim translates representable bindings using
`key` and native key notation; unsupported frontend combinations remain
unmapped with an availability warning. Command combinations require a frontend
that delivers Command, such as Neovide. Layout changes publish a settings-only
presentation with refreshed keys and labels; they do not start a writing check.

The activated capability set is bound to the retained run. Reattachment with a
different activated set is rejected using runUnavailable/newRun. Updated
clients remain compatible with an empty activated set from an older server.
