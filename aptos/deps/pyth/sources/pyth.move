module pyth::pyth {
    use aptos_framework::coin::Coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use pyth::price_identifier::PriceIdentifier;
    use pyth::price::Price;

    public fun get_price(_price_identifier: &PriceIdentifier): Price {
        abort 0
    }

    public fun get_price_no_older_than(_price_identifier: PriceIdentifier, _max_age_secs: u64): Price {
        abort 0
    }

    public fun get_price_unsafe(_price_identifier: &PriceIdentifier): Price {
        abort 0
    }

    public fun get_update_fee(_vaas: &vector<vector<u8>>): u64 {
        abort 0
    }

    public fun update_price_feeds(_vaas: vector<vector<u8>>, _fee: Coin<AptosCoin>) {
        abort 0
    }

    public entry fun update_price_feeds_with_funder(_signer: &signer, _vaas: vector<vector<u8>>) {
        abort 0
    }
}
