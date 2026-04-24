# ONE Sui — Audit Tracking

**Source:** `/home/rera/one/sui/sources/ONE.move` (850 lines, v0.1.0)
**Submission:** `AUDIT_R1_SUBMISSION.md` (single self-contained file with source inlined, 1096 lines / ~60KB)
**Self-audit:** `SELF_AUDIT_R1.md` (R1 GREEN, 0 C/H/M, 4 LOW applied, 7 INFO)

## Round 1 — External AI auditors

Submit `AUDIT_R1_SUBMISSION.md` to each auditor independently. Do NOT share one auditor's findings with another during R1 (we want genuinely independent parallel reviews).

| Auditor | Status | Submitted | Response | Verdict | Findings |
|---|---|---|---|---|---|
| Gemini 3.1 Pro | **DONE** | 2026-04-25 | 2026-04-25 | **GREEN** | 0 |
| Grok (xAI) | **DONE** | 2026-04-25 | 2026-04-25 | **GREEN** | 0 |
| Cerebras Qwen3-235B | **DONE** | 2026-04-25 | 2026-04-25 | **GREEN** | 1 INFO + 1 LOW |
| DeepSeek | **DONE** | 2026-04-25 | 2026-04-25 | **GREEN** | 0 |
| Kimi | **DONE** | 2026-04-25 | 2026-04-25 | **GREEN** | 1 INFO |
| Claude 4.7 Adaptive (fresh) | **DONE** | 2026-04-25 | 2026-04-25 | **YELLOW** | **1 MEDIUM** + 1 LOW + 2 INFO |

### R1 responses on file
- `r1/gemini_3_1_pro_response.md` — GREEN, 0 findings
- `r1/grok_response.md` — GREEN, 0 findings
- `r1/qwen_response.md` — GREEN, 2 findings: INFO + LOW
- `r1/deepseek_response.md` — GREEN, 0 findings
- `r1/kimi_response.md` — GREEN, 1 INFO
- `r1/claude_4_7_adaptive_fresh_response.md` — **YELLOW**, novel MEDIUM finding (M-01: reset-on-empty zombie inflation)

### Aggregate findings (all pending user decision, NOT applied)

| ID | Severity | Source | Summary |
|---|---|---|---|
| F-1 | INFO | Qwen | `sp_claim` emits no event when pending rewards are zero |
| F-2 | LOW | Qwen | `now + 10` theoretical overflow in staleness check (584B year horizon) |
| F-3 | INFO | Kimi | `sp_settle` saturation cap is dead-code; if triggered, `balance::split` would abort anyway |
| **F-4** | **MEDIUM** | **Claude 4.7 fresh** | **Reset-on-empty + stale-snap zombie inflation: if `total_sp` reaches 0 cleanly (no dust) and a user with `initial>0` but `effective=0` never called settle, reset-on-empty + their redeposit triggers `initial × PRECISION / snap_p` inflation up to 1e9× (capped by MIN_P_THRESHOLD). Fix proposal: add `sp_epoch` counter to Registry + `snapshot_epoch` to SP positions; treat pre-reset epochs as zombie in sp_settle. Statistical defense via dust accumulation, not guaranteed.** |
| F-5 | LOW | Claude 4.7 fresh | No `assert!(reg.sealed)` gate on user-facing entries — pre-seal deploy window interactions unbounded |
| F-6 | INFO | Claude 4.7 fresh | 60s Pyth staleness enables minor oracle-MEV (acceptable trade-off) |
| F-7 | INFO | Claude 4.7 fresh | Test coverage gap on oracle-dependent paths; recommend testnet integration test before mainnet |

### Verdict summary

**5/6 auditors GREEN, 1/6 YELLOW.** Q1-Q16 all answered OK across all six, but Claude 4.7 Adaptive (fresh session) identified one MEDIUM finding (F-4) and one LOW (F-5) that warrant review before publish per their verdict. First non-GREEN audit. Decision pending.

## Submission protocol

Per auditor:
1. Open fresh chat window (no prior context).
2. Paste full `AUDIT_R1_SUBMISSION.md` verbatim.
3. Do not add hints or clarifications unless the auditor flags `NEEDS_INFO`.
4. Record the verdict + raw response in `audit/r1/<auditor>_response.md`.
5. Extract findings into severity-tagged rows in this tracking table.

## Findings aggregation

After all 4 auditors respond, aggregate findings in `AUDIT_R1_FINDINGS.md`:
- Dedupe duplicates (count how many auditors caught the same issue).
- Sort by severity.
- Our response per finding: **APPLY / REJECT / DEFER / NEEDS_INVESTIGATION**.
- Tier-1 (correctness/security) findings: apply before R2.
- Tier-2 (policy/parameter) findings: propose + wait for user sign-off per `feedback_auditor_rec_signoff.md`.

## Round 2 (if triggered)

Trigger R2 if any auditor returns YELLOW or RED, OR if aggregate findings include at least 1 HIGH.

R2 submission includes:
- Diff of code changes since R1.
- Our response to each R1 finding (applied / rejected / deferred).
- Re-ask only the questions where R1 caller returned NEEDS_INFO or FINDING.

## Deploy gate

Package does NOT publish until:
- All 4 R1 auditors return GREEN, OR
- R2 resolves any YELLOW/RED from R1 to all-GREEN.

After publish, plan R4 post-mainnet audit per Aptos precedent (see `aptos_one_v013_audit_state.md` → R4 GREEN after 8 auditors).

---

## Companion: ONE-lite (deferred, separate package)

**Decision recorded 2026-04-25:** Keep current SP-inclusive ONE as primary. Build **ONE-lite** as a SEPARATE sibling package (no SP, pure liquidator-pays-debt Maker Vault style, target ~400 lines) as a user-choice option at launch.

**Architecture:** ONE-lite would drop:
- Stability Pool (sp_deposit/sp_withdraw/sp_claim/sp_settle)
- Reward indices (reward_index_one, reward_index_coll)
- Product factor / cliff guard
- Zombie position handling
- redeem_from_reserve
- route_fee SP routing (simple burn instead)
- All SP-related events + test helpers

**What stays:**
- open_trove, add_collateral, close_trove, redeem, liquidate
- Oracle (Pyth SUI/USD, identical price_8dec)
- destroy_cap / sealing
- coin_registry integration
- Same MCR (200%), fee (1%), liquidation threshold (150%), bonus (10%)

**Delta in liquidate:** liquidator pays full debt in ONE (burned), receives seized collateral + 10% bonus. No SP absorption step. Simple market-driven liquidation.

**Timeline:** Scaffold ONE-lite AFTER ONE v0.1.0 audit R1 clears. Same audit cycle for lite version. Both deployed as separate packages on Sui mainnet.

**Resume pointer:** "lanjut ONE-lite scaffold" after ONE v0.1.0 is sealed.
