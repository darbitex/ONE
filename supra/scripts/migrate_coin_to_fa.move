// One-shot migration: Coin<SupraCoin> -> FA (primary store).
// Usable by any SUPRA holder to move their balance to FA form,
// required before interacting with ONE protocol.
//
// Args:
//   amount (u64): raw SUPRA to migrate (8 dec).
script {
    use std::signer;
    use supra_framework::coin;
    use supra_framework::primary_fungible_store;
    use supra_framework::supra_coin::SupraCoin;

    fun migrate_coin_to_fa(user: &signer, amount: u64) {
        let c = coin::withdraw<SupraCoin>(user, amount);
        let fa = coin::coin_to_fungible_asset(c);
        primary_fungible_store::deposit(signer::address_of(user), fa);
    }
}
