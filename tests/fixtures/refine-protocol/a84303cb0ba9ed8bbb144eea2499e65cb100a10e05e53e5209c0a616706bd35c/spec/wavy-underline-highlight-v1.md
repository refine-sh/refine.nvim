# Wavy underline highlight v1

Capability: `com.runjuu.refine.wavy-underline-highlight.v1`.

The client offers this capability in `hello`; the server activates it only from
its published registry. Empty capability activation remains complete Protocol
1.0 behavior. This extension adds no command, event, or field. It widens one
enum after activation and leaves `schema/shared.schema.json` unchanged.

The only appearance carrier in Protocol 1.0 is `content.appearance` in a
`presentationContentReplaced` event. After activation, its
`appearance.highlight.style` MAY be `wavyUnderline` in addition to the base
`underline`, `dashedUnderline`, and `highlight` values. The activated value set
is defined by `schema/wavy-underline-highlight.schema.json`; every other
appearance member keeps its base meaning and validation.

Without activation the server MUST send `underline` wherever it would otherwise
send `wavyUnderline`. This substitution is the compatibility path for clients
that do not offer the capability. A server MUST NOT send `wavyUnderline` to an
unactivated client; an unactivated receiver keeps base behavior and treats it as
an unknown enum value, a fatal `malformedMessage`.

An activated client renders `wavyUnderline` as a continuous wave under each
highlighted range, in the suggestion color it would use for `underline`. A
client that cannot draw a wave on some surface MAY draw a straight `underline`
there instead. Activated receivers still reject every other unknown style value
as a fatal `malformedMessage`.
