# Changelog

## [0.21.5](https://github.com/rjskene/pipeline/compare/v0.21.4...v0.21.5) (2026-06-01)


### Features

* **classify:** read path-hint as overridable prior + record override rationale ([#759](https://github.com/rjskene/pipeline/issues/759)) ([3521d31](https://github.com/rjskene/pipeline/commit/3521d31fadb1264532ab3c888abc73ebcc0f569d))
* **create-classify:** make create-issues path-aware via advisory path-hint marker ([940667f](https://github.com/rjskene/pipeline/commit/940667f114f6e1be263df2ca71f276aa41b8e333))
* **create-issues:** emit advisory path-hint marker on clear A/B/C signal ([#759](https://github.com/rjskene/pipeline/issues/759)) ([d0e5f1f](https://github.com/rjskene/pipeline/commit/d0e5f1f216909d33528d664b24492a91f434c491))


### Bug Fixes

* **classify:** condense path-hint parse block + bump SKILL line cap to 290 ([#759](https://github.com/rjskene/pipeline/issues/759)) ([ec07c00](https://github.com/rjskene/pipeline/commit/ec07c00accda9c21275c71e1f3b3127afcf1488b))

## [0.21.4](https://github.com/rjskene/pipeline/compare/v0.21.3...v0.21.4) (2026-06-01)


### Features

* **token-cost:** inline-aware concurrency (honest lower-bound on point-interval inline) ([6b0899c](https://github.com/rjskene/pipeline/commit/6b0899c602bd49e02de3a0af45a675cdde2da411))
* **token-cost:** per-N token-bucket breakout on per-PATH table ([9915c31](https://github.com/rjskene/pipeline/commit/9915c31fd30c339d4ccd5c76fa6ab882bba9f5e0))
* **token-cost:** per-N token-bucket breakout on per-stage table (unpriced-honest) ([e730093](https://github.com/rjskene/pipeline/commit/e73009319c1aebbc7203e0feec03b5b483ec0b8f))
* **token-cost:** per-N token-bucket breakout on structure table (unpriced-honest inline) ([44d2405](https://github.com/rjskene/pipeline/commit/44d2405887a15a45625aa5b68efded6ebfa81e78))
* **token-cost:** render tokenomics durations in minutes ([31d9d10](https://github.com/rjskene/pipeline/commit/31d9d10aa0424f3985c0fc12a20771ae185775b5))
* **token-cost:** split task-latency by spawn vs inline structure (unpriced-honest inline) ([5eacb09](https://github.com/rjskene/pipeline/commit/5eacb09cc820477a7974dc4653c81fd6b525541c))
* **token-cost:** tokenomics report readability — minutes, per-N token-bucket breakouts, inline-aware concurrency + spawn/inline task-latency ([5836cb3](https://github.com/rjskene/pipeline/commit/5836cb338670728da27548e62f464fade136ecdd))
* **tokenomics:** inline agent costs read ~15-30x low until retroactive transcript-sum runs — surface lower-bound vs auto-backfill ([cbf3733](https://github.com/rjskene/pipeline/commit/cbf373332203d75da9b2ddf4b97f037cf8fe6a74))
* **tokenomics:** surface unreconciled lower-bound record count in coverage-health ([f704310](https://github.com/rjskene/pipeline/commit/f704310b8c07c6eff93e0c1697fe6775472f66ed))


### Bug Fixes

* **capture:** transcript-sum inline subagent costs instead of sidecar lower-bound ([b95a976](https://github.com/rjskene/pipeline/commit/b95a97641d322aba8c7b699823ad226206f6832b))

## [0.21.3](https://github.com/rjskene/pipeline/compare/v0.21.2...v0.21.3) (2026-06-01)


### Bug Fixes

* **tokenomics:** emit distinct stdout skip-marker on logging gate-skip ([#790](https://github.com/rjskene/pipeline/issues/790)) ([707a32e](https://github.com/rjskene/pipeline/commit/707a32e6ba6481761e52f7ed2daf8762fb2d7dd5))
* **tokenomics:** propagate gate vars into backfill/report scripts + surface gated skip ([#790](https://github.com/rjskene/pipeline/issues/790)) ([46c84b5](https://github.com/rjskene/pipeline/commit/46c84b545f70f755c8297b4a9859d491b411560c))
* **tokenomics:** skill boot doesn't propagate config vars to backfill/report scripts — silent no-op + PIPELINE_REPO error ([7363bd4](https://github.com/rjskene/pipeline/commit/7363bd4f356acfb2440015eaed5aeedf8487aac2))

## [0.21.2](https://github.com/rjskene/pipeline/compare/v0.21.1...v0.21.2) (2026-06-01)


### Bug Fixes

* **inline-execute:** mandate terminal-state directive on evaluate-issue-pr inline dispatch ([6518b2e](https://github.com/rjskene/pipeline/commit/6518b2ecf4cd250817a9e1cfe9b6582a79dea091))
* **inline-execute:** mandate terminal-state directive on evaluate-issue-pr inline dispatch ([a1b6cc7](https://github.com/rjskene/pipeline/commit/a1b6cc7c79528d7372dbd0e0ccffc35dff6191f5)), closes [#772](https://github.com/rjskene/pipeline/issues/772)

## [0.21.1](https://github.com/rjskene/pipeline/compare/v0.21.0...v0.21.1) (2026-06-01)


### Bug Fixes

* evaluation fixes for [#777](https://github.com/rjskene/pipeline/issues/777) — raise process-maps line cap 220→235 for new Dispatch transport section ([6c0ec76](https://github.com/rjskene/pipeline/commit/6c0ec76d7d82efd4d20e4b727241917a385b92be))

## [0.21.0](https://github.com/rjskene/pipeline/compare/v0.20.7...v0.21.0) (2026-06-01)


### Features

* **classify:** blast-radius B→D routing rule + high-uncertainty carve-out + mined exemplars ([#707](https://github.com/rjskene/pipeline/issues/707)) ([30bd6fe](https://github.com/rjskene/pipeline/commit/30bd6fe03b03c0a6d0505d995034740f0561dac2))
* **classify:** feature-based B→D routing — blast-radius rule + mined exemplars ([fdb5776](https://github.com/rjskene/pipeline/commit/fdb5776d949bcfe9107297f6348eeb2de2b62384))
* **cost-report:** --tokenomics B→D breakeven table ([ac0429c](https://github.com/rjskene/pipeline/commit/ac0429c9f64f65b0e93984ec12e69dd2a34e68bf))
* **cost-report:** --tokenomics bucket table (token-share vs cost-share) ([0162ded](https://github.com/rjskene/pipeline/commit/0162ded48a7a8568f8887cc212c258917361bccc))
* **cost-report:** --tokenomics concurrency assessment (observed overlap + ceiling) ([0e7f269](https://github.com/rjskene/pipeline/commit/0e7f2691f769df6f9b08568f52783c2cdbee80b8))
* **cost-report:** --tokenomics coverage-health block ([af520d5](https://github.com/rjskene/pipeline/commit/af520d55294f98d48d924307a5fba95f4511c13b))
* **cost-report:** --tokenomics mark+exclude headless session-lifetime durations ([5e99831](https://github.com/rjskene/pipeline/commit/5e9983120ff9abff2341da6e4f9f228adab45438))
* **cost-report:** --tokenomics net-out cache_read in per-PATH/issue size view ([6091b9a](https://github.com/rjskene/pipeline/commit/6091b9ae740a2fa5ad69648086b7e56ed6c5f319))
* **cost-report:** --tokenomics per-day + per-PR $ trend with outlier flagging ([5b806f3](https://github.com/rjskene/pipeline/commit/5b806f31a810e0c1b720819b00a87bd7a6ce086d))
* **cost-report:** --tokenomics per-stage cost table (token size nets out cache_read) ([751b79a](https://github.com/rjskene/pipeline/commit/751b79a55a251a3b2070fa012b29e5cd62241601))
* **cost-report:** --tokenomics structure table + stage×structure cross-tab ([e179645](https://github.com/rjskene/pipeline/commit/e179645bc20252d1f64eb795c7c9d63cfa1fde82))
* **cost-report:** config-driven per-model pricing; surface unpriced empty-model records ([c69adda](https://github.com/rjskene/pipeline/commit/c69adda3590637eba6c87e3324ddd352cdaef730))
* **cost-report:** dedup by (session_id,issue,stage) max-total before totaling ([5b33162](https://github.com/rjskene/pipeline/commit/5b33162bf856eb6f35c0105895732f5d3a2bdf34))
* **doctor:** route pipeline_config/labels_exist remediation to /pipeline:init ([#726](https://github.com/rjskene/pipeline/issues/726)) ([ec13a67](https://github.com/rjskene/pipeline/commit/ec13a676ed327eb89bc2c333dbdc1de29bdfaa95))
* **dogfood-fixtures:** add b1 alpha module (PATH B fixture) ([c4ef8fe](https://github.com/rjskene/pipeline/commit/c4ef8fedf91f98856a375ee9e85b382dc071930f))
* **dogfood-fixtures:** add b2 delta module (PATH B fixture) ([913da39](https://github.com/rjskene/pipeline/commit/913da3923f1171f1ecbbbf99392b9d2c068e95c4))
* **execute,classify:** collapsed-D carried-forward context + escalation backstop ([#700](https://github.com/rjskene/pipeline/issues/700)) ([1c75e56](https://github.com/rjskene/pipeline/commit/1c75e5638390de9a7a7328eb8aaf53068e1eb4f7))
* **fixture-b1:** add b1_beta fixture ([a9c4786](https://github.com/rjskene/pipeline/commit/a9c47860ae30c20f646b6ea6bbce4ce3ad73aa7a))
* **fixture-b1:** add b1_gamma sourcing alpha+beta ([824d2ff](https://github.com/rjskene/pipeline/commit/824d2ff0331a82be5f3fc71547cd5313b36b9093))
* **fixtures:** add b2 epsilon fixture ([7fe3b68](https://github.com/rjskene/pipeline/commit/7fe3b68ca9d8eb43d552ed9dde53948c583515cf))
* **fixtures:** add b2 harness + delta fixture ([ab599ee](https://github.com/rjskene/pipeline/commit/ab599ee8fa88fa99acb70420f5f9e4498524f343))
* **fixtures:** add b2 zeta fixture sourcing delta+epsilon ([973e149](https://github.com/rjskene/pipeline/commit/973e149bd5396ae2d9b280cc0bd069a018288384))
* **fullsend:** collapse PATH D classify+plan+execute into one foreground inline Agent, skip per-stage 1b dispatch ([#715](https://github.com/rjskene/pipeline/issues/715)) ([47fc465](https://github.com/rjskene/pipeline/commit/47fc46502e6780857622d3e07b0e62f3b810c456))
* **fullsend:** split-dispatch D inline foreground batch alongside B/C run-queue ([#700](https://github.com/rjskene/pipeline/issues/700)) ([27fe052](https://github.com/rjskene/pipeline/commit/27fe0526fc84a7a12601a81222d51caab02292ad))
* **init:** seed commented PIPELINE_PRICE_* override block into generated config ([#734](https://github.com/rjskene/pipeline/issues/734)) ([17a1bc7](https://github.com/rjskene/pipeline/commit/17a1bc77a65570d5d1efac6a77a68d729ec83b75))
* **inline-execute:** dispatch PATH B execute via inline Agent (no claude -p) ([bf250a4](https://github.com/rjskene/pipeline/commit/bf250a42a1df4baabdc9d54e34feee47ca992e08))
* **inline-execute:** move PATH B PR-eval to inline dispatch mode in evaluate-issue-pr ([#748](https://github.com/rjskene/pipeline/issues/748)) ([75cf076](https://github.com/rjskene/pipeline/commit/75cf0762834c4f14a289dcf5ab69fb8c1ca44da7))
* **inline-execute:** move PATH B to inline dispatch mode in execute-issue-plan ([#748](https://github.com/rjskene/pipeline/issues/748)) ([9eb55ef](https://github.com/rjskene/pipeline/commit/9eb55ef3dcb12e8166b5ccd0d0709dc13543bad2))
* **inline-execute:** route PATH B execute via inline Agent batch in fullsend ([#748](https://github.com/rjskene/pipeline/issues/748)) ([3aee533](https://github.com/rjskene/pipeline/commit/3aee533bba597c830732464f8e26871ab04f3070))
* **inline-execute:** route PATH B execute/PR-eval via inline Agent in run skill ([#748](https://github.com/rjskene/pipeline/issues/748)) ([dec111a](https://github.com/rjskene/pipeline/commit/dec111a5845fe4c164fdf85ed44be74e3738c4f7))
* **pipeline:** collapse PATH D ceremony — inline the quick-fix path, skip redundant re-contexting ([f4c7037](https://github.com/rjskene/pipeline/commit/f4c7037115d8a53b2ad9fa4d340d3da53e0174a5))
* **run:** collapse PATH D into single inline context, keep pr-eval separate ([#700](https://github.com/rjskene/pipeline/issues/700)) ([24b74db](https://github.com/rjskene/pipeline/commit/24b74db7be0b50d70252b7050ecd904a20d9326d))
* **run:** route PATH D through one collapsed inline classify+plan+execute Agent ([#715](https://github.com/rjskene/pipeline/issues/715)) ([b17b3fc](https://github.com/rjskene/pipeline/commit/b17b3fcd01b5d40c9a90d2a3351471532412b155))
* **token-cost:** add input/output/cache_read columns to per-day trend ([07470bc](https://github.com/rjskene/pipeline/commit/07470bc9c2df460d79dd43e9b5fbf73bf6563320))
* **token-cost:** add input/output/cache_read columns to per-PR trend ([ca8c926](https://github.com/rjskene/pipeline/commit/ca8c92660af4bb4aa4fb00ae9884580d187d3c49))
* **token-cost:** break out input/output/cache_read in per-issue size table ([6959cf9](https://github.com/rjskene/pipeline/commit/6959cf985e8e795357186d6660875d93a9f8857c))
* **token-cost:** break out input/output/cache_read token columns in per-issue size + trend tables ([9c9ada3](https://github.com/rjskene/pipeline/commit/9c9ada30a3cfbce9d2fa080e3a1be818b1ebcdd1))
* **token-cost:** JSON→markdown swap in helper payloads + dogfood reports (where no parse contract) ([c0cb99a](https://github.com/rjskene/pipeline/commit/c0cb99af3c9f1f11332ca041f4d5373bc49f001f))
* **token-cost:** terser ## Classification emit guidance ([#728](https://github.com/rjskene/pipeline/issues/728)) ([ee4b6d6](https://github.com/rjskene/pipeline/commit/ee4b6d655146443226089912a6db505aba07d4c2))
* **token-cost:** terser ## Evaluation emit guidance in evaluate-issue-pr ([#728](https://github.com/rjskene/pipeline/issues/728)) ([5528e99](https://github.com/rjskene/pipeline/commit/5528e99701a000152ecfffdecde5571fffc6fc2f))
* **token-cost:** terser ## Implementation Plan emit guidance ([#728](https://github.com/rjskene/pipeline/issues/728)) ([890bff6](https://github.com/rjskene/pipeline/commit/890bff6257f01f5fcedcfc2a1c7965ee28ea44db))
* **token-cost:** terser ## Plan Evaluation emit guidance ([#728](https://github.com/rjskene/pipeline/issues/728)) ([a68b2ed](https://github.com/rjskene/pipeline/commit/a68b2edafb1eca819d6f1d7a17e06edaf09141b5))
* **token-cost:** terser artifact templates — verbosity-trim plan/eval/classify skills ([2f92069](https://github.com/rjskene/pipeline/commit/2f92069683eb66be11e04b887433f23a3277a0cc))
* **tokenomics:** /pipeline:init seeds PIPELINE_PRICE_* override block into generated pipeline.config ([24b5305](https://github.com/rjskene/pipeline/commit/24b530592321ed6cf5a87b2d9a8ceb96a5746fab))
* **tokenomics:** /pipeline:tokenomics — dogfood usage-analysis skill (backfill + cost/latency report) ([b262d8c](https://github.com/rjskene/pipeline/commit/b262d8c40ac31cbec43aa2681752dc020d8e87db))
* **tokenomics:** /pipeline:tokenomics dogfood skill (backfill + report) ([3b5af78](https://github.com/rjskene/pipeline/commit/3b5af787dc8c258e3bb82ac092f4853f358aff70))


### Bug Fixes

* allowlist bare PIPELINE_PRICE drift token from test regex for [#734](https://github.com/rjskene/pipeline/issues/734) ([0158427](https://github.com/rjskene/pipeline/commit/0158427ffdbd63780f74b84a774f4afe42832513))
* **dogfood-fixtures:** add d1 quick utility (PATH D fixture) ([0f1eaaf](https://github.com/rjskene/pipeline/commit/0f1eaaf70a2deffa338ab534374c788881da93e9))
* **dogfood-fixtures:** add d2 echo utility (PATH D collapse validation) ([7b53cb8](https://github.com/rjskene/pipeline/commit/7b53cb87e8f37dcd6af8b2ca007395bbee50b0e0))
* **dogfood-fixtures:** add d2 echo utility (PATH D collapse validation) ([7dc86b2](https://github.com/rjskene/pipeline/commit/7dc86b234a5d14f34d7256aece658df027254a79)), closes [#718](https://github.com/rjskene/pipeline/issues/718)
* evaluation fixes for [#721](https://github.com/rjskene/pipeline/issues/721) — allowlist pipeline:tokenomics in namespace test ([38d9bc0](https://github.com/rjskene/pipeline/commit/38d9bc01024a7239a13e36b8a6c0bdec4bfb3b8b))
* **inline-execute:** inline agent cost undercounted — forward hook logs final-turn usage as usage_complete=true ([bd15853](https://github.com/rjskene/pipeline/commit/bd158530fa4f3bb7d2cf639725c0a4c7aa2dbfdb))
* **inline-execute:** mandate terminal-state directive in inline execute dispatch ([d862b89](https://github.com/rjskene/pipeline/commit/d862b89e05d6a6898997bb0267029c1d6f4120b3)), closes [#764](https://github.com/rjskene/pipeline/issues/764)
* **inline-execute:** mandate terminal-state directive in inline execute dispatch — kill narrate-and-yield drop-out ([b0a0ef7](https://github.com/rjskene/pipeline/commit/b0a0ef71b075d427fda4798a8cd003b3f1fbe5b6))
* **inline-execute:** stamp inline forward cost records usage_complete=false (lower-bound) ([2c651f4](https://github.com/rjskene/pipeline/commit/2c651f4bf106c7e5fdfc2bccacfc6730b798e06f))
* **pipeline:** [#715](https://github.com/rjskene/pipeline/issues/715) follow-ups — PIPELINE_REPO wrap on post-plan + exclude base-branch metadata ([#716](https://github.com/rjskene/pipeline/issues/716)) ([be169c4](https://github.com/rjskene/pipeline/commit/be169c4dbd06e3790e437fdef5e8532ccf47d81e))
* **pipeline:** PATH D collapse is contract-only — classify+plan+execute still run as separate contexts ([ae90c62](https://github.com/rjskene/pipeline/commit/ae90c62501938fdeda7f1c3fb2c849ac74fa6c0b))
* **plan-issue:** wrap post-plan.sh call with PIPELINE_REPO= to propagate into subshell ([#716](https://github.com/rjskene/pipeline/issues/716)) ([fd1f5df](https://github.com/rjskene/pipeline/commit/fd1f5df3ddd7cbb3fa01d68b275ad3cc6d0aaa98))
* **plan-waves:** guard empty-backtick Files-to-change grep under pipefail ([#730](https://github.com/rjskene/pipeline/issues/730)) ([c406bd0](https://github.com/rjskene/pipeline/commit/c406bd073f507f502c0acc20a9e9a4d1f15005f7))
* **plan-waves:** pipefail kills wave computation when a plan comment has no backtick-wrapped Files-to-change paths ([8ac7ab2](https://github.com/rjskene/pipeline/commit/8ac7ab23aad187c82c5fedbd054d15b4cb022bd3))
* **review:** harden blast-radius Test 1 to assert the rule body, not the heading ([#707](https://github.com/rjskene/pipeline/issues/707)) ([303c46c](https://github.com/rjskene/pipeline/commit/303c46c7f6a8b4b25c28d2a737ba9af7ded17fe1))
* **review:** scrub residual 'spawned PATH B' framing in run skill + process-maps; guard it ([#748](https://github.com/rjskene/pipeline/issues/748)) ([7952065](https://github.com/rjskene/pipeline/commit/79520650b931c44cb369054f4914ef574a1b2d03))
* **review:** tighten guard predicate + fail on empty report output ([#729](https://github.com/rjskene/pipeline/issues/729)) ([7df8b9a](https://github.com/rjskene/pipeline/commit/7df8b9ad34e28d614358458736df8f7ff141dd23))
* **setup-worktree:** exclude untracked .claude/base-branch via common-dir git exclude ([#716](https://github.com/rjskene/pipeline/issues/716)) ([b0603f0](https://github.com/rjskene/pipeline/commit/b0603f0077bcc7d502a0c0250fd29e3430717d0a))
* **token-cost:** drop missing-transcript skipped line from coverage-health ([2601240](https://github.com/rjskene/pipeline/commit/260124012469b3840832b05e92fdfe9d3e5d650b))
* **token-cost:** drop missing-transcript skipped line from coverage-health for [#746](https://github.com/rjskene/pipeline/issues/746) ([cf6cad6](https://github.com/rjskene/pipeline/commit/cf6cad62a512a0f62b0ece64a5f84bd38fd26f03))
* **tokenomics:** bake in Sonnet + Haiku list-price defaults — non-Opus models silently priced at Opus rates ([406b997](https://github.com/rjskene/pipeline/commit/406b997cc89aab335940cabd80aaafaf2d636f9c))
* **tokenomics:** bake in Sonnet/Haiku list-price defaults ([#733](https://github.com/rjskene/pipeline/issues/733)) ([d44240f](https://github.com/rjskene/pipeline/commit/d44240fd7763e7d779c522b8ad4d5de2ff93acdd))


### Miscellaneous Chores

* release 0.21.0 (inline-agent dispatch migration) ([#774](https://github.com/rjskene/pipeline/issues/774)) ([7e501f4](https://github.com/rjskene/pipeline/commit/7e501f454cc63bfd649817c972f082a79523cb56))

## [0.20.7](https://github.com/rjskene/pipeline/compare/v0.20.6...v0.20.7) (2026-05-31)


### Bug Fixes

* **dogfood-metrics:** dedup capture records on record_key before summing (last-write-wins) ([90a3a59](https://github.com/rjskene/pipeline/commit/90a3a5940e808da5b641352866185a91e0056bde)), closes [#698](https://github.com/rjskene/pipeline/issues/698)
* **dogfood-metrics:** default inline agent_type to general-purpose, mirroring log_subagent.py ([#699](https://github.com/rjskene/pipeline/issues/699)) ([772942b](https://github.com/rjskene/pipeline/commit/772942b1c611263bfb3499f147cb772b6270b9d9))
* **dogfood-metrics:** execute-stage tokens never reach the main capture log (worker writes to worktree, then cleaned up) ([a12e903](https://github.com/rjskene/pipeline/commit/a12e9035d984884440112d061bd35af2edad5855))
* **dogfood-metrics:** inline records inherit session model from orchestrator state sidecar ([#699](https://github.com/rjskene/pipeline/issues/699)) ([d8016e1](https://github.com/rjskene/pipeline/commit/d8016e15b37acade107b4c3783f252ab0c1d068c))
* **dogfood-metrics:** inline-stage model/agent_type provenance empty despite [#691](https://github.com/rjskene/pipeline/issues/691) ([39834df](https://github.com/rjskene/pipeline/commit/39834dfac5afcd1da4f0e27b8ea06b9ce725823b))
* **dogfood-metrics:** record_key not unique — re-run stages double-counted in per-issue token totals ([d4a99c5](https://github.com/rjskene/pipeline/commit/d4a99c56b6b0d4a06ca81081baf62cdaea6b9e2a))
* **dogfood-metrics:** resolve agent-cost OUTPUT log to git common-dir main worktree so execute records survive worktree prune ([#697](https://github.com/rjskene/pipeline/issues/697)) ([d700b1d](https://github.com/rjskene/pipeline/commit/d700b1da3729134f7f266ce955dbcd88d3870037))
* **review:** preserve session model on a model-less subsequent Stop ([#699](https://github.com/rjskene/pipeline/issues/699)) ([7e02028](https://github.com/rjskene/pipeline/commit/7e020287120d33e204444673548c7cded2723a3d))
* **run-queue:** [#636](https://github.com/rjskene/pipeline/issues/636) executor-reap grace logic silently kills evaluator workers mid-CI-wait (issue already pr-open) ([9e78c70](https://github.com/rjskene/pipeline/commit/9e78c70287d7df674004d5cc895ca3d770faa6f9))
* **run-queue:** require observed in-progress-&gt;pr-open transition before reaping a worker as a finished executor ([#694](https://github.com/rjskene/pipeline/issues/694)) ([936b72e](https://github.com/rjskene/pipeline/commit/936b72e829754d54e8dcf2f1479d1be83b9837e0))

## [0.20.6](https://github.com/rjskene/pipeline/compare/v0.20.5...v0.20.6) (2026-05-30)


### Features

* **auto-merge:** add finish-manual-merge.sh for post-merge bookkeeping ([f34a614](https://github.com/rjskene/pipeline/commit/f34a614e220cff317b7a5e86703eb3f855bde572)), closes [#655](https://github.com/rjskene/pipeline/issues/655)
* **auto-merge:** helper to replicate gate bookkeeping after a manual merge ([c3b3b07](https://github.com/rjskene/pipeline/commit/c3b3b070ec8ded6f3c2f265463833fe88038f846))
* **auto-merge:** NO_VERDICT mode skips verdict gate for hotfix lane ([#659](https://github.com/rjskene/pipeline/issues/659)) ([66857c3](https://github.com/rjskene/pipeline/commit/66857c3a757c5d114f926b4fdb6b03beb3cb1ae1))
* **hotfix:** opt-in auto-merge on green CI (no evaluator verdict) ([0db1a8f](https://github.com/rjskene/pipeline/commit/0db1a8f87aac414b22dc16bd23da4fbfa637ce59))
* **hotfix:** parse opt-in --auto-merge flag in Step 1 ([#659](https://github.com/rjskene/pipeline/issues/659)) ([5470ab8](https://github.com/rjskene/pipeline/commit/5470ab87225e465759cdca172565452b9131b0e3))
* **hotfix:** Step 6.5 opt-in CI-only auto-merge with explicit issue close ([#659](https://github.com/rjskene/pipeline/issues/659)) ([22633fa](https://github.com/rjskene/pipeline/commit/22633fa5d7f829587f69185a47caec714005ba35))


### Bug Fixes

* **dogfood-metrics:** inline forward cost records carry empty ts_start/ts_end → per-run time-windowing silently drops 100% of subagent rows ([8e74d77](https://github.com/rjskene/pipeline/commit/8e74d77d94e0d1bb396a0ba6124f72314211d553))
* **dogfood-metrics:** inline forward cost records lose provenance — agent_type always "unknown", model always empty ([71c52a8](https://github.com/rjskene/pipeline/commit/71c52a82ffff18d241fb6ed22a40001ecc21bc8f))
* **dogfood-metrics:** read agent_type from nested tool_input.subagent_type in build_record ([#691](https://github.com/rjskene/pipeline/issues/691)) ([5bfe69a](https://github.com/rjskene/pipeline/commit/5bfe69a36506e27db103cb6fb23e48a93bc6aeac))
* **dogfood-metrics:** stamp inline forward ts_end at emit time + backfill ts_start for record_key entropy ([#690](https://github.com/rjskene/pipeline/issues/690)) ([3c22dd6](https://github.com/rjskene/pipeline/commit/3c22dd650045f9722fad510c35cea9071354077c))
* **enforce-ci-wait:** stop instructing run_in_background in CI-wait remediation ([#684](https://github.com/rjskene/pipeline/issues/684)) ([4146561](https://github.com/rjskene/pipeline/commit/41465612b1eae5d17d7c55d93b031d573f06392a))
* **evaluate-issue-pr:** evaluator subagent ends its turn on the CI-wait step instead of completing the verdict+merge ([5f8b468](https://github.com/rjskene/pipeline/commit/5f8b4684c4bc1696c7cd970701a1638e7ca2a5ad))
* **evaluate-issue-pr:** run Step 5b CI-wait foreground so the subagent completes verdict+merge in-turn ([#684](https://github.com/rjskene/pipeline/issues/684)) ([dc77687](https://github.com/rjskene/pipeline/commit/dc77687e2a56e0a62cf2be184f77f6f465530694))
* **run-queue:** route single-issue queues through the poll loop so they block to queue-complete ([#685](https://github.com/rjskene/pipeline/issues/685)) ([b9f2e55](https://github.com/rjskene/pipeline/commit/b9f2e557361e4cc8cc7729c8bf9841428b068b1a))
* **run-queue:** single-issue queue exits 0 immediately instead of blocking to queue-complete ([1b7d1ac](https://github.com/rjskene/pipeline/commit/1b7d1acdf2b4108ef8b329f5721091a726a3536f))

## [0.20.5](https://github.com/rjskene/pipeline/compare/v0.20.4...v0.20.5) (2026-05-30)


### Features

* **audit-compliance:** enforce test-first commit ordering with WEAK verdict ([#640](https://github.com/rjskene/pipeline/issues/640)) ([86e075f](https://github.com/rjskene/pipeline/commit/86e075f5dc8ab65038342c240f38551f107d833b))
* **compliance-audit:** enforce red→green commit ordering (test-before-source), not just test-presence ([b1916c6](https://github.com/rjskene/pipeline/commit/b1916c6a43123851222726ae478788a104ee27ea))
* **compliance-backfill:** surface WEAK column + widen rate denominator ([#640](https://github.com/rjskene/pipeline/issues/640)) ([8dbd22f](https://github.com/rjskene/pipeline/commit/8dbd22fa09bb49d88d17e9c7ecfa06f76909c5f0))
* **dogfood-metrics:** add forward SubagentStop/Stop cost-capture hook ([#642](https://github.com/rjskene/pipeline/issues/642)) ([756d080](https://github.com/rjskene/pipeline/commit/756d0806e12293e1b7487df573c3311c5269487b))
* **dogfood-metrics:** add gh + capture-log loaders and fixtures ([#643](https://github.com/rjskene/pipeline/issues/643)) ([82accda](https://github.com/rjskene/pipeline/commit/82accdadd194a7149ea8c1a4524dd3673b06a06f))
* **dogfood-metrics:** add orchestrator row to cost-latency stage table ([#662](https://github.com/rjskene/pipeline/issues/662)) ([b74a3a3](https://github.com/rjskene/pipeline/commit/b74a3a3c07b75659e070aa8cb91643de65cf3761))
* **dogfood-metrics:** add retroactive agent cost parser ([#642](https://github.com/rjskene/pipeline/issues/642)) ([f1b30c3](https://github.com/rjskene/pipeline/commit/f1b30c39e277d6d0cc66870fc17eacbe5b2dc634))
* **dogfood-metrics:** add token-usage lib (sum/slug/stage/issue) ([#642](https://github.com/rjskene/pipeline/issues/642)) ([4396e92](https://github.com/rjskene/pipeline/commit/4396e92a694f0fe211e662759c5fa380157b6647))
* **dogfood-metrics:** build per-issue rows with ceremony + over-served flags ([#643](https://github.com/rjskene/pipeline/issues/643)) ([2e66678](https://github.com/rjskene/pipeline/commit/2e666785be178c62997e97d975d04962699a6d3b))
* **dogfood-metrics:** capture orchestrator/main-agent inline cost (PostToolUse(Agent) only sees subagents) ([1bbb8b8](https://github.com/rjskene/pipeline/commit/1bbb8b83bfa2fd7b7cfdfbfa5c2f5c3911e7a6b2))
* **dogfood-metrics:** cost & latency report — tokens/LOC/time per issue & stage, over-served outliers ([14b47dc](https://github.com/rjskene/pipeline/commit/14b47dc4056697d5b245285d826715a91a9ceb37))
* **dogfood-metrics:** feed cost/latency columns into metrics-snapshot ([#643](https://github.com/rjskene/pipeline/issues/643)) ([84caaa1](https://github.com/rjskene/pipeline/commit/84caaa1987406e4c81e02651bbec868798de061e))
* **dogfood-metrics:** per-issue/per-stage token + wall-clock capture ([bdd4cd2](https://github.com/rjskene/pipeline/commit/bdd4cd2dd2626e6b633b01cfba137bb60a8c0fdd))
* **dogfood-metrics:** per-session delta state so repeated Stop fires don't double-count ([#662](https://github.com/rjskene/pipeline/issues/662)) ([f668714](https://github.com/rjskene/pipeline/commit/f668714b64ba7e3a036ddbad61cbc6a86532cdef))
* **dogfood-metrics:** re-register Stop hook for orchestrator cost capture ([#662](https://github.com/rjskene/pipeline/issues/662)) ([3c5a886](https://github.com/rjskene/pipeline/commit/3c5a886f9833b23d1a24a7b86231e85fb8b02f88))
* **dogfood-metrics:** render aggregate tables, TOP-N, and over-served outliers ([#643](https://github.com/rjskene/pipeline/issues/643)) ([367d511](https://github.com/rjskene/pipeline/commit/367d511ec252c1d5d1ec1174fd77731c5729d0e2))
* **dogfood-metrics:** scaffold cost-latency-report.sh ([#643](https://github.com/rjskene/pipeline/issues/643)) ([7aea1a0](https://github.com/rjskene/pipeline/commit/7aea1a089b5673686c673d16e9a111e13c112c05))
* **metrics-snapshot:** strict test-first pass-rate + compliance_weak_count ([#640](https://github.com/rjskene/pipeline/issues/640)) ([37f3fdf](https://github.com/rjskene/pipeline/commit/37f3fdf3d462f0ebd8d868500fa3fd1875a96361))
* **run-queue:** add executor reap grace knob and PR_OPEN_POLLS state ([#636](https://github.com/rjskene/pipeline/issues/636)) ([2387cfa](https://github.com/rjskene/pipeline/commit/2387cfae5f1bd1eb0c7ce0a43321e8303bd7fe4c))
* **run-queue:** add executor_finished_terminal predicate ([#636](https://github.com/rjskene/pipeline/issues/636)) ([8ffe65b](https://github.com/rjskene/pipeline/commit/8ffe65b1b3e0861142e837710ef2e41c2053e726))
* **run-queue:** reap executor lingering past pr-open after grace window ([#636](https://github.com/rjskene/pipeline/issues/636)) ([4f573db](https://github.com/rjskene/pipeline/commit/4f573dbdb46aadd1b804dc095c552b8d2060f2ff))


### Bug Fixes

* **dogfood-metrics:** adapt cost-latency reader to merged [#642](https://github.com/rjskene/pipeline/issues/642) capture schema ([1f47d70](https://github.com/rjskene/pipeline/commit/1f47d70f43e1b0348b0fa58efa0c3aa752b0d820))
* **dogfood-metrics:** capture cost on PostToolUse(Agent) — SubagentStop lacks usage/description ([#660](https://github.com/rjskene/pipeline/issues/660)) ([5801964](https://github.com/rjskene/pipeline/commit/58019649ebb95207aed701b26359d71fac486beb))
* **dogfood-metrics:** cost-latency-report per-stage join silently drops orchestrator records (issue:"") ([7d4b6e0](https://github.com/rjskene/pipeline/commit/7d4b6e08d16fe709816fd43dd43a2c01272a48f1))
* **dogfood-metrics:** emit null orchestrator duration_ms, not calendar-span latency ([#667](https://github.com/rjskene/pipeline/issues/667)) ([0c9d6b8](https://github.com/rjskene/pipeline/commit/0c9d6b8ce4f7eef26ac8fcd1655c699a61427b0e))
* **dogfood-metrics:** exclude pre-fix orchestrator records (non-null duration) from cost-latency report ([#678](https://github.com/rjskene/pipeline/issues/678)) ([48d29dd](https://github.com/rjskene/pipeline/commit/48d29dd68dd56bbecb72094cc1f4d16c9034716e))
* **dogfood-metrics:** first-token-position wins for multi-stage descriptions ([#642](https://github.com/rjskene/pipeline/issues/642)) ([b94ae7e](https://github.com/rjskene/pipeline/commit/b94ae7eb91f9283d0d96b9538da3d34ab22f61b0))
* **dogfood-metrics:** group orchestrator cost-latency rows by session_id, not issue ([#678](https://github.com/rjskene/pipeline/issues/678)) ([870ced3](https://github.com/rjskene/pipeline/commit/870ced37844e0a15920ab0675a7fa0dc129af0b5))
* **dogfood-metrics:** log_subagent.py logs duration 0 — reads tool_response.total_duration_ms (null), not top-level duration_ms ([f4d58a5](https://github.com/rjskene/pipeline/commit/f4d58a58cbcc3a978fdfa3b6f478e0ce9b557fbd))
* **dogfood-metrics:** log_subagent.py sources duration from top-level duration_ms ([#663](https://github.com/rjskene/pipeline/issues/663)) ([5998ab0](https://github.com/rjskene/pipeline/commit/5998ab031e37c22dcce780a0764d2dae8c02c6ab))
* **dogfood-metrics:** orchestrator duration_ms spans calendar session life, not compute time ([9f0896c](https://github.com/rjskene/pipeline/commit/9f0896c262cd9adb7154f8b44b8503bdfa468b0a))
* **dogfood-metrics:** orchestrator row in cost-latency-report sums all-time pre-fix records → 257M tokens / 387h duration ([cb9f92f](https://github.com/rjskene/pipeline/commit/cb9f92fc4e54fb31f6ef2fbf883f433a015bd137))
* **dogfood-metrics:** orchestrator tokens.total is work-total (exclude per-turn cache_read re-count) ([ded5fb7](https://github.com/rjskene/pipeline/commit/ded5fb781d291c9af6f213eb1dceb9fab0f3ee60)), closes [#668](https://github.com/rjskene/pipeline/issues/668)
* **dogfood-metrics:** orchestrator tokens.total is work-total, exclude cache_read re-count ([#668](https://github.com/rjskene/pipeline/issues/668)) ([d4936f2](https://github.com/rjskene/pipeline/commit/d4936f21341eae577355c8ed239fadf135c50017))
* **dogfood-metrics:** pass Path to append_locked so forward records persist ([#642](https://github.com/rjskene/pipeline/issues/642)) ([f8fbd52](https://github.com/rjskene/pipeline/commit/f8fbd52fcd96d1dd1ac604cb452f9407415de996))
* **dogfood-metrics:** register SubagentStop/Stop cost hook in dogfood settings ([#642](https://github.com/rjskene/pipeline/issues/642)) ([dc3bcf7](https://github.com/rjskene/pipeline/commit/dc3bcf77693dcd678a11733e4716b1d540c72ce5))
* **dogfood-metrics:** relabel orchestrator slow-stage line + annotate cache_read asymmetry ([#678](https://github.com/rjskene/pipeline/issues/678)) ([1b7d64f](https://github.com/rjskene/pipeline/commit/1b7d64f17ca2a51f1e2806c4c69f8461970e168a))
* **dogfood-metrics:** resolve PIPELINE_LOGS_ENABLED from pipeline.config in cost hook ([#657](https://github.com/rjskene/pipeline/issues/657)) ([118eeac](https://github.com/rjskene/pipeline/commit/118eeac4fc7ab63acbe376814a85431046f9a1dd))
* **dogfood-metrics:** surface orchestrator issue:"" records in per-stage join ([#669](https://github.com/rjskene/pipeline/issues/669)) ([7583a68](https://github.com/rjskene/pipeline/commit/7583a68b276e763e433fb7bfc61f91b14bb2b71d))
* **executor:** execute-issue-plan full-suite verification hangs on interactive tests + spawns concurrent self-colliding suite runs ([8edbfbc](https://github.com/rjskene/pipeline/commit/8edbfbc23f454d60ee3309cf3d45f820f49206a6))
* **executor:** make the spawn-claude tmux timeout configurable via PIPELINE_EXECUTOR_TIMEOUT_SECONDS ([#656](https://github.com/rjskene/pipeline/issues/656)) ([5a39421](https://github.com/rjskene/pipeline/commit/5a3942189069acb1080a4babb50c1f3e4af3c907))
* **executor:** raise or checkpoint the hardcoded 90-min PATH C executor timeout ([d52e186](https://github.com/rjskene/pipeline/commit/d52e1862ad8dd4a6461aa5b5428ac7f557cddbc2))
* **executor:** scope+stdin-guard+serialize execute-issue-plan verification ([#677](https://github.com/rjskene/pipeline/issues/677)) ([e30bb42](https://github.com/rjskene/pipeline/commit/e30bb42fc4eefe1ecbbc2dd92ffc0e609b124cd2))
* **fullsend:** match verdict-neutral manual-merge-required token in wake-loop doc ([ebeda93](https://github.com/rjskene/pipeline/commit/ebeda9354be1551c1f41239a7022009f8ea4b63a))
* **migrate:** bound prompt_one read on non-tty stdin so it can't hang ([#676](https://github.com/rjskene/pipeline/issues/676)) ([5cead1a](https://github.com/rjskene/pipeline/commit/5cead1aecd9bc671ec689f622ac2bb6a4048b394))
* **migrate:** migrate-from-subtree.sh prompt_one read hangs when stdin is a non-tty open pipe ([d411382](https://github.com/rjskene/pipeline/commit/d4113828278a4ed9e89e571833bddff892c611d1))
* **review:** correct Scenario 10 comment to reflect single orchestrator record ([#669](https://github.com/rjskene/pipeline/issues/669)) ([deebf9e](https://github.com/rjskene/pipeline/commit/deebf9e3d080b665d70e2f6871a238dfeaed1f4d))
* **review:** document PIPELINE_EXECUTOR_REAP_GRACE_POLLS in config example ([#636](https://github.com/rjskene/pipeline/issues/636)) ([6d5a784](https://github.com/rjskene/pipeline/commit/6d5a7841ca8dae9b78ac9167f2753a0d7cd5cac0))
* **review:** note WEAK in extract_tdd_verdict verdict-domain docstring ([#640](https://github.com/rjskene/pipeline/issues/640)) ([16bac09](https://github.com/rjskene/pipeline/commit/16bac09e9514c0643de7f6f66a31d40796bb0064))
* **review:** tolerate malformed capture lines instead of zeroing report ([#643](https://github.com/rjskene/pipeline/issues/643)) ([ecaac6a](https://github.com/rjskene/pipeline/commit/ecaac6a4995038ad3288709ed21381b43f39712a))
* **review:** use ts_end for orchestrator record_key so per-session deltas get distinct idempotency keys ([#662](https://github.com/rjskene/pipeline/issues/662)) ([9cd7b2e](https://github.com/rjskene/pipeline/commit/9cd7b2e3fc2f029930002bc10648433789474c02))
* **run-queue:** add executor_finished_terminal reap for workers lingering past pr-open ([c7fef90](https://github.com/rjskene/pipeline/commit/c7fef90d9dffbf603eecb289fc06f7a51e1f50c9))
* **run-queue:** clarify the misleading "approved-manual-merge" outcome token ([f057325](https://github.com/rjskene/pipeline/commit/f0573259cd291cb1a349c4287c74fa0e41b86cd6))
* **run-queue:** emit verdict-neutral manual-merge-required token with gate reason ([986c18d](https://github.com/rjskene/pipeline/commit/986c18d65127a10a07067c8f493dd357114aed5e))
* **run-queue:** gate agent-stalled on tmux-pane forward progress, not CPU alone ([#641](https://github.com/rjskene/pipeline/issues/641)) ([9e6e40f](https://github.com/rjskene/pipeline/commit/9e6e40fdfb03a090622395d1c0e469f6d0dc1c7f))
* **run-queue:** kill worker process group on reap + mode-aware terminal predicate ([#666](https://github.com/rjskene/pipeline/issues/666)) ([e99a68c](https://github.com/rjskene/pipeline/commit/e99a68c9e5a1f4517bd01fdf1f514732a50d828a))
* **run-queue:** kill worker process group on reap so queue-complete implies no orphans ([#666](https://github.com/rjskene/pipeline/issues/666)) ([9bd8280](https://github.com/rjskene/pipeline/commit/9bd82804a1149744f23d2c0b8c80c0fbcfaae312))
* **run-queue:** make executor reap mode-aware so eval queues don't reap on pre-existing pr-open ([#666](https://github.com/rjskene/pipeline/issues/666)) ([112eac8](https://github.com/rjskene/pipeline/commit/112eac89d6805bf5c255f651406d42428c81084c))
* **run-queue:** stall detection is CPU-only — false-positives on API-bound executors/evaluators (gate on forward progress instead) ([fb73785](https://github.com/rjskene/pipeline/commit/fb73785b98b65b7e747babdd8e1f2300d991de2c))

## [0.20.4](https://github.com/rjskene/pipeline/compare/v0.20.3...v0.20.4) (2026-05-30)


### Features

* **fullsend:** execute slate wave-by-wave with inter-wave pull and emit-edges-sourced scoped halt ([#626](https://github.com/rjskene/pipeline/issues/626)) ([26720d9](https://github.com/rjskene/pipeline/commit/26720d91d7da43a5e1ce1a8466e2b3f403525a56))
* **plan-waves:** add additive --emit-edges mode + per-wave/inter-wave-pull doc contracts ([#626](https://github.com/rjskene/pipeline/issues/626)) ([632f16f](https://github.com/rjskene/pipeline/commit/632f16fa5f2de70a5e62fd07f07686059e02e42b))


### Bug Fixes

* **execute-issue-plan:** add hard terminal exit after pr-open to stop post-PR lingering ([#631](https://github.com/rjskene/pipeline/issues/631)) ([63cc50a](https://github.com/rjskene/pipeline/commit/63cc50aa4c6c98f1ed5dab013cdf58f71c9b5614))
* **execute-issue-plan:** agent lingers ~13min after PR creation, holding worktree + queue slot ([0c50a87](https://github.com/rjskene/pipeline/commit/0c50a8715f5522512f826431afb9e189e8d3522d))
* **fullsend:** enforce wave-by-wave execution so blocked issues branch only after blockers merge ([20ad0a1](https://github.com/rjskene/pipeline/commit/20ad0a15f74d721fc048d5a03ae874c442027e69))
* **metrics-snapshot:** export PIPELINE_REPO so sibling extractors don't degrade to null ([46b31ba](https://github.com/rjskene/pipeline/commit/46b31bad5a24fb669a77c45e9d5fc3d2ca294437))
* **metrics-snapshot:** export PIPELINE_REPO so sibling extractors don't degrade to null ([91002fd](https://github.com/rjskene/pipeline/commit/91002fd053458829f65942f53bd06821151142b7)), closes [#638](https://github.com/rjskene/pipeline/issues/638)
* **run-queue:** scope errexit off in the poll loop + diagnose abnormal exits, silence false-fire on benign exits ([#630](https://github.com/rjskene/pipeline/issues/630)) ([06d1552](https://github.com/rjskene/pipeline/commit/06d1552c0b852f8bfe623cb60312b304ee9a52de))
* **run-queue:** set -e in poll loop kills the monitor on a transient gh/tmux non-zero while agents still run ([0ffd621](https://github.com/rjskene/pipeline/commit/0ffd621646860e1a38957a6abc6e7506f8dfd440))

## [0.20.3](https://github.com/rjskene/pipeline/compare/v0.20.2...v0.20.3) (2026-05-29)


### Features

* add /pipeline:init to bootstrap the plugin in new (non-subtree) projects ([68c0c3b](https://github.com/rjskene/pipeline/commit/68c0c3b96133cfd1783428c9fad4a9fb205bb44a))
* **doctor:** warn when dogfood local-marketplace install is enabled but not the resolved plugin root ([#625](https://github.com/rjskene/pipeline/issues/625)) ([24c47fc](https://github.com/rjskene/pipeline/commit/24c47fc54383a66a27e724614cefa449d8d14577))
* **doctor:** warn when dogfood local-marketplace symlink is missing or stale ([#624](https://github.com/rjskene/pipeline/issues/624)) ([df7df91](https://github.com/rjskene/pipeline/commit/df7df9118acc2e55175ff0b666fbf68c5ae7a8cf))
* **dogfood:** heal symlink on UserPromptSubmit, not just SessionStart ([#624](https://github.com/rjskene/pipeline/issues/624)) ([45730b0](https://github.com/rjskene/pipeline/commit/45730b0ef825e6ac7bd74c0022d8c90ffa82678f))
* **dogfood:** register UserPromptSubmit symlink-heal hook ([#624](https://github.com/rjskene/pipeline/issues/624)) ([6078ee2](https://github.com/rjskene/pipeline/commit/6078ee27db8c99bfc1003e4932abd92229663c6c))
* **init:** add /pipeline:init command skill ([37da6e6](https://github.com/rjskene/pipeline/commit/37da6e69762e91d31b9618ac4ab254da6f0fa340))
* **init:** add init.sh bootstrap (preflight, config, labels, doctor tail) ([642096e](https://github.com/rjskene/pipeline/commit/642096ed1ceee2e521bb2ecb0ebe17f3b911c25b))


### Bug Fixes

* evaluation fixes for [#621](https://github.com/rjskene/pipeline/issues/621) — allowlist pipeline:init in namespace test ([3ea90e0](https://github.com/rjskene/pipeline/commit/3ea90e0223c24088ea89cbe7bebaa902120c1aae))
* **general:** _resolve-plugin-root.sh prefers published cache over local-marketplace symlink in dogfood sessions (orchestrator runs stale scripts) ([32e7d5c](https://github.com/rjskene/pipeline/commit/32e7d5cc9313cdb6143d0632511cb4d5e23228fa))
* **general:** Dogfood live-update symlink not durable mid-session (/remote-control wipes cache dir; heal only at SessionStart) ([c74300d](https://github.com/rjskene/pipeline/commit/c74300de463e80c38de1c1a1696761174640c4ff))
* **resolve-plugin-root:** prefer enabled local-marketplace install over published cache copy ([#625](https://github.com/rjskene/pipeline/issues/625)) ([354e9ff](https://github.com/rjskene/pipeline/commit/354e9ff7f2b02ec6eaa0c42da3cf74b947d11f8c))

## [0.20.2](https://github.com/rjskene/pipeline/compare/v0.20.1...v0.20.2) (2026-05-29)


### Features

* **dogfood:** add dev/hooks/dogfood-refresh.sh for SessionStart+manual refresh ([0745aa6](https://github.com/rjskene/pipeline/commit/0745aa6bd1d371c11ea27d4d0cf5979300c007b4))
* **dogfood:** add setup-dogfood-local + mode-swap scripts ([d88a4d5](https://github.com/rjskene/pipeline/commit/d88a4d559a427337fc50e6ce06b53eeb63233d56))
* **dogfood:** add symlink-swap helper ([#618](https://github.com/rjskene/pipeline/issues/618)) ([21f526e](https://github.com/rjskene/pipeline/commit/21f526ecfadb70ebfe9b8081fc35f3e2dc1ea112))
* **dogfood:** call symlink-swap after refresh merge ([#618](https://github.com/rjskene/pipeline/issues/618)) ([3d1b0aa](https://github.com/rjskene/pipeline/commit/3d1b0aa7bc58522008855ba43eba785e29356216))
* **dogfood:** local file:// marketplace + auto-refresh hook ([2df0099](https://github.com/rjskene/pipeline/commit/2df0099b3f654cdd8aafe7e5b2dff71b4057c41e))
* **dogfood:** register SessionStart auto-refresh hook in .claude/settings.json ([000214b](https://github.com/rjskene/pipeline/commit/000214bd4797f1bd517df38a895adb93570899f5))
* **dogfood:** symlink-swap installPath so `git pull` actually = live update ([202f8a5](https://github.com/rjskene/pipeline/commit/202f8a59fe6e53bd21bf6520062b590b4c1c6231))


### Bug Fixes

* **dogfood:** drop bare /pipeline:* substring from setup script comment ([e0181fb](https://github.com/rjskene/pipeline/commit/e0181fb001de34589162311c212f4f4211386cae))
* **dogfood:** scope setup-dogfood-local.sh scrub to current repo's projectPath ([c4ca866](https://github.com/rjskene/pipeline/commit/c4ca866f6e3bbcbaa7e958faad1d19650905f00e))
* **dogfood:** scope setup-dogfood-local.sh scrub to current repo's projectPath ([352559e](https://github.com/rjskene/pipeline/commit/352559e9d9f45147c3c3cd9675aa2c5b2a05883f)), closes [#615](https://github.com/rjskene/pipeline/issues/615)
* **dogfood:** setup-dogfood-local.sh writes invalid source.source="local" — Claude Code accepts "file" ([675a0e6](https://github.com/rjskene/pipeline/commit/675a0e6ad3d5ccbb596405a3bcb9cf0bc28a926d))
* **dogfood:** write source.source="file" so Claude Code accepts the marketplace entry ([e8ec264](https://github.com/rjskene/pipeline/commit/e8ec264800312c86bbfce252b5a17f3960a3b67f)), closes [#617](https://github.com/rjskene/pipeline/issues/617)
* **review:** redirect dogfood-refresh to main repo when invoked from a worktree ([f622947](https://github.com/rjskene/pipeline/commit/f622947a03c981f357a4f9858e915fc4dffff3e4))

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
