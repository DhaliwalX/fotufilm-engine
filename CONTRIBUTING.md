# Contributing

Contributions are provided under Apache-2.0 unless explicitly agreed otherwise.
See [LICENSE](LICENSE) and [LICENSING.md](LICENSING.md) for the applicable terms.

Keep portable simulation in FotufilmCore and shared image-formation physics in
`Sources/FotufilmHalide/FotufilmHalideShared.h`. Keep stock behavior data-driven.
Uniform fields must survive spatial stages unchanged, neutral mid-gray must remain
anchored, and seeded grain must be deterministic. Verify CPU/Metal agreement for
rendering changes and inspect representative output.

Run `swift test -c release --parallel` and the relevant desktop/plugin build. Update
`docs/documentation.html` for user-visible behavior, and `docs/support.html` for setup
or troubleshooting changes. Check local links when changing public pages.

Never commit credentials, restricted calibration data, manufacturer publications,
or vendor SDKs. The checked-in example container key
is public and must never be replaced with a production key. Run
`python3 tools/check-source-boundary.py` before proposing changes.
