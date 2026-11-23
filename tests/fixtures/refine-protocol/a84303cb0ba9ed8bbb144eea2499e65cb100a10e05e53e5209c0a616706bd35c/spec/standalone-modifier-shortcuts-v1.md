# Standalone modifier shortcuts v1

Capability: `com.runjuu.refine.standalone-modifier-shortcuts.v1`.

Requires activated suggestion-shortcuts.v1 or suggestion-shortcuts.v2. Without
activation, clients MUST retain their existing supported shortcuts and MUST NOT
send the extension command. Servers MUST NOT emit extension events to those
clients. This capability forwards standalone ShiftLeft/Right, AltLeft/Right and
ControlLeft/Right presses; it does not add chord or double-tap recognition.

The client sends `setModifierShortcutOwner` with `owner` containing `ownerId`,
`processId` (the positive macOS host application PID, not the plugin subprocess),
and `keys` (zero to two unique standalone modifier codes). An empty list revokes
ownership. The opaque ownerId is never reused for another interaction. It binds
connection, view, source revision, check, suggestion, card/cursor mode, selection,
and settings. Renew unchanged ownership at least every 500 ms; servers stop
forwarding after two seconds without renewal. A connection starts unarmed, and
ownership and events MUST NOT survive disconnect or be replayed on reconnect.

The server replies with `modifierShortcutAvailability`, whose `state` contains
`ownerId` and `available`. Availability requires an operational native monitor
and permission. It may change on renewal. Clients show unavailable bindings
until availability is confirmed for the current owner. Permission denial must
not break ordinary shortcuts or pointer actions.

The server emits `modifierShortcutPressed`, whose `press` contains `ownerId` and
`code`, only for a subscribed standalone physical modifier press while the exact
host process is foreground. Other modifiers must be absent. Release, repeat,
recording, and queued events preceding ownership do not trigger. Modifier events
continue to the host. These are existing press semantics, not tap-on-release:
starting to type an uppercase letter can trigger an owned Shift binding.

The client MUST revalidate the owner token and its current editor eligibility
on receipt, including focused view, overlays, autocomplete, current source,
read-only Apply, action availability and busy-action deduplication. It then uses
the normal performAction/completeApply flow; cursor Dismiss still only cancels
cursor activation. Unowned or stale presses do nothing. Envelope sequence rules
apply equally to these events. No text or raw keyboard stream is forwarded.

The initial Refine implementation serves the refine-sublime/sublime host pair.
The client must supply its real host PID; labels and PIDs are coordination
metadata, not authentication. All existing same-user transport protections apply.
