# Agent Instructions

## Working Style

- Inspect the repository and existing history before making assumptions.
- Prefer small, focused changes over broad refactors.
- Work through changes in the planned order and verify each step.
- Keep engine-specific code in engine adapters; keep shared behavior in the
  runtime layer.
- Prefer Git submodules for engine dependencies when the dependency is a
  source-level engine that must be pinned and reproducibly built.
- Preserve pinned dependency revisions and document repository setup clearly.
- Commit completed logical changes separately with concise commit messages.
- Before committing, review status and diff, check whitespace, and run the
  relevant builds and tests.

## Documentation

- Keep README prose wrapped to approximately 80 characters where practical.
- Document commands for setup, building, testing, and supported engine
  differences.
- Keep documentation aligned with the current implementation; remove stale
  references rather than preserving obsolete workflows.

## Testing

- Test every supported engine where behavior is shared.
- Use exit status and explicit expected output rather than sentinel text
  searches.
- Distinguish common integration tests from engine-specific capability tests.
