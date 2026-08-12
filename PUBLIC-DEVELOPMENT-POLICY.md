# Public development policy

This repository is an independently authored, public proof of concept. Its
implementation must be explainable entirely from public sources.

This policy is a practical engineering safeguard, not a formal legal
clean-room certification.

## Allowed sources

- The public RFC and its public review discussion.
- The official public OpenClaw repository at recorded commits.
- Public Microsoft Learn, .NET, Windows, and MSIX documentation.
- Public Node.js documentation and official distributions.
- Public package registries and projects with compatible licenses.
- Independently authored experiments and test fixtures.

Material sources used for design or implementation must be recorded in
`PUBLIC-SOURCES.md`.

## Prohibited sources

Do not copy, adapt, translate, decompile, or structurally imitate:

- private source repositories or branches;
- private pipelines, manifests, scripts, or build logs;
- private packages, feeds, binaries, symbols, or signing material;
- private architecture documents, work items, chats, or incident reports;
- code or assets copied from another checkout without verified public
  provenance.

Private material may establish that a business requirement exists, but it must
not be used as an implementation reference. Stop work if a change cannot be
justified from a source listed in `PUBLIC-SOURCES.md`.

## Required workflow

1. Work only in this public repository.
2. Create `.public-safety.local.json` from the committed example and add exact
   private paths and identifiers relevant to the local machine.
3. Record each new implementation source or dependency in
   `PUBLIC-SOURCES.md`.
4. Run repository safety checks after adding dependencies, workflows,
   manifests, generated assets, or binaries.
5. Stage only intended files and run staged mode before every commit.
6. Review `git diff --cached --binary` before committing.
7. Submit changes through a pull request and require the public-safety CI
   check before merging.
8. Inspect every distributable archive with package mode before upload or
   release.

Local hooks are optional convenience checks and are not an enforcement
boundary. Required CI checks and human review remain mandatory because Git
hooks can be bypassed.

## Exceptions

There are no wildcard or directory-wide exceptions. An exception must identify
one exact path or artifact and document its public source, license,
cryptographic checksum when applicable, and reason for inclusion. Add that
record to `PUBLIC-SOURCES.md` before changing the scanner.

## Suspected contamination

Stop implementation and publication immediately. Do not merely delete the
material in a later commit: it may remain in Git history and workflow
artifacts. Identify the affected commits and artifacts, remove them from all
reachable history, invalidate published artifacts, and obtain a fresh review
before resuming.
