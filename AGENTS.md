# Repository guidance

Use concise technical communication and make the smallest complete change.
Read component READMEs before editing. Keep portable simulation
in FotufilmCore and shared physics in the stage headers under Sources/FotufilmHalide/Stages
(FotufilmHalideShared.h is the umbrella that includes them; a stage header holds expressions,
never schedules). Keep stocks data-driven.
Never commit credentials, restricted data, manufacturer publications, or vendor SDKs.
Run relevant tests and builds. Update docs/documentation.html for user-facing changes
and docs/support.html for setup changes. Check changed public-page links.
Declare every user-facing control once in Sources/FotufilmEditModel/EditorControlCatalogue.swift and
run `swift run fotufilm-controls` (with `--consumer <path>` for the private checkout) to regenerate
the bridge slots, plugin ids, Motion template, web controls, Kotlin sources and documentation tables.
CI runs the same command with `--check`.
The packed configuration layout and the AOT variant list live in
Sources/FotufilmHalide/config-layout.json and aot-variants.json; edit those and run
`python3 tools/generate-config-layout.py` / `python3 tools/generate-aot-variants.py` rather than
the generated headers. CI checks both with `--check`.
