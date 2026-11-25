# Changelog

## [0.3.0](https://github.com/acramatte/zaimu-tomo/compare/v0.2.1...v0.3.0) (2026-11-25)


### Features

* **accounts:** add current and credit card account types and share the upload store ([#137](https://github.com/acramatte/zaimu-tomo/issues/137)) ([95f5497](https://github.com/acramatte/zaimu-tomo/commit/95f549767aef37e3c136d2599f00044d8aa4b556))
* add a pure matcher for statement lines and journal entries ([f0a5d15](https://github.com/acramatte/zaimu-tomo/commit/f0a5d15269a77dda91bb3fa3457898d400437d9f))
* reconcile statement lines against the journal ([f87d853](https://github.com/acramatte/zaimu-tomo/commit/f87d85398d66883744567582c5456bef1e1ee8ad))
* retry the extraction verifier as its own durable job ([22c7ddc](https://github.com/acramatte/zaimu-tomo/commit/22c7ddc43de5c700b11fc937d0bd35ae207edb6e))
* show statements and their lines ([3b4c27b](https://github.com/acramatte/zaimu-tomo/commit/3b4c27be640670f48c88a3bc2e7c6254f5ba0b74))
* **statements:** enforce statement invariants in Postgres ([37bf7b5](https://github.com/acramatte/zaimu-tomo/commit/37bf7b534519974197b03bcb31be0acc0c35f02b))
* **statements:** handle discarded extract jobs and trace statement runs ([f015bfb](https://github.com/acramatte/zaimu-tomo/commit/f015bfb3ab29e1979c61458e1c42e6ebeaa18026))
* **statements:** read one statement page with the extractor ([34e7295](https://github.com/acramatte/zaimu-tomo/commit/34e7295de6db3f1447db851f69d3b3ddb8762124))
* **statements:** store uploaded statements and extract lines with Oban ([f15164b](https://github.com/acramatte/zaimu-tomo/commit/f15164baad1e866425094dc134a7d3b2a10a41c5))


### Bug Fixes

* accept an invoice whose items give no reason for payment ([9888437](https://github.com/acramatte/zaimu-tomo/commit/9888437b85e4973b4216b674c8c6b795ca237ce5))
* copy the v2 invoice prompts into the local templates ([5d534e3](https://github.com/acramatte/zaimu-tomo/commit/5d534e343b393aa12d830db70658386a7692e1ac))
* stack statement lines on narrow screens ([a0db010](https://github.com/acramatte/zaimu-tomo/commit/a0db010c7283fb0f6a927908b43d1525f957a19a))
* **statements:** harden reconciliation queries, Matcher, PubSub, and backing UI ([136ecb0](https://github.com/acramatte/zaimu-tomo/commit/136ecb0436e261074d428e75e062e3b60d4ef18e))
* **statements:** harden statement pages, ProcessingRefresh, and failure descriptions ([4440d03](https://github.com/acramatte/zaimu-tomo/commit/4440d03a16e8d2c2f335a7961cac4180b9f69436))
* update phoenix, phoenix_live_view and db_connection for advisories ([77b06dd](https://github.com/acramatte/zaimu-tomo/commit/77b06dd862ceab24a716da9ec8c415f8ddd4fb3b))


### Refactoring

* **live:** model ProcessingRefresh as :idle | {:scheduled, ref} with on_tick/2 ([5d32ae0](https://github.com/acramatte/zaimu-tomo/commit/5d32ae0e25ac6553f0227ac73485fa709366b2d1))
* share the processing refresh between live pages ([215ae6d](https://github.com/acramatte/zaimu-tomo/commit/215ae6d8240ec2512022370b097d8f23b0f728fe))
* **statements:** tag credit rows explicitly as :credit in Reconciliation.backing ([b0b6365](https://github.com/acramatte/zaimu-tomo/commit/b0b6365b55c4d9453a48a0a0d83ca5b2d7d5999c))

## [0.2.1](https://github.com/acramatte/zaimu-tomo/compare/v0.2.0...v0.2.1) (2026-11-20)


### Bug Fixes

* cap extractor output explicitly and record finish reason in Langfuse ([9a43266](https://github.com/acramatte/zaimu-tomo/commit/9a432668d0e4cec5d824d6d6919bff22c9d80d20))
* give extractor calls a realistic timeout and stop duplicate retries ([8fa08f6](https://github.com/acramatte/zaimu-tomo/commit/8fa08f6823e4e0690a98594de0ba24303593440f))
* give the verifier a realistic timeout and cap its retries ([2f50494](https://github.com/acramatte/zaimu-tomo/commit/2f5049420b62083241aa07e9333499e020f033d5))
* tell users when the extraction service timed out ([d210247](https://github.com/acramatte/zaimu-tomo/commit/d210247a5341b71174be61a751abc445d6d0b418))

## [0.2.0](https://github.com/acramatte/zaimu-tomo/compare/v0.1.0...v0.2.0) (2026-11-17)


### Features

* add text search to the journal entries page ([d616905](https://github.com/acramatte/zaimu-tomo/commit/d61690514b444c1758e57234d2151fc689c6b4f7))
