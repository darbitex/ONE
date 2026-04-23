/// Bootstrap script: Pyth VAA update + open_trove + sp_deposit in one atomic tx.
/// Call with fresh VAA bytes (from hermes.pyth.network) to ensure oracle freshness
/// before the ONE module reads it.
script {
    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use pyth::pyth;
    use ONE::ONE;

    fun bootstrap(
        user: &signer,
        vaa_bytes: vector<vector<u8>>,
        apt_amt: u64,
        debt: u64,
        sp_amount: u64,
    ) {
        let fee_amount = pyth::get_update_fee(&vaa_bytes);
        let fee_coin = coin::withdraw<AptosCoin>(user, fee_amount);
        pyth::update_price_feeds(vaa_bytes, fee_coin);

        ONE::open_trove(user, apt_amt, debt);

        if (sp_amount > 0) {
            ONE::sp_deposit(user, sp_amount);
        };
        let _ = signer::address_of(user);
    }
}
