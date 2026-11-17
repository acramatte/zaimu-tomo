# Changelog

## [0.2.0](https://github.com/acramatte/zaimu-tomo/compare/v0.1.0...v0.2.0) (2026-11-17)


### Features

* condense the journal into a month-grouped ledger with a booking queue ([ea4f04a](https://github.com/acramatte/zaimu-tomo/commit/ea4f04a8d04ef0c0b289f2279308f5b5d911f0be))
* guard the journal entry status in the database ([443baa6](https://github.com/acramatte/zaimu-tomo/commit/443baa69b9643bc59d86290261b64651e86be835))
* **processing:** show retrying documents with attempt and last failure ([#133](https://github.com/acramatte/zaimu-tomo/issues/133)) ([a4515d6](https://github.com/acramatte/zaimu-tomo/commit/a4515d6125f1e5c0d6eccf216c8574c84d4544d5))
* refuse changes to a set journal-entry fingerprint ([15d0fde](https://github.com/acramatte/zaimu-tomo/commit/15d0fde9235f52a552aad32779a1715146e50fbf))
* show real documents on the activity page ([745469c](https://github.com/acramatte/zaimu-tomo/commit/745469ca8fdbd96d0aefca2e3e29d85c0c722283))


### Bug Fixes

* bump plug to 1.20.4 for CVE-2026-120287 ([283e7e4](https://github.com/acramatte/zaimu-tomo/commit/283e7e4feb1437dbadba5d69a1b093eb674896c7))
* keep the invoice PDF viewer within its card ([02b82e0](https://github.com/acramatte/zaimu-tomo/commit/02b82e04cf232ca409b8ca9c0c3190e9359476b5))
* remove the ungated journal-entry insert ([8ce1eed](https://github.com/acramatte/zaimu-tomo/commit/8ce1eed11182429d92ff95a22cff30b2b54818bf))
* show processing in blue so it no longer reads as posted ([aece5bf](https://github.com/acramatte/zaimu-tomo/commit/aece5bf0059db3dbbfa4e23495d9aae009a11d04))
* turn off Dialyzer's opaque check to restore the nightly run ([c7d20d1](https://github.com/acramatte/zaimu-tomo/commit/c7d20d1a73bb0c2e6ee9b597131391032bb28e32))
