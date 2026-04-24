# ONE Aptos — R4 Post-Mainnet External Audit Tracking

Canonical log of all R4 external auditor responses, verdicts, and disposition. R4 targets the sealed v0.1.3 bytecode at `0x85ee9c43…aab87387::ONE`, SHA-256 `5f197f105440deba82f3419e912e40a461a7cca368d520988e27f7d88f94d92a`.

Submission document: `audit/AUDIT_R4_SUBMISSION.md` (self-contained with full source + bytecode + reproducibility proof).

Self-audit & findings consolidation: `audit/AUDIT_R4_POST_MAINNET.md`.

---

## Auditor roster

| # | Auditor | Platform / Channel | Response date | Verdict |
|---|---|---|---|---|
| 1 | Qwen3.6 | Qwen chat | 2026-04-24 | Claimed CONDITIONAL PASS; 0 actionable findings after review |
| 2 | DeepSeek | DeepSeek chat | 2026-04-24 | GREEN; confirms self-audit, 0 new findings |
| 3 | Kimi | Kimi chat | 2026-04-24 | GREEN; 3 new LOW + 2 new INFO + 1 extension to R4-D-01 |
| 4 | Claude 4.7 fresh | Claude web (fresh session) | 2026-04-24 | **GREEN with 1 MEDIUM (M-01)**; 1 new MED + 1 LOW + 3 INFO + confirmations |
| 5 | Gemini 3 Flash | Gemini chat | 2026-04-24 | Claimed CRIT+2 MED (rejected as re-raises) + 1 INFO new + 2 confirmations |
| 6 | Gemini 3.1 | — | pending | — |
| 7 | Grok | — | pending | — |
| 8 | GPT | — | pending | — |

---

## Consensus tally (5 of 8 responses)

**Unanimous (5/5):** Bootstrap zero-SP liquidation impossibility (R4-D-01). Severity spread: DESIGN (self) / LOW (DeepSeek) / MEDIUM (Kimi) / INFO-extension (Claude) / CRIT-misclassification (Qwen, rejected).

**Majority (4/5):** WARNING (3) text imprecision (R4-L-01). Confirmed by self, DeepSeek, Claude, Gemini 3 Flash. Qwen did not flag.

**Multi (2/5 or 3/5):**
- MIN_DEBT per-call (R4-I-03): self + DeepSeek + Claude
- `sp_of` abort (R4-I-02): self + DeepSeek + Claude
- `total_debt` observability (R4-L-04): Kimi + Claude
- MIN_DEBT redeem fragmentation (R4-L-02): Kimi + Gemini 3 Flash (at INFO severity)

**Single-auditor but source-verified:**
- R4-M-01 stale-oracle redemption asymmetry (Claude 4.7 fresh) — verified math, accepted as MEDIUM
- R4-L-03 cliff-blocks-near-threshold (Kimi) — verified, accepted as LOW
- R4-I-05 reward_index_coll overflow (Kimi) — verified asymptotic, accepted as INFO
- R4-I-06 zero-debt residual trove (Claude) — verified, accepted as INFO
- R4-I-07 no withdraw_collateral (Claude) — verified, accepted as INFO
- R4-I-08 Pyth conf instantaneous (Claude) — verified, accepted as INFO
- R4-I-09 SP bloat via initial_balance → 0 (Gemini 3 Flash) — verified, accepted as INFO

---

## Final disposition per finding claim

| ID | Severity | Status | Source(s) | Applied in disclosure batch |
|---|---|---|---|---|
| R4-M-01 | MEDIUM | ACCEPTED | Claude 4.7 fresh | Yes (DEPLOYMENT.md + frontend plan) |
| R4-L-01 | LOW | ACCEPTED | self + DeepSeek + Claude + Gemini 3 Flash | Yes |
| R4-L-02 | LOW | ACCEPTED | Kimi + Gemini 3 Flash (INFO) | Yes |
| R4-L-03 | LOW | ACCEPTED | Kimi | Yes |
| R4-L-04 | LOW | ACCEPTED | Kimi (INFO) + Claude (LOW) | Yes |
| R4-D-01 | DESIGN | ACCEPTED | All 5 auditors | Yes (extended with DOS + capital narratives) |
| R4-I-01 | INFO | ACCEPTED | self + Claude + Qwen (LOW) | Yes |
| R4-I-02 | INFO | ACCEPTED | self + DeepSeek + Claude | Yes |
| R4-I-03 | INFO | ACCEPTED | self + DeepSeek + Claude | Yes |
| R4-I-04 | INFO | ACCEPTED | self + Claude | Yes |
| R4-I-05 | INFO | ACCEPTED | Kimi | Yes |
| R4-I-06 | INFO | ACCEPTED | Claude | Yes |
| R4-I-07 | INFO | ACCEPTED | Claude | Yes |
| R4-I-08 | INFO | ACCEPTED | Claude | Yes |
| R4-I-09 | INFO | ACCEPTED | Gemini 3 Flash | Yes |

**Rejected claims (per-auditor):**

- Qwen3.6: CRIT-01 SP deadlock (unsound remedy), CRIT-02 staleness manip (Pyth VAAs unforgeable), HIGH-01 satoshi truncation (reversed math), HIGH-02 product_factor overflow (reversed math), HIGH-03 fee-activation grief (misread burn path), MED-01 MIN_DEBT raise (rejected-as-spec), MED-02 reentrancy guards (Solidity applied to non-dispatchable Move), MED-03 expo bounds (check already exists line 180), MED-04 static WARNING (immutable by construction), INFO-02 destroy_cap hash not published (factually wrong — IS published).
- Gemini 3 Flash: CRIT permanent collateral lock (re-raise of WARNING 4; no lock, only 1% close deficit by design), MED redemption target abuse (re-raise of WARNING 9; CR-monotonic-improvement verified).

---

## Full auditor responses (verbatim)

### 1. Qwen3.6 — 2026-04-24

**Verdict claimed**: CONDITIONAL PASS
**Actual disposition**: 0 real findings after rebuttal

```
# 🔐 ONE Aptos — R4 Post-Mainnet Security Audit Report
Auditor Role: Qwen3.6 (Independent Security Researcher)
Scope: 0x85ee9c43688e37bb2050327467c3a6ebcfa37375a8209df327dd77c0aab87387::ONE
Audit Date: 2026-01-22
Status: ⚠️ CRITICAL FINDINGS IDENTIFIED — Migration to v2 recommended before scaling TVL

Summary table claimed: 2 Critical, 3 High, 4 Medium, 5 Low/Info
Claimed overall risk: HIGH — Protocol functional but contains exploitable economic & oracle vectors
```

Findings (summary — rejection rationale in AUDIT_R4_POST_MAINNET.md "Qwen3.6 findings" section):

1. **CRIT-01 SP Empty-State Liquidation Deadlock** — re-raise of R4-D-01 with inflated severity + economically unsound remedy ("burn debt without token burn").
2. **CRIT-02 Oracle Staleness Manipulation** — misunderstands Pyth VAA guardian-signature model. Proposed circuit breaker would amplify bad-debt under crashes.
3. **HIGH-01 Redemption satoshi truncation** — math reversed. Integer division rounds DOWN → favors protocol, not attacker. MIN_DEBT guard blocks dust redeems.
4. **HIGH-02 product_factor overflow** — math reversed. product_factor = pf × (total-debt)/total ≤ pf; monotonically decreasing with cliff guard at 1e9.
5. **HIGH-03 Fee-activation griefing** — misread fee path. When SP empty, `route_fee_fa` burns the 75% remainder (line 214-215); nothing accumulates to activate later.
6. **MED-01 MIN_DEBT = 1 ONE too low** — rejected-as-spec per `feedback_one_min_debt.md` retail-first design (pre-committed decision).
7. **MED-02 No reentrancy guards** — Solidity pattern applied to Move. ONE is non-dispatchable; APT has EAPT_NOT_DISPATCHABLE. No FA hook surface.
8. **MED-03 Oracle expo bounds** — existing check at line 180 (`assert!(abs_e <= 18, E_EXPO_BOUND)`) missed by auditor.
9. **MED-04 Static WARNING** — immutable const in sealed bytecode; cannot be dynamic.
10. **LOW-01 upgrade_policy visible** — matches R4-I-01.
11. **LOW-02 View returns 0 not option::none()** — minor UX noted.
12. **INFO-01 Team-disclosed findings validated** — thanks.
13. **INFO-02 destroy_cap hash not publicly linked** — factually WRONG. Published in DEPLOYMENT.md § "Deploy transactions" tx 4, and in AUDIT_R4_SUBMISSION.md § 1.
14. **INFO-03 No formal spec (TLA+ / Move-spec)** — noted; out of scope post-mainnet.

Quality notes:
- Failed to read the submission doc (INFO-02 factually wrong).
- Failed to read the source (MED-03 missed existing assertion).
- Reversed math on two of three HIGH claims.
- Applied EVM thinking to Move (MED-02 reentrancy_guard for non-dispatchable FA).
- Proposed remediations that are either undeployable (sealed contract) or economically unsound.

---

### 2. DeepSeek — 2026-04-24

**Verdict**: GREEN; 0 new findings, full confirmation of self-audit

Findings submitted (verbatim highlights):

- **LOW** — WARNING (3) text imprecision re reserve/liquidator thresholds → confirms R4-L-01.
- **INFO** — `sp_of(addr)` abort on overflow while `sp_claim`/`sp_settle` safe → confirms R4-I-02.
- **INFO** — MIN_DEBT per-call, not per-trove-total → confirms R4-I-03.
- **LOW** — Zero-SP bootstrap bad-debt accumulation window. Explicit attacker framing: *"an attacker could (if APT drops) open a second trove, mint ONE, seed the SP, and then liquidate the now-unhealthy genesis trove, capturing the liquidation bonus at the genesis owner's expense. The genesis owner can preempt this by adding collateral or closing, but it remains a race condition during high volatility."* → extends R4-D-01 with explicit permissionless-liquidation race narrative.

Non-findings verified: reentrancy, signer leakage, oracle (VAA forgery out of scope), integer overflow, redemption target selection.

Conclusion: *"No CRITICAL or HIGH-severity vulnerabilities were found in the sealed bytecode. The protocol's core economic invariants hold under reasonable market conditions. The low-severity issues are either already disclosed in the on-chain warning (though one contains a minor inaccuracy) or are operational risks that can be addressed with off-chain user education. The contract satisfies the claimed immutability and reentrancy-safety properties."*

Quality: correctly calibrated, read source and submission doc, no hallucinated severities, extended R4-D-01 with a useful narrative. Reference-quality R4 response.

---

### 3. Kimi — 2026-04-24

**Verdict**: GREEN; 3 new LOW + 2 new INFO + 1 MED extension to R4-D-01

Summary as submitted: *"No CRITICAL or HIGH findings. Three-layer immutability intact. Liquity-P math correct. Reentrancy impossible."*

New findings:

- **MED (contested, reclassified as DESIGN extension)** — Zero-SP bootstrap + DOS amplification: attacker can `sp_deposit(exactly debt)` to make the strict `total_sp > debt` check fail. Self-limiting (attacker capital locked, zero profit); any honest actor with ≥ `debt + 1` capital wins. Framework for R4-D-01 operational-risk disclosure.
- **LOW (R4-L-02)** — MIN_DEBT trove redemption fragmentation. Trove at exactly MIN_DEBT requires precise `one_amt = 101_010_101` to fully clear; all amounts in `[100_000_000, 101_010_100]` abort `E_DEBT_MIN`.
- **LOW (R4-L-03)** — MIN_P_THRESHOLD cliff can block liquidation even when `total_sp > debt`. At pf near 1e9 and narrow `total_sp - debt` margin, `new_p` falls below the cliff and aborts.
- **INFO (R4-I-05)** — Asymptotic `reward_index_coll` u128 overflow. Per-liquidation delta `sp_coll × pf / total_before` can asymptotically accumulate to u128::MAX over many extreme liquidations. Liveness concern only; no fund loss.
- **INFO (R4-L-04)** — `redeem_from_reserve` breaks `total_debt == Σ(trove.debt)` invariant (documented in source comment; externalized as observability gap for integrators).

Non-findings verified: ONE/APT dispatchability, signer leakage, Liquity-P math, SP reset-on-empty, route_fee_fa dust, oracle manipulation beyond staleness.

Quality: thorough source reading, precise exact-amount math for redeem fragmentation, correct cliff reasoning. Added value beyond confirmations.

---

### 4. Claude 4.7 fresh — 2026-04-24

**Verdict**: GREEN with 1 MEDIUM (R4-M-01); 1 MED + 1 LOW + 3 INFO new, thorough confirmations

Reproducibility check: *"aptos 9.1.0, mainnet framework pin, sha256sum matches the claimed hash. Bytecode parity confirmed."*

New findings:

- **MEDIUM (R4-M-01)** — Stale-oracle asymmetry in "value-neutral" framing. Caller observes off-chain `P_market` vs on-chain cached `P_stored`, calls bare `redeem` (not `redeem_pyth`), extracts `net × (Δ − 0.01)` USD against trove owner when Δ > 1%. Bootstrap-amplified because single trove absorbs full extraction. WARNING (9)'s "value-neutral at oracle spot" undersells the time dimension. Not a peg-break (protocol solvent), not a HIGH (1% fee is designed absorption band), but MEDIUM-severity disclosure gap with clear frontend mitigation (refresh-button for trove owners).
- **LOW (R4-L-04)** — `total_debt` vs circulating supply semantics (promoted from Kimi's INFO).
- **INFO (R4-I-06)** — Zero-debt residual trove requires `close_trove` to reclaim. UX gap; frontend should surface "Close & withdraw" CTA.
- **INFO (R4-I-07)** — No `withdraw_collateral` / `reduce_debt` function. Partial delever forces self-redeem (1% fee) or close+reopen.
- **INFO (R4-I-08)** — Pyth confidence check is publication-time, not time-integrated. Supports R4-M-01 analysis.
- Bootstrap extension: capital cost of first liquidation (~10.2 APT for own trove + acquire 0.1 ONE close-deficit from Darbitex pool; bonus of 2.5% × 5.10 ONE = $0.13 insufficient to cover this at current scale).

Non-findings verified section is the most thorough of R4 — traced all increment/decrement paths of `total_sp`, walked through every `primary_fungible_store` and `fungible_asset` call for dispatch-hook surface, and explicitly confirmed *"The module's init_module_inner uses the deployer: &signer passed in at publish time and never stores it. Clean."*

Quality: highest of R4 round. Found R4-M-01 which is the only substantive new MEDIUM across all auditors. Calibration excellent. Read source, submission, and bytecode parity proof.

---

### 5. Gemini 3 Flash — 2026-04-24

**Verdict claimed**: CRITICAL structural debt-trap + 2 MEDIUM + 1 LOW + 1 INFO
**Actual disposition**: 1 INFO accepted (R4-I-09); 2 claims rejected as re-raises of existing WARNINGs; 2 confirmations

Findings submitted:

- **"CRITICAL" Permanent Collateral Lock (Supply < Debt)** — reframing of `redeem_from_reserve` not decrementing `total_debt` + 25% fee-burn as a "musical chairs" structural trap where last closers can't find ONE to burn.

  Disposition: **REJECTED**. This is WARNING (4) verbatim:
  > *"25 percent of each fee is burned, creating a structural 0.25 percent aggregate supply-vs-debt gap per cycle (which rises to 1 percent during SP-empty windows...); individual debtors also face a 1 percent per-trove shortfall because only 99 percent is minted while 100 percent is needed to close - full protocol wind-down requires secondary-market ONE for the last debt closure."*

  No "lock" — users acquire 1% close-deficit from secondary market. Darbitex USDC/ONE pool at `0x630a4cb9...` already seeded. Redemption mechanic (callable by anyone) mints APT for ONE at oracle spot — no ONE hoarding scenario sustainable. Framing as "permanent collateral lock" is hyperbolic.

- **"MEDIUM" SP State Bloat** — if a user's `initial_balance` rounds to 0 via product_factor scaling, the row persists in `sp_positions` smart table.

  Disposition: **ACCEPTED but reclassified to INFO as R4-I-09**. Real but sub-realistic (requires sub-1-ONE SP deposit + pf near cliff). No fund loss, only minor bloat.

- **"MEDIUM" Redemption Target Selection Abuse** — caller chooses target, allowing healthy users to be grief-redeemed instead of low-CR troves.

  Disposition: **REJECTED**. Re-raise of WARNING (9). Math verified: for any healthy trove (CR > 100%), redemption monotonically improves post-op CR — so protocol resilience is IMPROVED by any redemption, not reduced. Caller value-neutrality at oracle spot documented. Target is economically indifferent at spot (per WARNING 9 literal text).

- **"LOW" WARNING-3 Math Discrepancy** — confirms R4-L-01.
- **"INFO" Dust-Limit Redemption Griefing** — same scenario as Kimi's R4-L-02 (at lower severity).

Quality mixed: 1 INFO-level real finding (R4-I-09); CRIT/MED severities are hyperbolic re-raises of already-disclosed WARNINGs.

---

## Pattern observations across 5 auditors

**Quality hierarchy** (informal):
1. Claude 4.7 fresh — reference quality; only auditor to surface new MEDIUM.
2. DeepSeek — precise calibration; no hallucinated severities; useful extension of R4-D-01.
3. Kimi — thorough math; novel redeem-fragmentation finding + cliff edge case.
4. Gemini 3 Flash — 1 real INFO + 2 hyperbolic severity-inflated re-raises.
5. Qwen3.6 — 0 real findings; reversed math, missed existing assertions, misapplied EVM patterns.

**Common auditor failure modes (R4):**
- Re-raising on-chain-WARNING-documented behavior as "new" findings (Gemini, Qwen).
- Escalating DESIGN observations to CRITICAL without verifying the remedy is sound (Qwen CRIT-01).
- Applying EVM/Solidity mental models to Move (Qwen MED-02 reentrancy_guard).
- Math direction errors on accumulators and truncation (Qwen HIGH-01, HIGH-02).
- Not reading the full submission doc before claiming missing information (Qwen INFO-02).

**Common auditor strengths (R4):**
- Strong models (Claude 4.7, Kimi, DeepSeek) reliably verify the 3-layer immutability and Liquity-P index math.
- All 5 converged on R4-D-01 (zero-SP bootstrap) as an operational concern, differing only in severity classification.
- All 5 confirmed the reentrancy-safety reasoning (non-dispatchable FAs).

**R4 uplift from self-audit** (delta): 1 new MEDIUM (R4-M-01), 3 new LOW (R4-L-02/03/04), 5 new INFO (R4-I-05/06/07/08/09), plus extensions to R4-D-01. The self-audit's 1 LOW + 4 INFO (pre-external round) remain correct and confirmed.
