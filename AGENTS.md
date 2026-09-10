# Repository guidance

Use concise technical communication and make the smallest complete change.
Read component READMEs before editing. Keep portable simulation
in FotufilmCore and shared physics in FotufilmHalideShared.h. Keep stocks data-driven.
Never commit credentials, restricted data, manufacturer publications, or vendor SDKs.
Run relevant tests and builds. Update docs/documentation.html for user-facing changes
and docs/support.html for setup changes. Check changed public-page links.
Declare every user-facing control once in Sources/FotufilmEditModel/EditorControlCatalogue.swift and
run `swift run fotufilm-controls` (with `--consumer <path>` for the private checkout) to regenerate
the bridge slots, plugin ids, Motion template, web controls, Kotlin sources and documentation tables.
CI runs the same command with `--check`.
