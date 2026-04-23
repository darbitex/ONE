# gpt-oss  — openai/gpt-oss-120b:free

- **Severity:** HIGH  
  **Location:** `ONE::ONE::price_8dec()` (line ≈ 84)  
  **Issue:** The exponent sign check is inverted – `assert!(i64::get_is_negative(&e_i64), E_PRICE_EXPO);` aborts when the exponent **is** negative, but Pyth USD feeds use a negative exponent.  
  **Impact:** All oracle‑dependent entry functions (open, redeem, liquidate, reserve redeem) will abort on every valid price update, rendering the stablecoin unusable.  
  **Recommendation:** Change the assertion to `assert!(!i64::get_is_negative(&e_i64), E_PRICE_EXPO);` (or rename the error) so that a negative exponent is accepted.  
  **Confidence:** 95 %

- **Severity:** MEDIUM  
  **Location:** `ONE::ONE::liquidate()` (line ≈ 210)  
  **Issue:** Liquidation requires `r.total_sp > debt`. If `total_sp == debt` the transaction aborts, leaving an under‑collateralised trove permanently stuck (no further liquidations possible).  
  **Impact:** Users can lock the protocol in an insolvent state by creating a trove whose debt exactly equals the current SP size.  
  **Recommendation:** Allow `>=` (or handle the edge case by burning the exact SP amount and setting `product_factor` to `MIN_P_THRESHOLD`).  
  **Confidence:** 80 %

- **Severity:** MEDIUM  
  **Location:** `ONE::ONE::destroy_cap()` (line ≈ 45) and `ONE::ONE::init_module()` (line ≈ 71)  
  **Issue:** The cap is retrieved via `resource_account::retrieve_resource_account_cap` in `init_module`. A malicious origin could call `retrieve_resource_account_cap` **before** `init_module` runs, keep the `SignerCapability`, and skip `init_module` altogether. The contract would then have no `ResourceCap` stored, making `destroy_cap` abort, but the attacker retains the capability to sign as `@ONE` forever.  
  **Impact:** Breaks the “immutable after destroy” guarantee; the origin (or any compromised key) could continue to upgrade or drain the contract.  
  **Recommendation:** Make `init_module` the only entry that can retrieve the cap by marking the function `public(entry)` and enforcing that it is called in the same transaction as package publish, or store the cap in a temporary module‑private resource that cannot be accessed externally. Additionally, add a check that `exists<ResourceCap>(@ONE)` is false before retrieving.  
  **Confidence:** 70 %

- **Severity:** LOW  
  **Location:** `ONE::ONE::sp_settle()` (line ≈ 124)  
  **Issue:** Uses `u256` arithmetic but casts the final pending rewards to `u64` without overflow checks. Extremely large reward accruals (possible over decades) could overflow `u64`, silently truncating rewards.  
  **Impact:** Loss of reward precision; SP participants may receive less than entitled.  
  **Recommendation:** Add an explicit overflow check before casting, e.g., `assert!(pending_one <= u64::MAX, E_DECIMAL_OVERFLOW);`.  
  **Confidence:** 85 %

- **Severity:** INFO  
  **Location:** `ONE::ONE::redeem_impl()` (line ≈ 166)  
  **Issue:** The function does not verify that `coll_out` fits into `u64` after the division; the cast `(as u64)` truncates on overflow. In extreme low‑price scenarios `coll_out` could exceed `u64::MAX` and wrap to a small value, causing under‑collateralisation.  
  **Impact:** Potential loss of collateral for the protocol.  
  **Recommendation:** Perform a checked conversion or abort if `coll_out > u64::MAX`.  
  **Confidence:** 60 %

- **Severity:** INFO  
  **Location:** `ONE::ONE::open_impl()` (line ≈ 102)  
  **Issue:** Allows `coll_amt = 0` when opening a new trove (if `is_existing` is false). This creates a debt‑only trove with no collateral, which immediately fails the collateral‑ratio check but the check is performed **after** adding the collateral, so it aborts correctly. However, the error code returned is `E_COLLATERAL` (1) which is also used for other collateral checks, making debugging harder.  
  **Impact:** Minor usability confusion.  
  **Recommendation:** Use a distinct error code for “zero‑collateral open”.  
  **Confidence:** 70 %

- **Severity:** INFO  
  **Location:** `ONE::ONE::price_8dec()` (line ≈ 84)  
  **Issue:** The staleness check uses two asserts with the same error code `E_STALE`. One checks “too old”, the other “timestamp in future”. Distinguishing them would aid debugging.  
  **Impact:** Minor.  
  **Recommendation:** Use separate error codes.  
  **Confidence:** 90 %

**Verdict:** NEEDS‑FIX

---
tokens: in=12696 out=1871 dt=27.9s
