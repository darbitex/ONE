// ONE bootstrap script — converts deployer's Coin<SupraCoin> to FA,
// then opens the genesis trove. Run EXACTLY ONCE after publish, before auth_key null.
// Running twice adds to the genesis trove's debt/collateral — not catastrophic
// but yields an unintentionally-large genesis position. Verify first tx before rerun.
//
// Args:
//   supra_amt (u64): raw SUPRA amount for collateral (8 dec).
//                    Must satisfy: supra_amt * price_8dec / 1e8 >= 2 * debt
//                    (Open MCR = 200%). At SUPRA=$0.000408 -> min ~4_900 * 1e8 for 1 ONE debt.
//   debt (u64):      raw ONE to mint (8 dec). Min MIN_DEBT = 1 ONE = 100_000_000.
script {
    use std::signer;
    use supra_framework::coin;
    use supra_framework::primary_fungible_store;
    use supra_framework::supra_coin::SupraCoin;
    use ONE::ONE;

    fun bootstrap(deployer: &signer, supra_amt: u64, debt: u64) {
        // Step 1: Coin<SupraCoin> → FA (one-way, per Supra migration direction)
        let c = coin::withdraw<SupraCoin>(deployer, supra_amt);
        let fa = coin::coin_to_fungible_asset(c);
        primary_fungible_store::deposit(signer::address_of(deployer), fa);

        // Step 2: Open genesis trove
        ONE::open_trove(deployer, supra_amt, debt);
    }
}
