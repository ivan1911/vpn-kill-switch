<!-- CODEGRAPH_START -->
## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it BEFORE grep/find or reading files when you need to understand or locate code:

- **MCP tool** (when available): `codegraph_explore` answers most code questions in one call — the relevant symbols' verbatim source plus the call paths between them, including dynamic-dispatch hops grep can't follow. Name a file or symbol in the query to read its current line-numbered source. If it's listed but deferred, load it by name via tool search.
- **Shell** (always works): `codegraph explore "<symbol names or question>"` prints the same output.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.
<!-- CODEGRAPH_END -->

## Release policy

Only issue a release when the user explicitly asks to release the app. Feature requests, fixes, packaging a development DMG, pushes and PR merges all use the development workflow by default.

Keep the SemVer in `VERSION` stable during development. Identify each build with its commit SHA and mark uncommitted changes as dirty. On an explicit release request, use the requested version or choose the SemVer increment for the accumulated changes. Build the release from the resulting commit of the merged release PR on `main`. Use its SHA in the release identifier.

## Build and verification

For runtime ownership, generated commands, regression tests, DMG verification and release handoff, use the [agent build guide](docs/agents/build-and-verify.md).
