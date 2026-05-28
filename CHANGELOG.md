# Changelog

## [0.20.0-rc.3](https://github.com/rjskene/pipeline/compare/v0.19.0-rc.3...v0.20.0-rc.3) (2026-05-28)


### ⚠ BREAKING CHANGES

* **spawn-claude:** PIPELINE_EVAL_ISOLATION=container removed; web-eval is inline-only. PIPELINE_EVAL_CLASSIFIER, PIPELINE_CONTAINER_SKILLS, PIPELINE_EVAL_CONTAINERS, and PIPELINE_EVAL_CONTAINER_<MODE>_* are no longer read. Operators previously opting into container dispatch should remove these vars from pipeline.config.

### Features

* **compliance-audit:** retroactive TDD-compliance backfill wrapper ([5a64f66](https://github.com/rjskene/pipeline/commit/5a64f66444c39fe6f2720c36a917f6913046a0bf)), closes [#575](https://github.com/rjskene/pipeline/issues/575)
* **compliance-audit:** retroactive TDD-compliance verdict over recent merged PRs (dogfood batch) ([73da95a](https://github.com/rjskene/pipeline/commit/73da95ab104c138049f02780b0faad4883968577))
* **dynamic-effort:** record requested model in gated runs.log write ([c410240](https://github.com/rjskene/pipeline/commit/c410240201df02a2519637c9713630f864e79479))
* **late-error-report:** implement scripts/late-error-report.sh ([#574](https://github.com/rjskene/pipeline/issues/574)) ([f052b91](https://github.com/rjskene/pipeline/commit/f052b91c5758ef93b9ffd1ac9e3e2fbc2a4e8114))
* **late-errors:** late-error measurement report — categorize merged-PR eval findings by earliest-detectable stage ([72128b9](https://github.com/rjskene/pipeline/commit/72128b99f7a3ec2326681fee72a38253b1647e0f))
* **mock-web-eval:** add 'Clear all' button markup to list section ([506eccd](https://github.com/rjskene/pipeline/commit/506eccd55515b4005ace36bcbeeeb789a5a78713))
* **mock-web-eval:** add 'Clear all' button to list section that removes all items ([526ce71](https://github.com/rjskene/pipeline/commit/526ce715b1b8157755bdc9868252a014651b6030))
* **mock-web-eval:** wire 'Clear all' handler to empty #item-list ([8973bf3](https://github.com/rjskene/pipeline/commit/8973bf39bfb099e725344420289dddf7e79d3709))
* **self-improvement:** daily metrics-snapshot time-series + host cron ([5fe2f00](https://github.com/rjskene/pipeline/commit/5fe2f00fca590471a907f3b1671519d480e00443))
* **self-improvement:** daily metrics-snapshot time-series + host cron ([53f1cd5](https://github.com/rjskene/pipeline/commit/53f1cd54ab65e6439c244d97f3a607eaf9273c92)), closes [#576](https://github.com/rjskene/pipeline/issues/576)
* **spawn-claude:** record requested model on gated runs.log write ([f9a28ff](https://github.com/rjskene/pipeline/commit/f9a28fff3605b5c6eb883e10c03994c55a81c679))


### Bug Fixes

* **review:** drop classifier from spawned-agent enumeration ([98e0f06](https://github.com/rjskene/pipeline/commit/98e0f0691d3b89cedb643c851ef868fd3516ccc2)), closes [#514](https://github.com/rjskene/pipeline/issues/514)
* **review:** quote fixture-path args and warn on worktree install-cron ([33dec8e](https://github.com/rjskene/pipeline/commit/33dec8e620b58dcb4faba715b5d7287974fe3d74))


### Code Refactoring

* **spawn-claude:** remove container isolation branch ([32f023a](https://github.com/rjskene/pipeline/commit/32f023a58589399ca182f989bb92e583a1fae8e5))

## [0.18.0](https://github.com/rjskene/pipeline/compare/v0.18.0...v0.18.0) (2026-05-26)


### release

* cut v0.4.0 (stable graduation) ([f4db262](https://github.com/rjskene/pipeline/commit/f4db26201d9c1800df99307ed01e55f7b9bd0d37))
* cut v0.4.0-rc.1 (dev channel) ([#130](https://github.com/rjskene/pipeline/issues/130)) ([b0cef7c](https://github.com/rjskene/pipeline/commit/b0cef7c10d9b7c3c93a009240c98952b526aaa06))
* cut v0.4.0-rc.2 (dev channel) ([#153](https://github.com/rjskene/pipeline/issues/153)) ([bbb1dc2](https://github.com/rjskene/pipeline/commit/bbb1dc2b08fdbf4e037477998197e3bc71d12d94))
* cut v0.4.0-rc.3 (dev channel) ([#162](https://github.com/rjskene/pipeline/issues/162)) ([80b64c6](https://github.com/rjskene/pipeline/commit/80b64c6ab3d8b1f04621d958ecf9fe9a04ac3db9))
* cut v0.5.0 (stable graduation from rc.1) ([#185](https://github.com/rjskene/pipeline/issues/185)) ([5500533](https://github.com/rjskene/pipeline/commit/5500533e506c9fc1471fad0b385ebc4727c225eb))
* cut v0.5.0-rc.1 (consumer-install hardening tracker [#178](https://github.com/rjskene/pipeline/issues/178)) ([#183](https://github.com/rjskene/pipeline/issues/183)) ([a30f0e8](https://github.com/rjskene/pipeline/commit/a30f0e83e6598e2966f5721ec5d1671604153bad))
* cut v0.6.0 (stable graduation from rc.1) ([#191](https://github.com/rjskene/pipeline/issues/191)) ([ffba3dd](https://github.com/rjskene/pipeline/commit/ffba3ddea9514734314bf0fd47a643cca9eefb3b))
* cut v0.6.0-rc.1 (consumer_drift drift report for [#187](https://github.com/rjskene/pipeline/issues/187)) ([#189](https://github.com/rjskene/pipeline/issues/189)) ([fc8ac85](https://github.com/rjskene/pipeline/commit/fc8ac854a06655dcf9d69bd5e63ce604f873a22d))
* cut v0.7.0 (stable graduation from rc.1) ([#197](https://github.com/rjskene/pipeline/issues/197)) ([0430feb](https://github.com/rjskene/pipeline/commit/0430febdb899362321df8da0856e700ff649d90d))
* cut v0.7.0-rc.1 ([#195](https://github.com/rjskene/pipeline/issues/195)) ([0fad7c4](https://github.com/rjskene/pipeline/commit/0fad7c41bdbd06c6a5dc7d2f0126b6fca3c8eee3))
* cut v0.7.1 (stable graduation from rc.1) ([#203](https://github.com/rjskene/pipeline/issues/203)) ([b961968](https://github.com/rjskene/pipeline/commit/b961968c3b9e7d22e090911dfffd7e5f0b6cfe2b))
* cut v0.7.1-rc.1 (back-sync workflow fix) ([#201](https://github.com/rjskene/pipeline/issues/201)) ([a3dd742](https://github.com/rjskene/pipeline/commit/a3dd7427035031c90aa61ba5eef3fd7fb18efbbd))
* cut v0.7.2 (stable graduation from rc.1) ([#209](https://github.com/rjskene/pipeline/issues/209)) ([0983504](https://github.com/rjskene/pipeline/commit/098350473b7dc013f32b09deb35d0650164bde7e))
* cut v0.7.2-rc.1 (back-sync regression fix) ([#207](https://github.com/rjskene/pipeline/issues/207)) ([df3246e](https://github.com/rjskene/pipeline/commit/df3246ed6ba44437d0c2b3ccd849c729eea0f4de))
* cut v0.8.0-rc.1 (dev channel) ([#228](https://github.com/rjskene/pipeline/issues/228)) ([4e2ef6f](https://github.com/rjskene/pipeline/commit/4e2ef6f79fd359e27f9dd02a5edb21be74f01c7f))
* cut v0.8.0-rc.4 from staging ([#275](https://github.com/rjskene/pipeline/issues/275)) ([b71d590](https://github.com/rjskene/pipeline/commit/b71d590d2e2f6802c98eb622c8e0b9f3f1dd72eb))
* graduate v0.18.0 to stable ([9c8ff57](https://github.com/rjskene/pipeline/commit/9c8ff570b04cb24e7863bf772696b8f318649564))
* v0.10.0-rc.1 ([#348](https://github.com/rjskene/pipeline/issues/348)) ([f3b12d4](https://github.com/rjskene/pipeline/commit/f3b12d431da7434dfa5031b55063ce479e2a29c7))
* v0.10.0-rc.2 ([#366](https://github.com/rjskene/pipeline/issues/366)) ([724254a](https://github.com/rjskene/pipeline/commit/724254a81d0629636f92b5381a508b3b8d298c82))
* v0.10.0-rc.3 ([#372](https://github.com/rjskene/pipeline/issues/372)) ([6c37159](https://github.com/rjskene/pipeline/commit/6c3715916c5897d4c632dcd0f473331955d0e176))
* v0.14.0-rc.1 (staging → main) ([#448](https://github.com/rjskene/pipeline/issues/448)) ([e572c62](https://github.com/rjskene/pipeline/commit/e572c62d971b365ddd2efff9ca4e8e383079dc27))
* v0.14.0-rc.2 (staging → main) ([#452](https://github.com/rjskene/pipeline/issues/452)) ([ea30748](https://github.com/rjskene/pipeline/commit/ea30748df5643b4c805d9618d24a84ff98c7a5a3))
* v0.14.1-rc.1 (staging → main) ([#466](https://github.com/rjskene/pipeline/issues/466)) ([d9a956a](https://github.com/rjskene/pipeline/commit/d9a956aeb168f27a355456f7c18eb353b0828ddc))
* v0.14.1-rc.2 (staging → main) ([#470](https://github.com/rjskene/pipeline/issues/470)) ([6b2a6c8](https://github.com/rjskene/pipeline/commit/6b2a6c89705d93386e52cfdd06fed53db42322f5))
* v0.14.2 (staging → main) ([#479](https://github.com/rjskene/pipeline/issues/479)) ([48999e1](https://github.com/rjskene/pipeline/commit/48999e11fea6c7c3daa475cdba6d943f34697107))
* v0.14.2-rc.1 (staging → main) ([#477](https://github.com/rjskene/pipeline/issues/477)) ([727b9be](https://github.com/rjskene/pipeline/commit/727b9bec46ac2f99dae1abdad5f87bf45bad461c))
* v0.15.0-rc.1 (staging → main) ([#485](https://github.com/rjskene/pipeline/issues/485)) ([dbfc127](https://github.com/rjskene/pipeline/commit/dbfc127f400439d98afa87c10892735afe951ae4))


### Features

* add 'full send' shortcut for autonomous end-to-end pipeline execution ([#173](https://github.com/rjskene/pipeline/issues/173)) ([85aa8e9](https://github.com/rjskene/pipeline/commit/85aa8e973d4f4bae3b639f7c67430174fb3d7d04))
* add automatic status polling to pipeline queue runner ([#151](https://github.com/rjskene/pipeline/issues/151)) ([7dc9055](https://github.com/rjskene/pipeline/commit/7dc90552e04101ad29d4e57dddbcd81644345fbb))
* add bidirectional subtree drift detection (closes rjskene/claude-pipeline[#1](https://github.com/rjskene/pipeline/issues/1)) ([e0930eb](https://github.com/rjskene/pipeline/commit/e0930eb173455448305538cbe2e70c0b57ea9172))
* add create-issues skill for brainstorming mode ([1941361](https://github.com/rjskene/pipeline/commit/1941361bbed0c2d97282ca520cd522078d3a6744)), closes [#193](https://github.com/rjskene/pipeline/issues/193)
* add dynamic issue injection to queue runner via watch file ([#175](https://github.com/rjskene/pipeline/issues/175)) ([0e6eb84](https://github.com/rjskene/pipeline/commit/0e6eb84d9fffb97e1dadcacd085ac06ceadce42e))
* add orphaned branch pruning to sync-worktrees ([#176](https://github.com/rjskene/pipeline/issues/176)) ([edac7b4](https://github.com/rjskene/pipeline/commit/edac7b425a24bb1aa32814e9513ff9aeb6e544d0))
* add PR base branch verification and retarget script ([5c9a4e7](https://github.com/rjskene/pipeline/commit/5c9a4e7d42e12a4dddffaedd2c2b9d38553e10d2))
* add PR base branch verification and retarget script ([fc1d970](https://github.com/rjskene/pipeline/commit/fc1d970c426fd480c5605222d530798c2abed19d))
* add run_in_background guidance and EVENT lines to pipeline queue runner ([#50](https://github.com/rjskene/pipeline/issues/50)) ([e9846da](https://github.com/rjskene/pipeline/commit/e9846daf2f6b8e88ccb03eae489c169a46b0b536)), closes [#38](https://github.com/rjskene/pipeline/issues/38)
* add unit tests for spawn-claude gate pre-population ([e7043e9](https://github.com/rjskene/pipeline/commit/e7043e96cb3fadbba897ab29dfeb2390c3ea7e80))
* adopt Conventional Commits and release-please automation ([#318](https://github.com/rjskene/pipeline/issues/318)) ([f71fa48](https://github.com/rjskene/pipeline/commit/f71fa4805fe292201a6731ef3f81d92d0f860f92))
* **analyze-issues:** extract --analyze mode as standalone skill + add merged-PR supersession detection ([#447](https://github.com/rjskene/pipeline/issues/447)) ([79d6509](https://github.com/rjskene/pipeline/commit/79d6509eb79796f4d0e6e802dee6a0e3b52ee106))
* **analyze:** /pipeline:run --analyze MVP — duplicate detection + standalone-fits-tracker ([#168](https://github.com/rjskene/pipeline/issues/168)) ([5a2ce81](https://github.com/rjskene/pipeline/commit/5a2ce81f0bad90843a938d8bbc2118c89f0cc5c7))
* **analyze:** missing-label signal — surface issues lacking priority or path classification ([#227](https://github.com/rjskene/pipeline/issues/227)) ([3122d4a](https://github.com/rjskene/pipeline/commit/3122d4ac862a2fbe28cb468de3b3442237eb26d9))
* change auto-status interval default from 5 to 3 minutes ([#228](https://github.com/rjskene/pipeline/issues/228)) ([18eaa62](https://github.com/rjskene/pipeline/commit/18eaa62d46f3abe0f96f2fb48d637da60d698d15))
* **classify-issue:** broaden PATH D gate + add &lt;!-- pipeline:path --&gt; body-marker override ([#354](https://github.com/rjskene/pipeline/issues/354)) ([#355](https://github.com/rjskene/pipeline/issues/355)) ([6c31fac](https://github.com/rjskene/pipeline/commit/6c31fac37f177512f07a8de65800d0b55f90c26b))
* **config:** add PIPELINE_EVAL_ISOLATION + visual-proof vars ([008ee62](https://github.com/rjskene/pipeline/commit/008ee62c37742e2449ca06d9884d39dc79474711))
* **consumer-install:** /pipeline:doctor + --fix labels — non-mutating validator + label-seeding automation ([#148](https://github.com/rjskene/pipeline/issues/148)) ([120640b](https://github.com/rjskene/pipeline/commit/120640bfe30b8a1a902b6d7a674e931d80afad74))
* **consumer-install:** post-migration CLAUDE.md cleanup — advisory report + generated patch ([#149](https://github.com/rjskene/pipeline/issues/149)) ([166fea8](https://github.com/rjskene/pipeline/commit/166fea8ea14a7b96d5704e98741124c4c9ae92c5))
* **consumer-install:** promote settings.json cleanup from advisory-only to advisory + patch ([#150](https://github.com/rjskene/pipeline/issues/150)) ([15a2ea0](https://github.com/rjskene/pipeline/commit/15a2ea07fac662483476af1d8c5fd6c9cf98b936))
* **create-issues:** auto-detect grouping with existing trackers or propose new tracker on new-issue creation ([#158](https://github.com/rjskene/pipeline/issues/158)) ([9c35a0b](https://github.com/rjskene/pipeline/commit/9c35a0bef8ffdc2c862cbd95f7d67bb8d3edeac7))
* **create-issues:** compact list preview + single batch confirmation ([#317](https://github.com/rjskene/pipeline/issues/317)) ([5e67cb0](https://github.com/rjskene/pipeline/commit/5e67cb04842c9afad2ff7deec8c2b64be40cdf0f)), closes [#316](https://github.com/rjskene/pipeline/issues/316)
* **dev-install:** auto-back-sync release commits to staging — eliminates dual-clone install ritual ([#167](https://github.com/rjskene/pipeline/issues/167)) ([b08a99a](https://github.com/rjskene/pipeline/commit/b08a99af6030a5ab08c9a76ffe061f9b585d728f))
* **docs:** system foundation — docs/process-maps.md (new) + classify-issue SKILL (PATH owner) ([#401](https://github.com/rjskene/pipeline/issues/401)) ([e7376c3](https://github.com/rjskene/pipeline/commit/e7376c3c1a1460243461145223ae3ccd0932e975))
* **doctor:** detect residual pipeline state in consumer .claude/ and CLAUDE.md (mixing with prior install) ([#180](https://github.com/rjskene/pipeline/issues/180)) ([fabf62e](https://github.com/rjskene/pipeline/commit/fabf62eeed32fac25a8bfab5706b3d72779c014f))
* **doctor:** new check container_assets_unwired — conditional contract via marker-env triangle ([#328](https://github.com/rjskene/pipeline/issues/328)) ([010e7c2](https://github.com/rjskene/pipeline/commit/010e7c283ed7cb1f31121a0ebd38371e657ae89d))
* **doctor:** per-file drift report for preserved consumer .claude/ files vs plugin-shipped ([#188](https://github.com/rjskene/pipeline/issues/188)) ([ef6ea0e](https://github.com/rjskene/pipeline/commit/ef6ea0ee751e1d21d9a9bd84f91c1a21754eb98b))
* **dogfood:** opt-in local-working-tree CLAUDE_PLUGIN_ROOT override — staging fixes shouldn't need RC cut + reinstall to reach dogfood subshells ([#387](https://github.com/rjskene/pipeline/issues/387)) ([84ee87e](https://github.com/rjskene/pipeline/commit/84ee87e661a7adb9dd139a9da457848bb7150a4b))
* **eval:** pivot screenshot attachment from release-asset to in-branch git commit ([#272](https://github.com/rjskene/pipeline/issues/272)) ([2d9fd2e](https://github.com/rjskene/pipeline/commit/2d9fd2e0680be94f260fa8f6c7450506ea9c211e))
* **evaluate-issue-pr:** add Compliance Audit sub-block — TDD artifact check (red→green git signature) ([#432](https://github.com/rjskene/pipeline/issues/432)) ([5765763](https://github.com/rjskene/pipeline/commit/576576316526eabb9d7980070f14a3026b5ec766))
* **evaluate-issue-pr:** add post-merge screenshot URL rewrite helper ([56eaa66](https://github.com/rjskene/pipeline/commit/56eaa66fc4d4de9a74797c5e0fe2bd5046663b48))
* **evaluate-issue-pr:** auto-apply manual-merge label on block-* skip ([#489](https://github.com/rjskene/pipeline/issues/489)) ([6116835](https://github.com/rjskene/pipeline/commit/6116835bbc494aa92efc68e0e2a3b3d29cbb6f0c))
* **evaluator-dispatch:** default browser-eval evaluator to inline Agent dispatch; container path retained behind PIPELINE_EVAL_ISOLATION opt-in ([0c7a27c](https://github.com/rjskene/pipeline/commit/0c7a27c29a95091288d6b80b5a36e60dbddda503))
* **execute-issue-plan:** detect CI-blocking markers in PR titles and commit subjects ([#109](https://github.com/rjskene/pipeline/issues/109)) ([b0c5176](https://github.com/rjskene/pipeline/commit/b0c5176d17be384243a9996d94f653871d9ed3dd))
* **execute-issue-pr:** CI-fix loop — re-dispatch executor on CI failure with bounded retry budget ([#113](https://github.com/rjskene/pipeline/issues/113)) ([2eb1cf9](https://github.com/rjskene/pipeline/commit/2eb1cf90bb74b932c11b7599a638f78820283bfb)), closes [#52](https://github.com/rjskene/pipeline/issues/52)
* extend review-logs.sh with subagent activity view ([f8d4ef9](https://github.com/rjskene/pipeline/commit/f8d4ef98ca7a259b58c09b8d073513e0f40480eb))
* extract reusable pipeline harness into .claude-pipeline/ ([#120](https://github.com/rjskene/pipeline/issues/120)) ([dd0c30d](https://github.com/rjskene/pipeline/commit/dd0c30d9f6c0bad14f93dcac18c0911717aad60d))
* **fullsend:** event-driven queue monitoring — stall detection + Monitor-based orchestrator wakes ([#446](https://github.com/rjskene/pipeline/issues/446)) ([b54832d](https://github.com/rjskene/pipeline/commit/b54832dfd70387b5b12513a07fb636dd9cb5345e))
* **general:** surface per-file reference report + drift-tier classification on every run ([#194](https://github.com/rjskene/pipeline/issues/194)) ([3ffdc9f](https://github.com/rjskene/pipeline/commit/3ffdc9f81a16a27d013d135958c8a3a64268e719))
* **harness-isolation:** write-nothing-to-consumer-.claude/ CI guard ([#87](https://github.com/rjskene/pipeline/issues/87)) ([fc53a6a](https://github.com/rjskene/pipeline/commit/fc53a6a33331a902b27db657ba038a6c053a0078))
* **hooks:** register log-tool-use.sh as PostToolUse hook with unified TSV format ([3b17a4a](https://github.com/rjskene/pipeline/commit/3b17a4a0798c1e748d6a9c83e088c9021e78b303))
* **hooks:** restrict_paths.py — fail-open with diagnostic, skip env-var literals in command text ([#389](https://github.com/rjskene/pipeline/issues/389)) ([fdfc424](https://github.com/rjskene/pipeline/commit/fdfc4240b5976aa02dd68b039c15b18da2907889))
* **hotfix:** add /pipeline:hotfix emergency-lane skill — in-session worktree fix bypassing lifecycle gates ([#385](https://github.com/rjskene/pipeline/issues/385)) ([c507250](https://github.com/rjskene/pipeline/commit/c50725084f54371c8da63a5b4b5840c591b0ae5a))
* increase default MAX_AGENTS from 2 to 3 ([#149](https://github.com/rjskene/pipeline/issues/149)) ([8952a3b](https://github.com/rjskene/pipeline/commit/8952a3b495e1debfcc81133fc23d776c1a3e1a22)), closes [#140](https://github.com/rjskene/pipeline/issues/140)
* **mcp:** label-gated Playwright MCP attachment for spawned agents ([#481](https://github.com/rjskene/pipeline/issues/481)) ([b673e7c](https://github.com/rjskene/pipeline/commit/b673e7c0aead2bb4b09713d076c09f5332b28421))
* **merge:** pre-merge pairwise file overlap detection for batch merges ([#451](https://github.com/rjskene/pipeline/issues/451)) ([1572f07](https://github.com/rjskene/pipeline/commit/1572f0757c98c181d66b2ddb906c9fd79822d420))
* **mock-web-eval:** add Clear button to echo section that resets input + output ([14924b4](https://github.com/rjskene/pipeline/commit/14924b455243ea0e8ea1b00cb480fc1212d4571f))
* **mock-web-eval:** add Clear button to echo section that resets input and output ([7ee2abb](https://github.com/rjskene/pipeline/commit/7ee2abb94d544604b00fa81d5756e7ca8b8c5dd6))
* **mock-web-eval:** add counter Reset button wired to zero the counter ([62bb856](https://github.com/rjskene/pipeline/commit/62bb856a97cecc5208c910a28f0bd2a0e5315ae7))
* **mock-web-eval:** attach Playwright screenshots to PR eval comments ([#266](https://github.com/rjskene/pipeline/issues/266)) ([5b19b71](https://github.com/rjskene/pipeline/commit/5b19b71e8358adc67d46779a17d72baae163e645)), closes [#264](https://github.com/rjskene/pipeline/issues/264)
* **mock-web-eval:** classifier + pipeline.config wiring + tests ([#235](https://github.com/rjskene/pipeline/issues/235)) ([8fe9b93](https://github.com/rjskene/pipeline/commit/8fe9b9342c5706e06ad3f22a7a1f6508650a5d1f)), closes [#231](https://github.com/rjskene/pipeline/issues/231)
* **mock-web-eval:** end-to-end dogfood demo PR with visible Playwright evidence ([#236](https://github.com/rjskene/pipeline/issues/236)) ([e863997](https://github.com/rjskene/pipeline/commit/e863997999bddd2a005fadcd209861031eb01212))
* **mock-web-eval:** mock web app + Dockerfile + compose surface ([#234](https://github.com/rjskene/pipeline/issues/234)) ([86917f3](https://github.com/rjskene/pipeline/commit/86917f33a69ee49f629b61736bd534f038a87acb))
* **mock-web:** add a footer with build-timestamp display ([#256](https://github.com/rjskene/pipeline/issues/256)) ([f5400af](https://github.com/rjskene/pipeline/commit/f5400afe6c70e9c6b26816f211afbbb50886f2a8))
* **mock-web:** add counter section with increment/decrement buttons ([#251](https://github.com/rjskene/pipeline/issues/251)) ([827534a](https://github.com/rjskene/pipeline/commit/827534ae4a4fc407f86fc93d588778c9a1f300e5))
* **mock-web:** set page background to soft yellow ([#274](https://github.com/rjskene/pipeline/issues/274)) ([12c4de4](https://github.com/rjskene/pipeline/commit/12c4de4f44ebd08fd10dbc821beb58060e84bae3))
* **mock-web:** style h1 with brand blue ([#268](https://github.com/rjskene/pipeline/issues/268)) ([c9a386c](https://github.com/rjskene/pipeline/commit/c9a386c5c03093f4b47cf2b81d335c5555852bbc)), closes [#267](https://github.com/rjskene/pipeline/issues/267)
* native support for consumer-defined containerized PR evaluation (web-eval-style) ([#226](https://github.com/rjskene/pipeline/issues/226)) ([9d3146f](https://github.com/rjskene/pipeline/commit/9d3146f86d6f679b91f2e20a75b2c6192c593551))
* **observability:** gate plugin log writes on PIPELINE_LOGS_ENABLED (default off) ([#324](https://github.com/rjskene/pipeline/issues/324)) ([fcbdd4f](https://github.com/rjskene/pipeline/commit/fcbdd4ff0723a2916d671f67ac9cb73a1397a157))
* **orchestrator:** ingest issue/comment attachments into local scratch dir so agents can read screenshots ([#331](https://github.com/rjskene/pipeline/issues/331)) ([c320082](https://github.com/rjskene/pipeline/commit/c320082e602667d03f3325d85bd1246be0ba03fa))
* **parse-tracker-children:** add --fallback-mentions scan mode ([4280c83](https://github.com/rjskene/pipeline/commit/4280c8388c68311dd28f2706be3e3ed28adf3534))
* **path-d:** lightweight inline TDD path for quick-fix issues ([#346](https://github.com/rjskene/pipeline/issues/346)) ([c969327](https://github.com/rjskene/pipeline/commit/c96932779fb1d99018578bc03d781431b856beee))
* pipeline batch — email, documents, UI, and pipeline tooling ([96bcf1c](https://github.com/rjskene/pipeline/commit/96bcf1c5dfbb53a870a70cf6ab076484678623a5))
* **pipeline:** add audit-superpowers.sh for cross-referencing DISPATCH claims ([e297c3f](https://github.com/rjskene/pipeline/commit/e297c3f574bb0281611a6ba3d34cf629cb0d1371))
* **pipeline:** add brainstorm label to surface non-actionable discussion issues ([#127](https://github.com/rjskene/pipeline/issues/127)) ([be152a5](https://github.com/rjskene/pipeline/commit/be152a584d72efb8bca60cdab8e9ed6124cd46f8)), closes [#28](https://github.com/rjskene/pipeline/issues/28)
* **pipeline:** add interactive subtree drift resolution with auto-reinstall ([2e8bdb2](https://github.com/rjskene/pipeline/commit/2e8bdb2f2e61d089b0cef519e442a1ce8f51b8e5))
* **pipeline:** add stale skill pruning to install.sh ([4f7ebd5](https://github.com/rjskene/pipeline/commit/4f7ebd5fe4a8601ae0478390b91c3699cffce3e2))
* **pipeline:** add superpowers audit section and SP column to review-logs.sh ([c8a7512](https://github.com/rjskene/pipeline/commit/c8a7512c43fd48e10b3ea3892a118d03574ba20c))
* **pipeline:** add superpowers usage signals to skill templates ([#60](https://github.com/rjskene/pipeline/issues/60)) ([b922d10](https://github.com/rjskene/pipeline/commit/b922d1003fe218f46efa6c5a15474d053e84a73e))
* **pipeline:** audit instrumentation + on-demand review tool ([#334](https://github.com/rjskene/pipeline/issues/334)) ([4eb35c1](https://github.com/rjskene/pipeline/commit/4eb35c15812ba1c3deef86b4590691b2ae7619df))
* **pipeline:** full send pre-thinks priority + parallel-vs-serial ordering before firing classify/plan ([#126](https://github.com/rjskene/pipeline/issues/126)) ([6624d56](https://github.com/rjskene/pipeline/commit/6624d5606ffeb360e9c18dec7cf45ce4c7bbb28c))
* **pipeline:** honor current branch as worktree base + warn on next-major-release mismatch ([#283](https://github.com/rjskene/pipeline/issues/283)) ([ee92515](https://github.com/rjskene/pipeline/commit/ee92515fb0486947dfabfcb2ac043f415c7c7f90)), closes [#278](https://github.com/rjskene/pipeline/issues/278)
* **pipeline:** interactive subtree drift resolution with auto-reinstall ([fcf93e4](https://github.com/rjskene/pipeline/commit/fcf93e4cd6c8d8382aa0e80a5330405376e895b8))
* **pipeline:** label-driven 3-path execution (TDD / trivial / SDD) ([#331](https://github.com/rjskene/pipeline/issues/331)) ([14cd181](https://github.com/rjskene/pipeline/commit/14cd181ce048adf50e1ed2c87a8371ddb4b6a111))
* **pipeline:** make tmux session name configurable via PIPELINE_TMUX_SESSION ([#64](https://github.com/rjskene/pipeline/issues/64)) ([030452d](https://github.com/rjskene/pipeline/commit/030452dbc02d52d7529208c9c2a3c20124e2c089))
* **pipeline:** orchestrator awareness of release-please PRs (autorelease: pending) ([#112](https://github.com/rjskene/pipeline/issues/112)) ([03de881](https://github.com/rjskene/pipeline/commit/03de881664856d1db8fbb7fa56b6bd9c7418866b)), closes [#51](https://github.com/rjskene/pipeline/issues/51)
* **pipeline:** Stop-hook enforces CI-wait on PR eval ([#114](https://github.com/rjskene/pipeline/issues/114)) ([5bd9cca](https://github.com/rjskene/pipeline/commit/5bd9ccac7e9e7171bfd19406357335c6ca1489b6))
* **pipeline:** wire PATH enforcement chain — classify → label → plan → execute with TDD + code review ([#286](https://github.com/rjskene/pipeline/issues/286)) ([8239b33](https://github.com/rjskene/pipeline/commit/8239b33dfcc39fa1b6a3dabdcd6607e810f126d8))
* **plan-waves:** file-conflict detection uses body substring matches — over-serializes when bodies cross-reference; also wave-plan classify+plan stages unnecessarily ([#388](https://github.com/rjskene/pipeline/issues/388)) ([291bad8](https://github.com/rjskene/pipeline/commit/291bad8250c06c8f69a11ae99d6608495cb1412e))
* **plugin:** add scripts/migrate-from-subtree.sh for existing consumers ([#83](https://github.com/rjskene/pipeline/issues/83)) ([c7ef9e8](https://github.com/rjskene/pipeline/commit/c7ef9e837f404e956083b13cfd6387d587d2d80b))
* **plugin:** migrate hooks to plugin manifest (enforce-base-branch, restrict_paths, log-tool-use, log_subagent, block_deletions, enforce-path-c-delegation) ([#82](https://github.com/rjskene/pipeline/issues/82)) ([57fb847](https://github.com/rjskene/pipeline/commit/57fb847ca567b6a5231fe1f9a1f8d879f8dcd89d))
* **plugin:** publish marketplace.json so users can install via /plugin marketplace add + /plugin install ([#84](https://github.com/rjskene/pipeline/issues/84)) ([400e52a](https://github.com/rjskene/pipeline/commit/400e52ab8dc34e34ba75ab1a5f2b6ab3bce709dc))
* **plugin:** register slash commands via plugin auto-discovery (drop .template suffix) ([#94](https://github.com/rjskene/pipeline/issues/94)) ([e2e074b](https://github.com/rjskene/pipeline/commit/e2e074ba2338382da3012b68b058af7a178b6272))
* **plugin:** runtime config loader for pipeline.config + SKILL.md.template prose rewrite ([#78](https://github.com/rjskene/pipeline/issues/78)) ([5357b51](https://github.com/rjskene/pipeline/commit/5357b51522c52098516624cc963f628457d47055))
* **plugin:** scaffold Claude Code plugin manifest + namespace slash-commands under pipeline: ([#75](https://github.com/rjskene/pipeline/issues/75)) ([c08f781](https://github.com/rjskene/pipeline/commit/c08f7814da574bbe304f7507a91d640b6bf1beee))
* pre-populate skill-gate state in spawn-claude.sh.template ([82b104b](https://github.com/rjskene/pipeline/commit/82b104b874f57dbf6f60f5254564cff540d37652))
* register subagent hook and add upstream mirrors + docs ([5c1d74d](https://github.com/rjskene/pipeline/commit/5c1d74d527469736d7948087721be3e05fa1d41f))
* **release:** catch up main — release-please integration, conventional PR titles, CI gates ([edd50d2](https://github.com/rjskene/pipeline/commit/edd50d2cc7f7faba6387ba62c14766cd16821379))
* **release:** flip skill auto-merge commands to merge-commits ([13c8994](https://github.com/rjskene/pipeline/commit/13c899482fe9177f37fe2291f6209da8463f0f69))
* **release:** install release-please workflow + config (closes [#104](https://github.com/rjskene/pipeline/issues/104)) ([#106](https://github.com/rjskene/pipeline/issues/106)) ([1f5201b](https://github.com/rjskene/pipeline/commit/1f5201b92c309aa28324b4b6ab8290680638b17e))
* **release:** prerelease channel + dev-release install ([#121](https://github.com/rjskene/pipeline/issues/121)) ([e1db4bd](https://github.com/rjskene/pipeline/commit/e1db4bdef09b65b9b7428d73faa964662525d751)), closes [#120](https://github.com/rjskene/pipeline/issues/120)
* **release:** switch to merge commits to preserve per-PR CHANGELOG entries ([3ccf15c](https://github.com/rjskene/pipeline/commit/3ccf15c1c7884869e05e09bfc44a823576326c1d))
* remove auto-merge from execute-issue skill ([#156](https://github.com/rjskene/pipeline/issues/156)) ([90dbf83](https://github.com/rjskene/pipeline/commit/90dbf834c33f26ff5231b709beffde8f4c732067)), closes [#150](https://github.com/rjskene/pipeline/issues/150)
* remove CronCreate dependency from pipeline SKILL.md ([1778f62](https://github.com/rjskene/pipeline/commit/1778f622a380f777ddf63c75ce48c6a09f7df161))
* **run-queue:** add evaluator_finished_terminal predicate ([#489](https://github.com/rjskene/pipeline/issues/489)) ([486fe75](https://github.com/rjskene/pipeline/commit/486fe75fc91cb1787d33ede2209b7d3eabb7f8a8))
* **run-queue:** emit dispatch-inline event with slate-index port broker + migration warning ([36e6799](https://github.com/rjskene/pipeline/commit/36e6799bb9001ca04e02b5a0dd29038df2710461))
* **run:** auto-merge by default when eval Approved + CI green ([#128](https://github.com/rjskene/pipeline/issues/128)) ([488035f](https://github.com/rjskene/pipeline/commit/488035f8a190c8641256f41745b78749061d0321))
* **run:** canonical status table grouped by tracker + scope ([#152](https://github.com/rjskene/pipeline/issues/152)) ([db4a88c](https://github.com/rjskene/pipeline/commit/db4a88ce663c6efcc1bc1598f6eb3d7eeea1f6a8)), closes [#133](https://github.com/rjskene/pipeline/issues/133)
* **run:** promote "full send" magic-string to /pipeline:fullsend slash command ([#161](https://github.com/rjskene/pipeline/issues/161)) ([eea9371](https://github.com/rjskene/pipeline/commit/eea9371b2d962355e050f3857616005767b6a5b0))
* **run:** sort status table by stage_rank above priority ([#434](https://github.com/rjskene/pipeline/issues/434)) ([2160e39](https://github.com/rjskene/pipeline/commit/2160e39cecef14089635768013a51cf2f0c43df0))
* **scripts:** add visual-proof-port-broker.sh ([41da058](https://github.com/rjskene/pipeline/commit/41da058e968b2876e47460492f06416e7b00a8d2))
* **scripts:** add visual-proof-server reaper ([2cd36a2](https://github.com/rjskene/pipeline/commit/2cd36a22d91fe7f539aa008bab6b3074f8888291))
* **scripts:** one-off over-eval measurement — per-PATH plan/eval verbosity vs PR diff size report ([#435](https://github.com/rjskene/pipeline/issues/435)) ([565d452](https://github.com/rjskene/pipeline/commit/565d452dd727843e334218791e70fd17fb887274))
* **self-improve:** outer-loop emits "Suggested issues" section — draft titles + bodies for /pipeline:create-issues ([#225](https://github.com/rjskene/pipeline/issues/225)) ([c044beb](https://github.com/rjskene/pipeline/commit/c044bebc65354a6f31f7f8a4895c3ee1c51e5c42))
* **self-improve:** rebuild MVP audit — interaction lens via subagent ([#217](https://github.com/rjskene/pipeline/issues/217)) ([1589484](https://github.com/rjskene/pipeline/commit/1589484b51335e43700cb4bade44aff1c7fc3229))
* **self-improve:** repo-only audit hook on /pipeline:run — 4-lens inner+outer digest, read-only MVP ([#137](https://github.com/rjskene/pipeline/issues/137)) ([fd01288](https://github.com/rjskene/pipeline/commit/fd01288bcbcd2a3aaf760a4b62073a412827a6e9))
* **spawn-claude:** isolation-gated inline browser-eval dispatch + Playwright-MCP probe ([0a3d71d](https://github.com/rjskene/pipeline/commit/0a3d71d388372dcb4f4fbe03f5ebbbd293bd7617))
* **spawn:** consumer-pluggable container hook for skill execution (e.g. evaluate-issue-pr) ([#327](https://github.com/rjskene/pipeline/issues/327)) ([e8087e9](https://github.com/rjskene/pipeline/commit/e8087e90d72721582009298fc24f16ff62a72c6e))
* **spawn:** migrate from claude -p spawn model to inline Agent-tool dispatch (no CLI, no SDK) ([#159](https://github.com/rjskene/pipeline/issues/159)) ([6c7618d](https://github.com/rjskene/pipeline/commit/6c7618dc230624742f595d4a305c93f3718bc69a))
* **tracker-lifecycle:** auto-close tracker when all child checklist items are closed ([#129](https://github.com/rjskene/pipeline/issues/129)) ([d05452c](https://github.com/rjskene/pipeline/commit/d05452c55a7eff280ad48641eea2590c98e0e6d1))
* **tracker-lifecycle:** introduce tracker label and exclude from pipeline queue ([#124](https://github.com/rjskene/pipeline/issues/124)) ([ab3a1f5](https://github.com/rjskene/pipeline/commit/ab3a1f57a1992d8f0769d990e6e6746d74cbfc12))
* **tracker-lifecycle:** scope-prefix sub-issue titles with shared topic tag ([#125](https://github.com/rjskene/pipeline/issues/125)) ([e69d284](https://github.com/rjskene/pipeline/commit/e69d284d695faf42cd7ce688466e60376af4e22b))
* **verdict:** Extract visual-proof-from-plan sub-skill; invoke from both execute-issue-plan (TDD loop) and evaluate-issue-pr (verdict) ([#482](https://github.com/rjskene/pipeline/issues/482)) ([c8e6d4f](https://github.com/rjskene/pipeline/commit/c8e6d4ff6937d00fe571bf6681ebe7ca73b3e28e))
* warn when --base omitted on non-staging/main branch ([#174](https://github.com/rjskene/pipeline/issues/174)) ([c64a7c1](https://github.com/rjskene/pipeline/commit/c64a7c1eb007225e6c637a91bf0cf0ac0e031497)), closes [#171](https://github.com/rjskene/pipeline/issues/171)


### Bug Fixes

* **_resolve-plugin-root:** lexical sort picks 0.7.2 over 0.8.0-rc.5; needs semver-aware comparator ([#291](https://github.com/rjskene/pipeline/issues/291)) ([62e640a](https://github.com/rjskene/pipeline/commit/62e640aa4ab9f6eefb881988f39986436289ca50))
* add exact Skill tool invocation syntax to pipeline skill templates ([#49](https://github.com/rjskene/pipeline/issues/49)) ([90521c9](https://github.com/rjskene/pipeline/commit/90521c928ca1a8b92cc97390adef81c7e5388afa)), closes [#45](https://github.com/rjskene/pipeline/issues/45)
* add fail-open error handling and worktree guard to gate pre-population ([d24003e](https://github.com/rjskene/pipeline/commit/d24003e14838063d053fe51adb47640ec4ce70cd))
* **analyze:** exclude same-tracker siblings + already-in-rollout from Stage 1 heuristic shortlist ([#221](https://github.com/rjskene/pipeline/issues/221)) ([2a1b80c](https://github.com/rjskene/pipeline/commit/2a1b80c301cc8cd57c540451703a555fbcb73c0c))
* **auto-close-trackers:** fall back to body #NNN scan when ## Rollout sequence missing ([4aa28d9](https://github.com/rjskene/pipeline/commit/4aa28d9b28c2660fffb3a72793501220a6db7242))
* **auto-close-trackers:** trackers without '## Rollout sequence' checklist skipped even when all children closed ([a338f7f](https://github.com/rjskene/pipeline/commit/a338f7fb1acd9d524018a0c0f1f0e0fe391eb865))
* **auto-merge-gate:** silent block-ci when jq is missing — should fail loudly or doctor should check ([#281](https://github.com/rjskene/pipeline/issues/281)) ([2e4ddfb](https://github.com/rjskene/pipeline/commit/2e4ddfbed9882a16e9c708846ad4219083df1bcb))
* **ci:** migrate release-please action to googleapis/release-please-action@v4 ([#440](https://github.com/rjskene/pipeline/issues/440)) ([e53d343](https://github.com/rjskene/pipeline/commit/e53d343842509b30c230178437b66c0841a9407e))
* **classifier:** repoint eval-classifier-invoke.sh resolution to ${CLAUDE_PLUGIN_ROOT} in run-queue.sh + spawn-claude.sh ([#292](https://github.com/rjskene/pipeline/issues/292) family) ([#371](https://github.com/rjskene/pipeline/issues/371)) ([2af9248](https://github.com/rjskene/pipeline/commit/2af9248e27cc07ce7789092aaffb47e536a1f2e8))
* **config:** guard pipeline.config mock-web-eval paths against refactor drift ([#357](https://github.com/rjskene/pipeline/issues/357)) ([be8309f](https://github.com/rjskene/pipeline/commit/be8309f5f8e780e05db3b0a40d62d4a59795229c))
* **create-checkpoint-tag:** _find_main_repo trips on stray pipeline.config inside plugin tree ([#282](https://github.com/rjskene/pipeline/issues/282)) ([9f08041](https://github.com/rjskene/pipeline/commit/9f080411a096ef2c47ff0618d4fa6d5ededfdac2))
* **create-checkpoint-tag:** path math off-by-one breaks dogfood invocation from ./scripts/ ([#245](https://github.com/rjskene/pipeline/issues/245)) ([353141f](https://github.com/rjskene/pipeline/commit/353141f12c48b9067533083ceaa142e0661c6c66))
* **derive-pr-title:** non-canonical conventional-commit types double-prefix to chore(general): instead of normalizing the type and preserving the scope ([c2cdcd7](https://github.com/rjskene/pipeline/commit/c2cdcd7da4ba8a61c41bedd46972e2bd9d670f4d))
* **derive-pr-title:** normalize non-canonical conventional-commit types ([#507](https://github.com/rjskene/pipeline/issues/507)) ([f2288ff](https://github.com/rjskene/pipeline/commit/f2288ff058751c78ac9143f5570249439dfeed78))
* **derive-pr-title:** normalize titles so path-escape substrings don't trip restrict_paths.py on gh pr create ([#363](https://github.com/rjskene/pipeline/issues/363)) ([4362676](https://github.com/rjskene/pipeline/commit/436267623c2b88f4dc13167ee3457a30f48b0ea2))
* **doctor:** claude_md_residual misses dangling .claude/{scripts,hooks,skills}/ refs (detective complement to [#177](https://github.com/rjskene/pipeline/issues/177)) ([#370](https://github.com/rjskene/pipeline/issues/370)) ([3a8688d](https://github.com/rjskene/pipeline/commit/3a8688df83089e2415f048b38ccd9a52f1b40a73))
* **doctor:** filter build artifacts + soften claude_plugin_root warn on self-resolve success ([#222](https://github.com/rjskene/pipeline/issues/222)) ([868f73d](https://github.com/rjskene/pipeline/commit/868f73d4ea1f7c25e32d83e1b399b6c2944e4259))
* **doctor:** path-aware allow-list + recognize consumer-required scripts (don't propose deletion) ([#220](https://github.com/rjskene/pipeline/issues/220)) ([01ae9bd](https://github.com/rjskene/pipeline/commit/01ae9bdc97f9eb1bc98ba20fc8fc68df3136d2b2))
* **dogfood:** consumer .claude/scripts/* silently drifted from plugin rc.2 — doctor missed it ([#258](https://github.com/rjskene/pipeline/issues/258)) ([a8784a6](https://github.com/rjskene/pipeline/commit/a8784a6734fb0dfab72f785ec755f84fe5d8affa)), closes [#252](https://github.com/rjskene/pipeline/issues/252)
* **enforce-base-branch:** PR base escapes to `main` when hook not installed at consumer ([#300](https://github.com/rjskene/pipeline/issues/300)) ([99e956b](https://github.com/rjskene/pipeline/commit/99e956b65e41888d41f936edd48230434dddce6d))
* **evaluate-issue-pr:** autonomous greenlight auto-merge collapses Option A screenshot review window — eval-comment URLs 404 before any human sees them ([c36c381](https://github.com/rjskene/pipeline/commit/c36c381b44eae720eafa11e317458eabe3424797))
* **evaluate-issue-pr:** rewrite screenshot URLs to merge-SHA post auto-merge ([45ff742](https://github.com/rjskene/pipeline/commit/45ff742eed7fc470e6641636df8530f24e8e213d))
* **executor-stall:** bound inner-Claude sentinel-file polls in execute-issue-plan ([#468](https://github.com/rjskene/pipeline/issues/468)) ([ae786fa](https://github.com/rjskene/pipeline/commit/ae786fa120fa863fea3127551e3ef0203c5b856d))
* **executor-stall:** run-queue stall detection samples parent claude PID only, misses subtree wedge ([#469](https://github.com/rjskene/pipeline/issues/469)) ([2d98b8f](https://github.com/rjskene/pipeline/commit/2d98b8f18fdf5dfad0ac13e75d32aaede9e4970a))
* **general:** evaluate-issue-pr screenshots never render in PR comments (relative paths + git commit fails inside container sandbox) ([#483](https://github.com/rjskene/pipeline/issues/483)) ([d8f4abc](https://github.com/rjskene/pipeline/commit/d8f4abcc7d3f310d38424c0e72f1d960383da145))
* **general:** setup-worktree.sh invocation underspecified, breaks run-queue worktree lookup ([#391](https://github.com/rjskene/pipeline/issues/391)) ([4ce5a76](https://github.com/rjskene/pipeline/commit/4ce5a76f1538fa1865bb7b9edb46579d1b752ecc))
* **hooks:** add CLAUDE_PROJECT_DIR fallback, Glob null guard, and header comment ([aef4ef2](https://github.com/rjskene/pipeline/commit/aef4ef267af017c92430a51f284130a482c9ac2e))
* **hooks:** guard log-tool-use.sh against missing jq ([#412](https://github.com/rjskene/pipeline/issues/412)) ([#436](https://github.com/rjskene/pipeline/issues/436)) ([38e6752](https://github.com/rjskene/pipeline/commit/38e6752f386a3c17cba97d3ca90c3f81a6b8226d))
* **hooks:** prevent subagent JSON overwrite on same-second collision ([0536db9](https://github.com/rjskene/pipeline/commit/0536db9830b8472c8bc642aafb870d40450b6e46))
* **hooks:** self-resolve CLAUDE_PLUGIN_ROOT in skill Boot blocks ([#339](https://github.com/rjskene/pipeline/issues/339)) ([#364](https://github.com/rjskene/pipeline/issues/364)) ([13f24a6](https://github.com/rjskene/pipeline/commit/13f24a6ddb9c22864de8a9a096d52d1100dd5ba2))
* **hooks:** sync log-tool-use.sh template + honor .claude/base-branch in enforce-base-branch ([6c11678](https://github.com/rjskene/pipeline/commit/6c116789c07721e7bb35b94eb0a8f2d0e785180e))
* **migrate:** implement --patch settings rewrite logic (currently report-only) ([#224](https://github.com/rjskene/pipeline/issues/224)) ([21b80e6](https://github.com/rjskene/pipeline/commit/21b80e61d5fa5123d09a8c8d89c048af76b7b6bb))
* **migrate:** leaves dangling .claude/scripts/ references in consumer CLAUDE.md ([#182](https://github.com/rjskene/pipeline/issues/182)) ([40736fc](https://github.com/rjskene/pipeline/commit/40736fcfa5c5158cc2f4640464513d69462df544))
* **migrate:** migrate-from-subtree.sh skips unmarked skill/agent duplicates (marker-gate gap) ([#181](https://github.com/rjskene/pipeline/issues/181)) ([09eec21](https://github.com/rjskene/pipeline/commit/09eec215cb63d0cc230598450d02a1dab559eafb))
* **mock-web-eval:** demonstrator broken in dogfood at 3 wiring layers (env-file, --manual-merge, .mcp.json) ([#259](https://github.com/rjskene/pipeline/issues/259)) ([028c255](https://github.com/rjskene/pipeline/commit/028c255a264f1b4264be277d5853b7778f5555a5))
* **mock-web-eval:** env-file write-path and spawn-claude resolution-path disagree ([#280](https://github.com/rjskene/pipeline/issues/280)) ([52ef838](https://github.com/rjskene/pipeline/commit/52ef8381f78f0d0ff514b7e7aee7b66bf34b7ba0))
* **mock-web-eval:** handle GID/UID 1000 collision with node base image ([#239](https://github.com/rjskene/pipeline/issues/239)) ([e446282](https://github.com/rjskene/pipeline/commit/e446282db3b59112f7c340c6222620402d36d043)), closes [#237](https://github.com/rjskene/pipeline/issues/237)
* **mock-web-eval:** plugin slash commands not discoverable inside container ([#242](https://github.com/rjskene/pipeline/issues/242)) ([e8b6f93](https://github.com/rjskene/pipeline/commit/e8b6f9382a1d20d93bb7ebecaad5216b4cf87b1e))
* **mock-web-eval:** regression of [#241](https://github.com/rjskene/pipeline/issues/241) — /pipeline:* slash commands again not discoverable inside container ([fd30837](https://github.com/rjskene/pipeline/commit/fd30837f6b39b9e74fe812c40b1709c90540817f))
* **mock-web-eval:** restore /pipeline:* discoverability inside container ([#505](https://github.com/rjskene/pipeline/issues/505)) ([ed7e6d3](https://github.com/rjskene/pipeline/commit/ed7e6d3927a1ac7646b5e965199e88ce5b8d2544))
* **pipeline:** add CI status gate to evaluate-issue-pr skill ([#215](https://github.com/rjskene/pipeline/issues/215)) ([f9d557c](https://github.com/rjskene/pipeline/commit/f9d557c077764116a074063adb501f6051318dcd))
* **pipeline:** add Skill case to log-tool-use.sh with session ID ([cfcbed4](https://github.com/rjskene/pipeline/commit/cfcbed49d12f74500bd0d22ad0a1eb0dcc4d2275))
* **pipeline:** add verification gate for plan-issue comment posting ([d4bf739](https://github.com/rjskene/pipeline/commit/d4bf739f927c2eb5bce7b12a827e1b03fff999c5)), closes [#88](https://github.com/rjskene/pipeline/issues/88)
* **pipeline:** enforce superpowers skill dispatch — agents claim usage without dispatching ([7db7e45](https://github.com/rjskene/pipeline/commit/7db7e45c4476e2a480ddb77b23350b9c1af89ddb))
* **pipeline:** guard stale skill pruning with .pipeline-managed marker ([74e287f](https://github.com/rjskene/pipeline/commit/74e287fec365df61d6641cb70cfdc65f1f462373))
* **pipeline:** PATH C enforcement hygiene — cache TTL, trivial-target guard, log mtime filter ([#339](https://github.com/rjskene/pipeline/issues/339)) ([ef34b05](https://github.com/rjskene/pipeline/commit/ef34b05d9ec246c543df95eb3d47ef1b87d78afc))
* **pipeline:** plan-issue subagent returns plan body but skips gh issue comment + label-add ([#462](https://github.com/rjskene/pipeline/issues/462)) ([58130a1](https://github.com/rjskene/pipeline/commit/58130a13fa3411a2c8f22ce043181f202bf0ce63))
* **pipeline:** plan-issue verification gate for comment posting ([2267e33](https://github.com/rjskene/pipeline/commit/2267e335b34de350d8d4a66c0c49c573d1e94b44))
* **pipeline:** replace (optional) with (use if available, fallback if not) in superpowers comments ([7a49e63](https://github.com/rjskene/pipeline/commit/7a49e639ef61e800eb2720f36ab932b5cb3cdac5))
* **pipeline:** replace announce-string pattern with explicit Skill() calls — remove skill_gate hook + pipeline-config.json ([0e71f5b](https://github.com/rjskene/pipeline/commit/0e71f5bafdeb1df29e0293fde289213ae6d48d23)), closes [#126](https://github.com/rjskene/pipeline/issues/126)
* **pipeline:** replace commit-counting LOCAL_AHEAD with tree comparison ([eb40ec2](https://github.com/rjskene/pipeline/commit/eb40ec2e3b417733308812d717fc01b8623967b3)), closes [#61](https://github.com/rjskene/pipeline/issues/61)
* **pipeline:** replace freeform superpowers announcements with structured DISPATCH/SKIP evidence model ([e553efa](https://github.com/rjskene/pipeline/commit/e553efa9bbff273e38a74e89c5cc3fd504144fdc))
* **pipeline:** review-audits.sh reads worktree tool-use.log, not main repo ([#344](https://github.com/rjskene/pipeline/issues/344)) ([e65ccc7](https://github.com/rjskene/pipeline/commit/e65ccc7712efd32e7046b6b8a42a6f659676f7eb)), closes [#341](https://github.com/rjskene/pipeline/issues/341)
* **pipeline:** run-queue.sh + spawn-claude.sh print log paths even when PIPELINE_LOGS_ENABLED=false ([#461](https://github.com/rjskene/pipeline/issues/461)) ([7474f67](https://github.com/rjskene/pipeline/commit/7474f6703019bc5c5d7084910258e38c2651385a))
* **pipeline:** spawn-claude.sh macOS compat — absolute paths and script syntax ([#58](https://github.com/rjskene/pipeline/issues/58)) ([5ca0321](https://github.com/rjskene/pipeline/commit/5ca032162204638d5f4844b4087aa3eb1ddba91d)), closes [#48](https://github.com/rjskene/pipeline/issues/48)
* **pipeline:** treat same-second classify+label-bump as fresh in cache check ([#460](https://github.com/rjskene/pipeline/issues/460)) ([682a8da](https://github.com/rjskene/pipeline/commit/682a8dacc1c4e8250f5c143b0c273b824195260e))
* **plan-issue:** skill occasionally drafts plan but fails to post comment to issue ([#123](https://github.com/rjskene/pipeline/issues/123)) ([b9e51b4](https://github.com/rjskene/pipeline/commit/b9e51b408d1c3743825c5a99fd4173a40c7f407f))
* **plan-issue:** tighten skill prose so PATH C agents post their plan instead of returning text for the orchestrator ([#330](https://github.com/rjskene/pipeline/issues/330)) ([ab5267e](https://github.com/rjskene/pipeline/commit/ab5267eb6cdec022b497f624acf393a730478610))
* **plugin:** drop hard superpowers dependency from plugin.json (closes [#102](https://github.com/rjskene/pipeline/issues/102)) ([#103](https://github.com/rjskene/pipeline/issues/103)) ([e15ca5b](https://github.com/rjskene/pipeline/commit/e15ca5b44e7a715e1b78949e38b7a918d2bb2734))
* **plugin:** revert spawn-claude.sh slash to bare /&lt;skill&gt; ([#76](https://github.com/rjskene/pipeline/issues/76)) ([60e2be7](https://github.com/rjskene/pipeline/commit/60e2be7b8229b9689eea7e9cf920c875e275a37c))
* **plugin:** self-resolve CLAUDE_PLUGIN_ROOT when env var is unset in Bash subshells ([#179](https://github.com/rjskene/pipeline/issues/179)) ([35c2b83](https://github.com/rjskene/pipeline/commit/35c2b83bb2b109d9e4cfe125d82dc375fe26fb15))
* queue-status.sh crash kills queue runner on every poll cycle ([707660a](https://github.com/rjskene/pipeline/commit/707660a864fb1a1f30e7d49630ed145a3e882496))
* **queue-status:** recurring 'could not locate consumer repo' error during queue poll ([3ce8d8d](https://github.com/rjskene/pipeline/commit/3ce8d8db76198644b6ebc0f9c9790549088ed8ff))
* **queue-status:** resolve pipeline.config from project root instead of plugin root (same path-math family as [#277](https://github.com/rjskene/pipeline/issues/277)) ([#358](https://github.com/rjskene/pipeline/issues/358)) ([64513d8](https://github.com/rjskene/pipeline/commit/64513d865f8efc84185dcf525a8adc21f43a2ec4))
* **release:** back-sync workflow's -X ours discards release-please version bumps (regression from [#200](https://github.com/rjskene/pipeline/issues/200)) ([#206](https://github.com/rjskene/pipeline/issues/206)) ([c973ce8](https://github.com/rjskene/pipeline/commit/c973ce8cd95fbc6e1701bd375eff7a3f7edfd9e5))
* **release:** eliminate recurring back-sync divergence conflicts on RC cuts (staging→main) ([#200](https://github.com/rjskene/pipeline/issues/200)) ([8df8c92](https://github.com/rjskene/pipeline/commit/8df8c92eb1b757b827de9e9d591ab03b53ceeae2))
* remove skill-gate remnants — spawn template block, gate test, audit script ([a79ba56](https://github.com/rjskene/pipeline/commit/a79ba565a325d34ae025db6204c171a294b76168))
* **review-audits:** repoint TDD_IMPLEMENTER_MARKER to plugin root, not consumer .claude/ ([#351](https://github.com/rjskene/pipeline/issues/351)) ([aecb809](https://github.com/rjskene/pipeline/commit/aecb809dad9ec666b02484bb9e79fa73f8c2b791))
* **review-logs:** resolve log dir from project root instead of plugin root (same path-math family as [#277](https://github.com/rjskene/pipeline/issues/277)) ([#289](https://github.com/rjskene/pipeline/issues/289)) ([a1d786e](https://github.com/rjskene/pipeline/commit/a1d786e046665d87e03681c9d629e91db7f6c33e))
* **review:** cross-reference [#505](https://github.com/rjskene/pipeline/issues/505) in the [#241](https://github.com/rjskene/pipeline/issues/241) root-cause comment block ([#505](https://github.com/rjskene/pipeline/issues/505)) ([32e447a](https://github.com/rjskene/pipeline/commit/32e447a76751d664dca2d688b9d08681e709b0c4))
* **review:** guard evaluator predicate against gh null PR lookup ([#489](https://github.com/rjskene/pipeline/issues/489)) ([d475265](https://github.com/rjskene/pipeline/commit/d4752654a405e2bfda8f24140d51cd4b45796441))
* **review:** set exec bit on test-rewrite-eval-screenshot-urls.sh for consistency ([a8a8929](https://github.com/rjskene/pipeline/commit/a8a8929dd26dd874b414a92ef4f044635e3adde8))
* **run-queue:** classify_issue uses gh 'linked:&lt;N&gt;' qualifier which returns unrelated PRs, blocking execute dispatch with container-mode rejection ([2ddd2c6](https://github.com/rjskene/pipeline/commit/2ddd2c61f709010809d26490f7aa48c1a0179d25))
* **run-queue:** do not bump BUCKET_ACTIVE on inline dispatch (allow multi-issue slates) ([6a7170b](https://github.com/rjskene/pipeline/commit/6a7170b08e6d787b845d2c8810a668913730d082))
* **run-queue:** gate evaluator_finished_terminal label arm on Evaluation comment ([cd46b13](https://github.com/rjskene/pipeline/commit/cd46b13e13d5b8ff55588251da6b29adaa16af8e))
* **run-queue:** propagate PIPELINE_PROJECT_ROOT to queue-status poll helper ([1ad1dae](https://github.com/rjskene/pipeline/commit/1ad1daed42015f4f53ec0a3fe556755245e3eb66)), closes [#490](https://github.com/rjskene/pipeline/issues/490)
* **run-queue:** runner hangs after evaluator completes without auto-merge (eval verdict Approved + manual-merge flag) ([dc1308e](https://github.com/rjskene/pipeline/commit/dc1308efa0f2e0b615ade6b2f6dc589b1e10bf29))
* **run-queue:** treat evaluator verdict + manual-merge as terminal ([#489](https://github.com/rjskene/pipeline/issues/489)) ([41aecea](https://github.com/rjskene/pipeline/commit/41aecea8874ce67f19c0546493e6f6740d465c82))
* **run-skill:** housekeeping subshells lose PIPELINE_REPO — auto-close-trackers silently no-ops every run ([#290](https://github.com/rjskene/pipeline/issues/290)) ([84b93f7](https://github.com/rjskene/pipeline/commit/84b93f796c4436b0ac00f463cdcb6b637ad34425))
* **run:** fail loud when trackers.json shape is wrong + inline build snippet so EPICS section renders children ([#431](https://github.com/rjskene/pipeline/issues/431)) ([569a249](https://github.com/rjskene/pipeline/commit/569a249ba443913b3c1035b98301c71436378c5f))
* **run:** mandate orchestrator reprint status table into assistant reply ([#424](https://github.com/rjskene/pipeline/issues/424)) ([c23f098](https://github.com/rjskene/pipeline/commit/c23f0986999f3eac17882beee7459b772f039dc4))
* **run:** mandate orchestrator reprint status table into assistant reply ([#424](https://github.com/rjskene/pipeline/issues/424)) ([#426](https://github.com/rjskene/pipeline/issues/426)) ([cc79f61](https://github.com/rjskene/pipeline/commit/cc79f61bc2c9de3768e4aead688ae770d518ebc5))
* **self-audit:** use grep -m1 to avoid SIGPIPE on large transcripts ([#265](https://github.com/rjskene/pipeline/issues/265)) ([#279](https://github.com/rjskene/pipeline/issues/279)) ([e86b1c9](https://github.com/rjskene/pipeline/commit/e86b1c940098f8b38aaf731cbe7b92b126bc0512))
* **settings:** point $schema to schemastore canonical URL ([#142](https://github.com/rjskene/pipeline/issues/142)) ([8c2d72f](https://github.com/rjskene/pipeline/commit/8c2d72fe9a02a0f1d25accfcdfc255025e6c3993))
* **spawn-claude:** accept UPPERCASE PIPELINE_EVAL_CONTAINER_&lt;MODE&gt;_* via shared helper ([#390](https://github.com/rjskene/pipeline/issues/390)) ([5187153](https://github.com/rjskene/pipeline/commit/5187153afaba39cf0e477881176012dd8c0d278f))
* **spawn-claude:** bare-host eval pre-empts container dispatch when --container-mode is missing ([#243](https://github.com/rjskene/pipeline/issues/243)) ([7d0e289](https://github.com/rjskene/pipeline/commit/7d0e289b8f8d01f888b0d0543d89114a98c2c0ad))
* **spawn-claude:** empty-MCP file at /tmp/ collides with container mode — host path unreachable inside container, evaluator exits in &lt;1s ([4137c32](https://github.com/rjskene/pipeline/commit/4137c32ffaf5365dca9d2a51cac620406d448506))
* **spawn-claude:** exit 0 early on inline branch instead of falling through ([01f8424](https://github.com/rjskene/pipeline/commit/01f84246ee882d0a74ad7ff827ed7855cfc3175c))
* **spawn-claude:** namespace slash invocation to /pipeline:${SKILL} (closes [#100](https://github.com/rjskene/pipeline/issues/100)) ([#101](https://github.com/rjskene/pipeline/issues/101)) ([563764d](https://github.com/rjskene/pipeline/commit/563764d825c81428e1ecff8600bec4f776df89e3))
* **spawn-claude:** skip empty-MCP branch under container mode ([#516](https://github.com/rjskene/pipeline/issues/516)) ([ad6c9ce](https://github.com/rjskene/pipeline/commit/ad6c9ce228edd31f135d214361b37547b3415f76))
* **tests:** exclude CHANGELOG.md from removed-file guard (unbreaks release CI) ([#117](https://github.com/rjskene/pipeline/issues/117)) ([a93c9ca](https://github.com/rjskene/pipeline/commit/a93c9ca8be427892ab0dac599855fd6610ff5579))
* **tests:** remove broken test-path-c-args-directive.sh (closes [#88](https://github.com/rjskene/pipeline/issues/88)) ([#105](https://github.com/rjskene/pipeline/issues/105)) ([9827cb1](https://github.com/rjskene/pipeline/commit/9827cb1872914714471673c87295653f18268b1b))
* **tests:** scrub PIPELINE_* from run_helper env to prevent fixture leak ([#425](https://github.com/rjskene/pipeline/issues/425)) ([#433](https://github.com/rjskene/pipeline/issues/433)) ([b3c0b83](https://github.com/rjskene/pipeline/commit/b3c0b83348367c46c768dfdd539a72e2dbe9b6d6))
* **tests:** test-ci-fix-loop.sh flakes in full-suite, passes isolated — likely state leakage ([#369](https://github.com/rjskene/pipeline/issues/369)) ([0223a8e](https://github.com/rjskene/pipeline/commit/0223a8ee1a669b51d42686c63e2272c7792bf0cd))
* **tests:** unbreak release CI on main — exclude CHANGELOG self-reference + drop hard-coded version ([bb4d240](https://github.com/rjskene/pipeline/commit/bb4d2403c86ad97a79024e28fe4a80e94afee7ed))
* use mktemp for audit-superpowers.sh temp files ([96218f7](https://github.com/rjskene/pipeline/commit/96218f74a471643f5a95ae53a1f5c52842454f20))
* use mktemp in evaluate-issue Phase 2b inline audit + revert scope creep ([dfee011](https://github.com/rjskene/pipeline/commit/dfee0113ad88879f04d85678211277163c309ceb))
* **worktree-tools:** accept bare wt-&lt;N&gt; basename in cleanup-worktree.sh discovery ([#365](https://github.com/rjskene/pipeline/issues/365)) ([1be2cd5](https://github.com/rjskene/pipeline/commit/1be2cd5917ed190987cefdaba4cbff0bef88eaae))


### Performance Improvements

* **run:** move status-table render from SKILL.md prose into scripts/render-status-table.sh ([#386](https://github.com/rjskene/pipeline/issues/386)) ([f5f47ff](https://github.com/rjskene/pipeline/commit/f5f47ffa2272e0c2b1428451cc9cefd2f34e7242))
* **run:** quiet git pull + scope merged-PR lookup to active-worktree branches in step 0/1 ([#352](https://github.com/rjskene/pipeline/issues/352)) ([71855e6](https://github.com/rjskene/pipeline/commit/71855e6f2ca5f37e201c1f44a95d5d8fd7b84226))
* **run:** trim SKILL.md by moving examples and analyze-mode spec to references/ ([#376](https://github.com/rjskene/pipeline/issues/376)) ([40767ca](https://github.com/rjskene/pipeline/commit/40767caa9a4f09352a505ff23878a1b75d922d6d))


### Miscellaneous Chores

* cut v0.8.0-rc.2 — mock-web-eval demonstrator wave + dogfood fixes ([#246](https://github.com/rjskene/pipeline/issues/246)) ([8d87332](https://github.com/rjskene/pipeline/commit/8d8733238b16e1a85d7574344e8c57d65f4e1cb1))
* cut v0.8.0-rc.3 — mock-web-eval smoke-test wave + doctor/wiring fixes ([#262](https://github.com/rjskene/pipeline/issues/262)) ([5542995](https://github.com/rjskene/pipeline/commit/5542995eb8784f55251b0fbc013edc25580f43c3))
* cut v0.8.0-rc.5 — bundle five staging PRs ([#279](https://github.com/rjskene/pipeline/issues/279), [#280](https://github.com/rjskene/pipeline/issues/280), [#281](https://github.com/rjskene/pipeline/issues/281), [#282](https://github.com/rjskene/pipeline/issues/282), [#283](https://github.com/rjskene/pipeline/issues/283)) ([a1ebfaa](https://github.com/rjskene/pipeline/commit/a1ebfaaa942bac7420165312981bdaf40969e6a2))
* cut v0.8.0-rc.6 — bundle three staging PRs ([#289](https://github.com/rjskene/pipeline/issues/289), [#290](https://github.com/rjskene/pipeline/issues/290), [#291](https://github.com/rjskene/pipeline/issues/291)) ([21d883d](https://github.com/rjskene/pipeline/commit/21d883d296bfb0a14df60e3d21134f03eb4bd244))
* cut v0.8.1 stable patch — hotfix [#295](https://github.com/rjskene/pipeline/issues/295) enforce-base-branch defense-in-depth ([e2034d9](https://github.com/rjskene/pipeline/commit/e2034d947b122e0796962520eeee12eb018e84e8))
* cut v0.8.2 stable patch — repo-transfer URL retarget ([55c7afe](https://github.com/rjskene/pipeline/commit/55c7afe97a33b4136a965a1788427467bbb434af))
* cut v0.8.3 stable patch — pre-public legacy-identity scrub ([968909e](https://github.com/rjskene/pipeline/commit/968909e114fde5c3d01542c06e98d17f7ee73b87))
* cut v0.9.0-rc.1 ([#332](https://github.com/rjskene/pipeline/issues/332)) ([f28ed9c](https://github.com/rjskene/pipeline/commit/f28ed9c3216bbcb722b3f6663f3c6187aafc7703))
* graduate v0.5.0-rc.1 to v0.5.0 stable ([74248fc](https://github.com/rjskene/pipeline/commit/74248fc96efaa223705e437f6fb55e854573b2d5))
* graduate v0.6.0-rc.1 to v0.6.0 stable ([7c1b220](https://github.com/rjskene/pipeline/commit/7c1b2203b13f26ce046bd0a0ce7456600b968433))
* graduate v0.7.0-rc.1 to v0.7.0 stable ([44a5521](https://github.com/rjskene/pipeline/commit/44a55218abeb7a3c9baa835184d604b52f61e7f6))
* graduate v0.7.1-rc.1 to v0.7.1 stable ([b3547aa](https://github.com/rjskene/pipeline/commit/b3547aa0c8138b1aa7e4cb0b5cf4d341d0bdf0e8))
* graduate v0.7.2-rc.1 to v0.7.2 stable ([9b05199](https://github.com/rjskene/pipeline/commit/9b05199bc7beb928567e3a2c4a3e7876897ca678))
* graduate v0.8.0-rc.6 to v0.8.0 stable ([f669109](https://github.com/rjskene/pipeline/commit/f66910918241ee84f08e4bcf139432b96ff0b784))
* graduate v0.9.0 stable ([#334](https://github.com/rjskene/pipeline/issues/334)) ([a0d2761](https://github.com/rjskene/pipeline/commit/a0d2761c9e018c18f8a4cf475f7dcefae74cfea6))
* release v0.14.0 ([6fd9cd9](https://github.com/rjskene/pipeline/commit/6fd9cd9aecc2710c37a04dafbd99b3829f02f8d2))
* **release:** cut 0.4.0-rc.4 ([56e3c94](https://github.com/rjskene/pipeline/commit/56e3c940987d566f5808e6ca1c346ed36cdc4bda))
* **release:** cut v0.11.0-rc.1 ([#392](https://github.com/rjskene/pipeline/issues/392)) ([3a49266](https://github.com/rjskene/pipeline/commit/3a4926642c53a2312b0378be1617b7da69a40027))
* **release:** cut v0.13.0-rc.1 ([#438](https://github.com/rjskene/pipeline/issues/438)) ([a9e72ea](https://github.com/rjskene/pipeline/commit/a9e72ea63899eadee422113cf0fc9f26ba361898))
* **release:** graduate v0.12.0 stable ([#409](https://github.com/rjskene/pipeline/issues/409)) ([a0c6f39](https://github.com/rjskene/pipeline/commit/a0c6f39921a1c2c91d383e214b840c5bef5e7365))
* **release:** graduate v0.13.0 stable ([#443](https://github.com/rjskene/pipeline/issues/443)) ([efdd001](https://github.com/rjskene/pipeline/commit/efdd001f0b67629d3490605e242a05fd12d64450))
* **release:** graduate v0.14.1-rc.2 to v0.14.1 ([702cb34](https://github.com/rjskene/pipeline/commit/702cb34140f00efd20ceca9aa7e8edc1eff53805))
* **release:** v0.10.0 — graduate rc series to stable ([e93debd](https://github.com/rjskene/pipeline/commit/e93debd34a07c41dd766a71bcaffa9fcf71a6dce))
* **release:** v0.10.0-rc.4 — docs polish + path-A fullsend hardening ([5448a1c](https://github.com/rjskene/pipeline/commit/5448a1c4f55e5651d0b68c132dbbb8c1fe30503b))

## [0.18.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.17.0-rc.1...v0.18.0-rc.1) (2026-05-26)


### Features

* **config:** add PIPELINE_EVAL_ISOLATION + visual-proof vars ([008ee62](https://github.com/rjskene/pipeline/commit/008ee62c37742e2449ca06d9884d39dc79474711))
* **evaluate-issue-pr:** add post-merge screenshot URL rewrite helper ([56eaa66](https://github.com/rjskene/pipeline/commit/56eaa66fc4d4de9a74797c5e0fe2bd5046663b48))
* **evaluator-dispatch:** default browser-eval evaluator to inline Agent dispatch; container path retained behind PIPELINE_EVAL_ISOLATION opt-in ([0c7a27c](https://github.com/rjskene/pipeline/commit/0c7a27c29a95091288d6b80b5a36e60dbddda503))
* **mock-web-eval:** add counter Reset button wired to zero the counter ([62bb856](https://github.com/rjskene/pipeline/commit/62bb856a97cecc5208c910a28f0bd2a0e5315ae7))
* **run-queue:** emit dispatch-inline event with slate-index port broker + migration warning ([36e6799](https://github.com/rjskene/pipeline/commit/36e6799bb9001ca04e02b5a0dd29038df2710461))
* **scripts:** add visual-proof-port-broker.sh ([41da058](https://github.com/rjskene/pipeline/commit/41da058e968b2876e47460492f06416e7b00a8d2))
* **scripts:** add visual-proof-server reaper ([2cd36a2](https://github.com/rjskene/pipeline/commit/2cd36a22d91fe7f539aa008bab6b3074f8888291))
* **spawn-claude:** isolation-gated inline browser-eval dispatch + Playwright-MCP probe ([0a3d71d](https://github.com/rjskene/pipeline/commit/0a3d71d388372dcb4f4fbe03f5ebbbd293bd7617))


### Bug Fixes

* **derive-pr-title:** non-canonical conventional-commit types double-prefix to chore(general): instead of normalizing the type and preserving the scope ([c2cdcd7](https://github.com/rjskene/pipeline/commit/c2cdcd7da4ba8a61c41bedd46972e2bd9d670f4d))
* **derive-pr-title:** normalize non-canonical conventional-commit types ([#507](https://github.com/rjskene/pipeline/issues/507)) ([f2288ff](https://github.com/rjskene/pipeline/commit/f2288ff058751c78ac9143f5570249439dfeed78))
* **evaluate-issue-pr:** autonomous greenlight auto-merge collapses Option A screenshot review window — eval-comment URLs 404 before any human sees them ([c36c381](https://github.com/rjskene/pipeline/commit/c36c381b44eae720eafa11e317458eabe3424797))
* **evaluate-issue-pr:** rewrite screenshot URLs to merge-SHA post auto-merge ([45ff742](https://github.com/rjskene/pipeline/commit/45ff742eed7fc470e6641636df8530f24e8e213d))
* **mock-web-eval:** regression of [#241](https://github.com/rjskene/pipeline/issues/241) — /pipeline:* slash commands again not discoverable inside container ([fd30837](https://github.com/rjskene/pipeline/commit/fd30837f6b39b9e74fe812c40b1709c90540817f))
* **mock-web-eval:** restore /pipeline:* discoverability inside container ([#505](https://github.com/rjskene/pipeline/issues/505)) ([ed7e6d3](https://github.com/rjskene/pipeline/commit/ed7e6d3927a1ac7646b5e965199e88ce5b8d2544))
* **review:** cross-reference [#505](https://github.com/rjskene/pipeline/issues/505) in the [#241](https://github.com/rjskene/pipeline/issues/241) root-cause comment block ([#505](https://github.com/rjskene/pipeline/issues/505)) ([32e447a](https://github.com/rjskene/pipeline/commit/32e447a76751d664dca2d688b9d08681e709b0c4))
* **review:** set exec bit on test-rewrite-eval-screenshot-urls.sh for consistency ([a8a8929](https://github.com/rjskene/pipeline/commit/a8a8929dd26dd874b414a92ef4f044635e3adde8))
* **run-queue:** classify_issue uses gh 'linked:&lt;N&gt;' qualifier which returns unrelated PRs, blocking execute dispatch with container-mode rejection ([2ddd2c6](https://github.com/rjskene/pipeline/commit/2ddd2c61f709010809d26490f7aa48c1a0179d25))
* **run-queue:** do not bump BUCKET_ACTIVE on inline dispatch (allow multi-issue slates) ([6a7170b](https://github.com/rjskene/pipeline/commit/6a7170b08e6d787b845d2c8810a668913730d082))
* **spawn-claude:** empty-MCP file at /tmp/ collides with container mode — host path unreachable inside container, evaluator exits in &lt;1s ([4137c32](https://github.com/rjskene/pipeline/commit/4137c32ffaf5365dca9d2a51cac620406d448506))
* **spawn-claude:** exit 0 early on inline branch instead of falling through ([01f8424](https://github.com/rjskene/pipeline/commit/01f84246ee882d0a74ad7ff827ed7855cfc3175c))
* **spawn-claude:** skip empty-MCP branch under container mode ([#516](https://github.com/rjskene/pipeline/issues/516)) ([ad6c9ce](https://github.com/rjskene/pipeline/commit/ad6c9ce228edd31f135d214361b37547b3415f76))

## [0.17.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.16.0-rc.1...v0.17.0-rc.1) (2026-05-25)


### Features

* **evaluate-issue-pr:** auto-apply manual-merge label on block-* skip ([#489](https://github.com/rjskene/pipeline/issues/489)) ([6116835](https://github.com/rjskene/pipeline/commit/6116835bbc494aa92efc68e0e2a3b3d29cbb6f0c))
* **parse-tracker-children:** add --fallback-mentions scan mode ([4280c83](https://github.com/rjskene/pipeline/commit/4280c8388c68311dd28f2706be3e3ed28adf3534))
* **run-queue:** add evaluator_finished_terminal predicate ([#489](https://github.com/rjskene/pipeline/issues/489)) ([486fe75](https://github.com/rjskene/pipeline/commit/486fe75fc91cb1787d33ede2209b7d3eabb7f8a8))


### Bug Fixes

* **auto-close-trackers:** fall back to body #NNN scan when ## Rollout sequence missing ([4aa28d9](https://github.com/rjskene/pipeline/commit/4aa28d9b28c2660fffb3a72793501220a6db7242))
* **auto-close-trackers:** trackers without '## Rollout sequence' checklist skipped even when all children closed ([a338f7f](https://github.com/rjskene/pipeline/commit/a338f7fb1acd9d524018a0c0f1f0e0fe391eb865))
* **queue-status:** recurring 'could not locate consumer repo' error during queue poll ([3ce8d8d](https://github.com/rjskene/pipeline/commit/3ce8d8db76198644b6ebc0f9c9790549088ed8ff))
* **review:** guard evaluator predicate against gh null PR lookup ([#489](https://github.com/rjskene/pipeline/issues/489)) ([d475265](https://github.com/rjskene/pipeline/commit/d4752654a405e2bfda8f24140d51cd4b45796441))
* **run-queue:** gate evaluator_finished_terminal label arm on Evaluation comment ([cd46b13](https://github.com/rjskene/pipeline/commit/cd46b13e13d5b8ff55588251da6b29adaa16af8e))
* **run-queue:** propagate PIPELINE_PROJECT_ROOT to queue-status poll helper ([1ad1dae](https://github.com/rjskene/pipeline/commit/1ad1daed42015f4f53ec0a3fe556755245e3eb66)), closes [#490](https://github.com/rjskene/pipeline/issues/490)
* **run-queue:** runner hangs after evaluator completes without auto-merge (eval verdict Approved + manual-merge flag) ([dc1308e](https://github.com/rjskene/pipeline/commit/dc1308efa0f2e0b615ade6b2f6dc589b1e10bf29))
* **run-queue:** treat evaluator verdict + manual-merge as terminal ([#489](https://github.com/rjskene/pipeline/issues/489)) ([41aecea](https://github.com/rjskene/pipeline/commit/41aecea8874ce67f19c0546493e6f6740d465c82))

## [0.16.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.15.0-rc.1...v0.16.0-rc.1) (2026-05-25)


### Features

* **release:** switch to merge commits to preserve per-PR CHANGELOG entries ([3ccf15c](https://github.com/rjskene/pipeline/commit/3ccf15c1c7884869e05e09bfc44a823576326c1d))

## [0.15.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.14.2...v0.15.0-rc.1) (2026-05-25)


### release

* v0.15.0-rc.1 (staging → main) ([#485](https://github.com/rjskene/pipeline/issues/485)) ([dbfc127](https://github.com/rjskene/pipeline/commit/dbfc127f400439d98afa87c10892735afe951ae4))

## [0.14.2](https://github.com/rjskene/pipeline/compare/v0.14.2-rc.1...v0.14.2) (2026-05-24)


### release

* v0.14.2 (staging → main) ([#479](https://github.com/rjskene/pipeline/issues/479)) ([48999e1](https://github.com/rjskene/pipeline/commit/48999e11fea6c7c3daa475cdba6d943f34697107))

## [0.14.2-rc.1](https://github.com/rjskene/pipeline/compare/v0.14.1...v0.14.2-rc.1) (2026-05-24)


### release

* v0.14.2-rc.1 (staging → main) ([#477](https://github.com/rjskene/pipeline/issues/477)) ([727b9be](https://github.com/rjskene/pipeline/commit/727b9bec46ac2f99dae1abdad5f87bf45bad461c))

## [0.14.1](https://github.com/rjskene/pipeline/compare/v0.14.1-rc.2...v0.14.1) (2026-05-24)


### Miscellaneous Chores

* **release:** graduate v0.14.1-rc.2 to v0.14.1 ([702cb34](https://github.com/rjskene/pipeline/commit/702cb34140f00efd20ceca9aa7e8edc1eff53805))

## [0.14.1-rc.2](https://github.com/rjskene/pipeline/compare/v0.14.1-rc.1...v0.14.1-rc.2) (2026-05-24)


### release

* v0.14.1-rc.2 (staging → main) ([#470](https://github.com/rjskene/pipeline/issues/470)) ([6b2a6c8](https://github.com/rjskene/pipeline/commit/6b2a6c89705d93386e52cfdd06fed53db42322f5))

## [0.14.1-rc.1](https://github.com/rjskene/pipeline/compare/v0.14.0...v0.14.1-rc.1) (2026-05-24)


### release

* v0.14.1-rc.1 (staging → main) ([#466](https://github.com/rjskene/pipeline/issues/466)) ([d9a956a](https://github.com/rjskene/pipeline/commit/d9a956aeb168f27a355456f7c18eb353b0828ddc))

## [0.14.0](https://github.com/rjskene/pipeline/compare/v0.14.0-rc.2...v0.14.0) (2026-05-24)


### Miscellaneous Chores

* release v0.14.0 ([6fd9cd9](https://github.com/rjskene/pipeline/commit/6fd9cd9aecc2710c37a04dafbd99b3829f02f8d2))

## [0.14.0-rc.2](https://github.com/rjskene/pipeline/compare/v0.14.0-rc.1...v0.14.0-rc.2) (2026-05-23)


### release

* v0.14.0-rc.2 (staging → main) ([#452](https://github.com/rjskene/pipeline/issues/452)) ([ea30748](https://github.com/rjskene/pipeline/commit/ea30748df5643b4c805d9618d24a84ff98c7a5a3))

## [0.14.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.13.0...v0.14.0-rc.1) (2026-05-23)


### release

* v0.14.0-rc.1 (staging → main) ([#448](https://github.com/rjskene/pipeline/issues/448)) ([e572c62](https://github.com/rjskene/pipeline/commit/e572c62d971b365ddd2efff9ca4e8e383079dc27))

## [0.13.0](https://github.com/rjskene/pipeline/compare/v0.13.0-rc.1...v0.13.0) (2026-05-23)


### Miscellaneous Chores

* **release:** graduate v0.13.0 stable ([#443](https://github.com/rjskene/pipeline/issues/443)) ([efdd001](https://github.com/rjskene/pipeline/commit/efdd001f0b67629d3490605e242a05fd12d64450))

## [0.13.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.12.1-rc.1...v0.13.0-rc.1) (2026-05-23)


### Miscellaneous Chores

* **release:** cut v0.13.0-rc.1 ([#438](https://github.com/rjskene/pipeline/issues/438)) ([a9e72ea](https://github.com/rjskene/pipeline/commit/a9e72ea63899eadee422113cf0fc9f26ba361898))

## [0.12.1-rc.1](https://github.com/rjskene/pipeline/compare/v0.12.0...v0.12.1-rc.1) (2026-05-22)


### Bug Fixes

* **run:** mandate orchestrator reprint status table into assistant reply ([#424](https://github.com/rjskene/pipeline/issues/424)) ([#426](https://github.com/rjskene/pipeline/issues/426)) ([cc79f61](https://github.com/rjskene/pipeline/commit/cc79f61bc2c9de3768e4aead688ae770d518ebc5))

## [0.12.0](https://github.com/rjskene/pipeline/compare/v0.12.0-rc.1...v0.12.0) (2026-05-22)


### Miscellaneous Chores

* **release:** graduate v0.12.0 stable ([#409](https://github.com/rjskene/pipeline/issues/409)) ([a0c6f39](https://github.com/rjskene/pipeline/commit/a0c6f39921a1c2c91d383e214b840c5bef5e7365))

## [0.12.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.11.0-rc.1...v0.12.0-rc.1) (2026-05-22)


### Features

* **docs:** system foundation — docs/process-maps.md (new) + classify-issue SKILL (PATH owner) ([#401](https://github.com/rjskene/pipeline/issues/401)) ([e7376c3](https://github.com/rjskene/pipeline/commit/e7376c3c1a1460243461145223ae3ccd0932e975))

## [0.11.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.10.0...v0.11.0-rc.1) (2026-05-22)


### Miscellaneous Chores

* **release:** cut v0.11.0-rc.1 ([#392](https://github.com/rjskene/pipeline/issues/392)) ([3a49266](https://github.com/rjskene/pipeline/commit/3a4926642c53a2312b0378be1617b7da69a40027))

## [0.10.0](https://github.com/rjskene/pipeline/compare/v0.10.0-rc.4...v0.10.0) (2026-05-21)


### Miscellaneous Chores

* **release:** v0.10.0 — graduate rc series to stable ([#380](https://github.com/rjskene/pipeline/issues/380)) ([e93debd](https://github.com/rjskene/pipeline/commit/e93debd34a07c41dd766a71bcaffa9fcf71a6dce))

## [0.10.0-rc.4](https://github.com/rjskene/pipeline/compare/v0.10.0-rc.3...v0.10.0-rc.4) (2026-05-21)


### Miscellaneous Chores

* **release:** v0.10.0-rc.4 — docs polish + path-A fullsend hardening ([#378](https://github.com/rjskene/pipeline/issues/378)) ([5448a1c](https://github.com/rjskene/pipeline/commit/5448a1c4f55e5651d0b68c132dbbb8c1fe30503b))

## [0.10.0-rc.3](https://github.com/rjskene/pipeline/compare/v0.10.0-rc.2...v0.10.0-rc.3) (2026-05-21)


### release

* v0.10.0-rc.3 ([#372](https://github.com/rjskene/pipeline/issues/372)) ([6c37159](https://github.com/rjskene/pipeline/commit/6c3715916c5897d4c632dcd0f473331955d0e176))

## [0.10.0-rc.2](https://github.com/rjskene/pipeline/compare/v0.10.0-rc.1...v0.10.0-rc.2) (2026-05-21)


### release

* v0.10.0-rc.2 ([#366](https://github.com/rjskene/pipeline/issues/366)) ([724254a](https://github.com/rjskene/pipeline/commit/724254a81d0629636f92b5381a508b3b8d298c82))

## [0.10.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.9.0...v0.10.0-rc.1) (2026-05-20)


### release

* v0.10.0-rc.1 ([#348](https://github.com/rjskene/pipeline/issues/348)) ([f3b12d4](https://github.com/rjskene/pipeline/commit/f3b12d431da7434dfa5031b55063ce479e2a29c7))

## [0.9.0](https://github.com/rjskene/pipeline/compare/v0.9.0-rc.1...v0.9.0) (2026-05-20)


### Miscellaneous Chores

* graduate v0.9.0 stable ([#334](https://github.com/rjskene/pipeline/issues/334)) ([a0d2761](https://github.com/rjskene/pipeline/commit/a0d2761c9e018c18f8a4cf475f7dcefae74cfea6))

## [0.9.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.8.3...v0.9.0-rc.1) (2026-05-20)


### Miscellaneous Chores

* cut v0.9.0-rc.1 ([#332](https://github.com/rjskene/pipeline/issues/332)) ([f28ed9c](https://github.com/rjskene/pipeline/commit/f28ed9c3216bbcb722b3f6663f3c6187aafc7703))

## [0.8.3](https://github.com/rjskene/pipeline/compare/v0.8.2...v0.8.3) (2026-05-19)


### Miscellaneous Chores

* cut v0.8.3 stable patch — pre-public legacy-identity scrub ([#307](https://github.com/rjskene/pipeline/issues/307)) ([968909e](https://github.com/rjskene/pipeline/commit/968909e114fde5c3d01542c06e98d17f7ee73b87))

## [0.8.2](https://github.com/rjskene/pipeline/compare/v0.8.1...v0.8.2) (2026-05-19)


### Miscellaneous Chores

* cut v0.8.2 stable patch — repo-transfer URL retarget ([#304](https://github.com/rjskene/pipeline/issues/304)) ([55c7afe](https://github.com/rjskene/pipeline/commit/55c7afe97a33b4136a965a1788427467bbb434af))

## [0.8.1](https://github.com/rjskene/pipeline/compare/v0.8.0...v0.8.1) (2026-05-18)


### Miscellaneous Chores

* cut v0.8.1 stable patch — hotfix [#295](https://github.com/rjskene/pipeline/issues/295) enforce-base-branch defense-in-depth ([#301](https://github.com/rjskene/pipeline/issues/301)) ([e2034d9](https://github.com/rjskene/pipeline/commit/e2034d947b122e0796962520eeee12eb018e84e8))

## [0.8.0](https://github.com/rjskene/pipeline/compare/v0.8.0-rc.6...v0.8.0) (2026-05-18)


### Miscellaneous Chores

* graduate v0.8.0-rc.6 to v0.8.0 stable ([#298](https://github.com/rjskene/pipeline/issues/298)) ([f669109](https://github.com/rjskene/pipeline/commit/f66910918241ee84f08e4bcf139432b96ff0b784))

## [0.8.0-rc.6](https://github.com/rjskene/pipeline/compare/v0.8.0-rc.5...v0.8.0-rc.6) (2026-05-18)


### Miscellaneous Chores

* cut v0.8.0-rc.6 — bundle three staging PRs ([#296](https://github.com/rjskene/pipeline/issues/296)) ([21d883d](https://github.com/rjskene/pipeline/commit/21d883d296bfb0a14df60e3d21134f03eb4bd244))

## [0.8.0-rc.5](https://github.com/rjskene/pipeline/compare/v0.8.0-rc.4...v0.8.0-rc.5) (2026-05-18)


### Miscellaneous Chores

* cut v0.8.0-rc.5 — bundle five staging PRs ([#284](https://github.com/rjskene/pipeline/issues/284)) ([a1ebfaa](https://github.com/rjskene/pipeline/commit/a1ebfaaa942bac7420165312981bdaf40969e6a2))

## [0.8.0-rc.4](https://github.com/rjskene/pipeline/compare/v0.8.0-rc.3...v0.8.0-rc.4) (2026-05-18)


### release

* cut v0.8.0-rc.4 from staging ([#275](https://github.com/rjskene/pipeline/issues/275)) ([b71d590](https://github.com/rjskene/pipeline/commit/b71d590d2e2f6802c98eb622c8e0b9f3f1dd72eb))

## [0.8.0-rc.3](https://github.com/rjskene/pipeline/compare/v0.8.0-rc.2...v0.8.0-rc.3) (2026-05-18)


### Miscellaneous Chores

* cut v0.8.0-rc.3 — mock-web-eval smoke-test wave + doctor/wiring fixes ([#262](https://github.com/rjskene/pipeline/issues/262)) ([5542995](https://github.com/rjskene/pipeline/commit/5542995eb8784f55251b0fbc013edc25580f43c3))

## [0.8.0-rc.2](https://github.com/rjskene/pipeline/compare/v0.8.0-rc.1...v0.8.0-rc.2) (2026-05-18)


### Miscellaneous Chores

* cut v0.8.0-rc.2 — mock-web-eval demonstrator wave + dogfood fixes ([#246](https://github.com/rjskene/pipeline/issues/246)) ([8d87332](https://github.com/rjskene/pipeline/commit/8d8733238b16e1a85d7574344e8c57d65f4e1cb1))

## [0.8.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.7.2...v0.8.0-rc.1) (2026-05-17)


### release

* cut v0.8.0-rc.1 (dev channel) ([#228](https://github.com/rjskene/pipeline/issues/228)) ([4e2ef6f](https://github.com/rjskene/pipeline/commit/4e2ef6f79fd359e27f9dd02a5edb21be74f01c7f))

## [0.7.2](https://github.com/rjskene/pipeline/compare/v0.7.2-rc.1...v0.7.2) (2026-05-17)


### release

* cut v0.7.2 (stable graduation from rc.1) ([#209](https://github.com/rjskene/pipeline/issues/209)) ([0983504](https://github.com/rjskene/pipeline/commit/098350473b7dc013f32b09deb35d0650164bde7e))

## [0.7.2-rc.1](https://github.com/rjskene/pipeline/compare/v0.7.1...v0.7.2-rc.1) (2026-05-17)


### release

* cut v0.7.2-rc.1 (back-sync regression fix) ([#207](https://github.com/rjskene/pipeline/issues/207)) ([df3246e](https://github.com/rjskene/pipeline/commit/df3246ed6ba44437d0c2b3ccd849c729eea0f4de))

## [0.7.1](https://github.com/rjskene/pipeline/compare/v0.7.0...v0.7.1) (2026-05-17)


### release

* cut v0.7.1 (stable graduation from rc.1) ([#203](https://github.com/rjskene/pipeline/issues/203)) ([b961968](https://github.com/rjskene/pipeline/commit/b961968c3b9e7d22e090911dfffd7e5f0b6cfe2b))
* cut v0.7.1-rc.1 (back-sync workflow fix) ([#201](https://github.com/rjskene/pipeline/issues/201)) ([a3dd742](https://github.com/rjskene/pipeline/commit/a3dd7427035031c90aa61ba5eef3fd7fb18efbbd))

## [0.7.0](https://github.com/rjskene/pipeline/compare/v0.7.0-rc.1...v0.7.0) (2026-05-16)


### release

* cut v0.7.0 (stable graduation from rc.1) ([#197](https://github.com/rjskene/pipeline/issues/197)) ([0430feb](https://github.com/rjskene/pipeline/commit/0430febdb899362321df8da0856e700ff649d90d))

## [0.7.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.6.0...v0.7.0-rc.1) (2026-05-16)


### release

* cut v0.7.0-rc.1 ([#195](https://github.com/rjskene/pipeline/issues/195)) ([0fad7c4](https://github.com/rjskene/pipeline/commit/0fad7c41bdbd06c6a5dc7d2f0126b6fca3c8eee3))

## [0.6.0](https://github.com/rjskene/pipeline/compare/v0.6.0-rc.1...v0.6.0) (2026-05-16)


### release

* cut v0.6.0 (stable graduation from rc.1) ([#191](https://github.com/rjskene/pipeline/issues/191)) ([ffba3dd](https://github.com/rjskene/pipeline/commit/ffba3ddea9514734314bf0fd47a643cca9eefb3b))

## [0.6.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.5.0...v0.6.0-rc.1) (2026-05-16)


### release

* cut v0.6.0-rc.1 (consumer_drift drift report for [#187](https://github.com/rjskene/pipeline/issues/187)) ([#189](https://github.com/rjskene/pipeline/issues/189)) ([fc8ac85](https://github.com/rjskene/pipeline/commit/fc8ac854a06655dcf9d69bd5e63ce604f873a22d))

## [0.5.0](https://github.com/rjskene/pipeline/compare/v0.5.0-rc.1...v0.5.0) (2026-05-16)


### release

* cut v0.5.0 (stable graduation from rc.1) ([#185](https://github.com/rjskene/pipeline/issues/185)) ([5500533](https://github.com/rjskene/pipeline/commit/5500533e506c9fc1471fad0b385ebc4727c225eb))

## [0.5.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.4.0...v0.5.0-rc.1) (2026-05-16)


### release

* cut v0.5.0-rc.1 (consumer-install hardening tracker [#178](https://github.com/rjskene/pipeline/issues/178)) ([#183](https://github.com/rjskene/pipeline/issues/183)) ([a30f0e8](https://github.com/rjskene/pipeline/commit/a30f0e83e6598e2966f5721ec5d1671604153bad))

## [0.4.0](https://github.com/rjskene/pipeline/compare/v0.4.0-rc.4...v0.4.0) (2026-05-15)


### release

* cut v0.4.0 (stable graduation) ([f4db262](https://github.com/rjskene/pipeline/commit/f4db26201d9c1800df99307ed01e55f7b9bd0d37))

## [0.4.0-rc.4](https://github.com/rjskene/pipeline/compare/v0.4.0-rc.3...v0.4.0-rc.4) (2026-05-15)


### Miscellaneous Chores

* **release:** cut 0.4.0-rc.4 ([56e3c94](https://github.com/rjskene/pipeline/commit/56e3c940987d566f5808e6ca1c346ed36cdc4bda))

## [0.4.0-rc.3](https://github.com/rjskene/pipeline/compare/v0.4.0-rc.2...v0.4.0-rc.3) (2026-05-15)


### release

* cut v0.4.0-rc.3 (dev channel) ([#162](https://github.com/rjskene/pipeline/issues/162)) ([80b64c6](https://github.com/rjskene/pipeline/commit/80b64c6ab3d8b1f04621d958ecf9fe9a04ac3db9))

## [0.4.0-rc.2](https://github.com/rjskene/pipeline/compare/v0.4.0-rc.1...v0.4.0-rc.2) (2026-05-15)


### release

* cut v0.4.0-rc.2 (dev channel) ([#153](https://github.com/rjskene/pipeline/issues/153)) ([bbb1dc2](https://github.com/rjskene/pipeline/commit/bbb1dc2b08fdbf4e037477998197e3bc71d12d94))

## [0.4.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.3.1...v0.4.0-rc.1) (2026-05-15)


### release

* cut v0.4.0-rc.1 (dev channel) ([#130](https://github.com/rjskene/pipeline/issues/130)) ([b0cef7c](https://github.com/rjskene/pipeline/commit/b0cef7c10d9b7c3c93a009240c98952b526aaa06))

## [0.3.1](https://github.com/rjskene/pipeline/compare/v0.3.0...v0.3.1) (2026-05-14)


### Bug Fixes

* **tests:** exclude CHANGELOG.md from removed-file guard (unbreaks release CI) ([#117](https://github.com/rjskene/pipeline/issues/117)) ([a93c9ca](https://github.com/rjskene/pipeline/commit/a93c9ca8be427892ab0dac599855fd6610ff5579))

## [0.3.0](https://github.com/rjskene/pipeline/compare/v0.2.0...v0.3.0) (2026-05-14)


### Features

* **execute-issue-plan:** detect CI-blocking markers in PR titles and commit subjects ([#109](https://github.com/rjskene/pipeline/issues/109)) ([b0c5176](https://github.com/rjskene/pipeline/commit/b0c5176d17be384243a9996d94f653871d9ed3dd))
* **execute-issue-pr:** CI-fix loop — re-dispatch executor on CI failure with bounded retry budget ([#113](https://github.com/rjskene/pipeline/issues/113)) ([2eb1cf9](https://github.com/rjskene/pipeline/commit/2eb1cf90bb74b932c11b7599a638f78820283bfb)), closes [#52](https://github.com/rjskene/pipeline/issues/52)
* **pipeline:** orchestrator awareness of release-please PRs (autorelease: pending) ([#112](https://github.com/rjskene/pipeline/issues/112)) ([03de881](https://github.com/rjskene/pipeline/commit/03de881664856d1db8fbb7fa56b6bd9c7418866b)), closes [#51](https://github.com/rjskene/pipeline/issues/51)
* **pipeline:** Stop-hook enforces CI-wait on PR eval ([#114](https://github.com/rjskene/pipeline/issues/114)) ([5bd9cca](https://github.com/rjskene/pipeline/commit/5bd9ccac7e9e7171bfd19406357335c6ca1489b6))
* **plugin:** register slash commands via plugin auto-discovery (drop .template suffix) ([#94](https://github.com/rjskene/pipeline/issues/94)) ([e2e074b](https://github.com/rjskene/pipeline/commit/e2e074ba2338382da3012b68b058af7a178b6272))
* **release:** install release-please workflow + config (closes [#104](https://github.com/rjskene/pipeline/issues/104)) ([#106](https://github.com/rjskene/pipeline/issues/106)) ([1f5201b](https://github.com/rjskene/pipeline/commit/1f5201b92c309aa28324b4b6ab8290680638b17e))


### Bug Fixes

* **plugin:** drop hard superpowers dependency from plugin.json (closes [#102](https://github.com/rjskene/pipeline/issues/102)) ([#103](https://github.com/rjskene/pipeline/issues/103)) ([e15ca5b](https://github.com/rjskene/pipeline/commit/e15ca5b44e7a715e1b78949e38b7a918d2bb2734))
* **spawn-claude:** namespace slash invocation to /pipeline:${SKILL} (closes [#100](https://github.com/rjskene/pipeline/issues/100)) ([#101](https://github.com/rjskene/pipeline/issues/101)) ([563764d](https://github.com/rjskene/pipeline/commit/563764d825c81428e1ecff8600bec4f776df89e3))
* **tests:** remove broken test-path-c-args-directive.sh (closes [#88](https://github.com/rjskene/pipeline/issues/88)) ([#105](https://github.com/rjskene/pipeline/issues/105)) ([9827cb1](https://github.com/rjskene/pipeline/commit/9827cb1872914714471673c87295653f18268b1b))
