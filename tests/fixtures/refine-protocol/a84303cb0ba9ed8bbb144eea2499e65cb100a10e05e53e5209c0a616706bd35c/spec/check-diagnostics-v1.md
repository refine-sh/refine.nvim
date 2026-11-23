# Check diagnostics v1

Capability: `com.runjuu.refine.check-diagnostics.v1`.

The client offers this capability in `hello`; the server activates it only from
its published registry. The server MUST omit `content.checkDiagnostics` without
activation. An unactivated client ignores that extension field after validating
the portable JSON profile. Empty capability activation remains complete Protocol
1.0 behavior, and this extension adds no command or event type.

After activation, a `presentationContentReplaced` event MAY include
`content.checkDiagnostics` only when `status` is `complete` and `coverage` is
`partial`. The object conforms to `schema/check-diagnostics.schema.json` and has
required `issues` and `omittedIssueCount` members. It MUST contain at least one
issue or a positive omitted count; otherwise the server omits the object.

An issue identifies one unchecked passage and check kind:

- `sourceId` identifies a source in the presentation revision's authoritative snapshot.
- `range` is a nonempty source-local UTF-16 range wholly inside that source, with
  both endpoints on Unicode-scalar boundaries. It is not a range in model input,
  normalized text, or a preceding revision.
- `kind` is `grammar` or `fluency`.
- `reason` is one of `unusableOutput` (the model result could not be used),
  `protectedTextRestoreFailed` (protected source content could not be restored),
  `excessiveChange` (the proposed change exceeded the accepted change policy), or
  `cancelled` (this unit was interrupted).

The array contains at most 128 issues. Producers deduplicate identical
`sourceId`, `range`, `kind`, and `reason` tuples, then sort by the source's index
in the authoritative snapshot, range location, range length, kind, and reason.
The final two comparisons use ascending ASCII order. Producers retain the first
128 tuples, or a shorter prefix to satisfy a resource limit, and set
`omittedIssueCount` to the number of tuples not included. The prefix MAY be empty
when the omitted count is positive. The count is a nonnegative safe integer.
Receivers reject duplicate or incorrectly ordered tuples, invalid source
references, invalid ranges, unknown kinds or
reasons, and other malformed activated data under normal fatal protocol error
handling. Unknown object members retain the base protocol's ignore behavior.

Validation uses the presentation revision's original source identities, order,
lengths, and Unicode-scalar boundaries, including for superseded presentations.
Receivers MUST NOT validate old diagnostics against a newer snapshot. They MAY
retain bounded coordinate metadata without retaining historical source text. If
the required evidence is unavailable or has been evicted, the receiver MUST close
the connection under fatal protocol error handling instead of skipping
validation. Evidence from a lost run MUST NOT validate a later run merely because
a revision identifier is reused.

Diagnostics replace the complete prior diagnostic list for their presentation.
They do not erase valid suggestions and do not change `coverage` semantics.
Their absence does not imply full coverage. Deliberately protected or excluded
writing is not an error solely because it was excluded. A server records an issue
only when an attempted unit cannot supply a trustworthy result.

Clients SHOULD show the affected line or passage, the check kind, a plain-language
reason, and an explicit retry action. Navigation MUST check that the source
revision is still current. Retrying the note uses the existing `requestCheck`
command; it does not require a new message. A failed unit must not become a
permanent successful cache hit. Diagnostics carry no source snippets, model
output, prompts, exception descriptions, paths, or credentials. User-requested
exports SHOULD contain only location metadata, counts, kinds, and reason codes.

The activated set remains bound to retained run identity as in Protocol 1.0.
Publication requires a new registry/manifest snapshot; this extension does not
change any earlier published snapshot.
