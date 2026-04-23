#[test_only]
module ONE::ONE_tests {
    use std::option;
    use std::string;
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use ONE::ONE;

    const MOCK_APT_HOST: address = @0xABCD;

    fun setup(deployer: &signer): Object<Metadata> {
        timestamp::set_time_has_started_for_testing(
            &account::create_signer_for_test(@aptos_framework)
        );
        let apt_signer = account::create_signer_for_test(MOCK_APT_HOST);
        let ctor = object::create_named_object(&apt_signer, b"APT");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &ctor, option::none(),
            string::utf8(b"Aptos Coin"), string::utf8(b"APT"), 8,
            string::utf8(b""), string::utf8(b""),
        );
        let apt_md = object::object_from_constructor_ref<Metadata>(&ctor);
        ONE::init_module_for_test(deployer, apt_md);
        apt_md
    }

    #[test(deployer = @ONE)]
    fun test_init_creates_registry(deployer: &signer) {
        setup(deployer);
        let (debt, sp, p, r1, r2) = ONE::totals();
        assert!(debt == 0, 100);
        assert!(sp == 0, 101);
        assert!(p == 1_000_000_000_000_000_000, 102);
        assert!(r1 == 0, 103);
        assert!(r2 == 0, 104);
    }

    #[test(deployer = @ONE)]
    fun test_warning_text_on_chain(deployer: &signer) {
        setup(deployer);
        let w = ONE::read_warning();
        let prefix = b"ONE is an immutable stablecoin";
        let i = 0;
        while (i < vector::length(&prefix)) {
            assert!(*vector::borrow(&w, i) == *vector::borrow(&prefix, i), 200);
            i = i + 1;
        };
        let pyth_ref = b"Pyth Network";
        assert!(contains_bytes(&w, &pyth_ref), 201);
    }

    #[test(deployer = @ONE)]
    fun test_trove_of_unknown_returns_zero(deployer: &signer) {
        setup(deployer);
        let (c, d) = ONE::trove_of(@0xA11CE);
        assert!(c == 0 && d == 0, 300);
    }

    #[test(deployer = @ONE)]
    fun test_sp_of_unknown_returns_zero(deployer: &signer) {
        setup(deployer);
        let (bal, p_one, p_coll) = ONE::sp_of(@0xA11CE);
        assert!(bal == 0 && p_one == 0 && p_coll == 0, 400);
    }

    #[test(deployer = @ONE)]
    fun test_metadata_addr_stable(deployer: &signer) {
        setup(deployer);
        assert!(ONE::metadata_addr() == ONE::metadata_addr(), 500);
    }

    #[test(deployer = @ONE, user = @0xA11CE)]
    #[expected_failure(abort_code = 2, location = ONE::ONE)]
    fun test_close_trove_without_trove_aborts(deployer: &signer, user: &signer) {
        setup(deployer);
        ONE::close_trove(user);
    }

    #[test(deployer = @ONE, user = @0xA11CE)]
    #[expected_failure(abort_code = 5, location = ONE::ONE)]
    fun test_sp_claim_without_position_aborts(deployer: &signer, user: &signer) {
        setup(deployer);
        ONE::sp_claim(user);
    }

    #[test(deployer = @ONE, user = @0xA11CE)]
    #[expected_failure(abort_code = 5, location = ONE::ONE)]
    fun test_sp_withdraw_without_position_aborts(deployer: &signer, user: &signer) {
        setup(deployer);
        ONE::sp_withdraw(user, 100_000_000);
    }

    #[test(deployer = @ONE, user = @0xA11CE)]
    #[expected_failure(abort_code = 6, location = ONE::ONE)]
    fun test_sp_deposit_zero_aborts(deployer: &signer, user: &signer) {
        setup(deployer);
        ONE::sp_deposit(user, 0);
    }

    #[test(deployer = @ONE)]
    fun test_sp_position_creation_via_helper(deployer: &signer) {
        setup(deployer);
        let u = @0xBEEF;
        ONE::test_create_sp_position(u, 100_000_000);
        let (bal, p_one, p_coll) = ONE::sp_of(u);
        assert!(bal == 100_000_000, 600);
        assert!(p_one == 0, 601);
        assert!(p_coll == 0, 602);
    }

    #[test(deployer = @ONE)]
    fun test_reward_index_increment_and_pending(deployer: &signer) {
        setup(deployer);
        let u = @0xBEEF;
        ONE::test_create_sp_position(u, 100_000_000);
        ONE::test_route_fee_virtual(1_000_000);
        let (_, _, _, r_one, _) = ONE::totals();
        assert!(r_one == 7_500_000_000_000_000, 700);
        let (bal, p_one, p_coll) = ONE::sp_of(u);
        assert!(bal == 100_000_000, 701);
        assert!(p_one == 750_000, 702);
        assert!(p_coll == 0, 703);
    }

    #[test(deployer = @ONE)]
    fun test_reward_index_pro_rata_two_depositors(deployer: &signer) {
        setup(deployer);
        ONE::test_create_sp_position(@0xAAAA, 200_000_000);
        ONE::test_create_sp_position(@0xBBBB, 100_000_000);
        ONE::test_route_fee_virtual(300_000_000);
        let (_, pa, _) = ONE::sp_of(@0xAAAA);
        let (_, pb, _) = ONE::sp_of(@0xBBBB);
        assert!(pa == 150_000_000, 800);
        assert!(pb == 75_000_000, 801);
    }

    #[test(deployer = @ONE)]
    fun test_liquidation_single_depositor(deployer: &signer) {
        setup(deployer);
        ONE::test_create_sp_position(@0xAAAA, 10_000_000_000);
        ONE::test_simulate_liquidation(2_000_000_000, 2_500_000_000);
        let (bal, p_one, p_coll) = ONE::sp_of(@0xAAAA);
        assert!(bal == 8_000_000_000, 900);
        assert!(p_one == 0, 901);
        assert!(p_coll == 2_500_000_000, 902);
        let (_, total_sp, pf, _, r_coll) = ONE::totals();
        assert!(total_sp == 8_000_000_000, 903);
        assert!(pf == 800_000_000_000_000_000, 904);
        assert!(r_coll == 250_000_000_000_000_000, 905);
    }

    #[test(deployer = @ONE)]
    fun test_liquidation_two_depositors_pro_rata(deployer: &signer) {
        setup(deployer);
        ONE::test_create_sp_position(@0xAAAA, 10_000_000_000);
        ONE::test_create_sp_position(@0xBBBB, 10_000_000_000);
        ONE::test_simulate_liquidation(2_000_000_000, 2_500_000_000);
        let (a_bal, _, a_coll) = ONE::sp_of(@0xAAAA);
        let (b_bal, _, b_coll) = ONE::sp_of(@0xBBBB);
        assert!(a_bal == 9_000_000_000, 1000);
        assert!(b_bal == 9_000_000_000, 1001);
        assert!(a_coll == 1_250_000_000, 1002);
        assert!(b_coll == 1_250_000_000, 1003);
    }

    #[test(deployer = @ONE)]
    fun test_liquidation_sequential_math(deployer: &signer) {
        setup(deployer);
        ONE::test_create_sp_position(@0xAAAA, 10_000_000_000);
        ONE::test_simulate_liquidation(2_000_000_000, 2_500_000_000);
        ONE::test_create_sp_position(@0xBBBB, 10_000_000_000);
        ONE::test_simulate_liquidation(1_000_000_000, 1_500_000_000);
        let (a_bal, _, a_coll) = ONE::sp_of(@0xAAAA);
        assert!(a_bal == 7_555_555_555, 1100);
        assert!(a_coll == 3_166_666_666, 1101);
        let (b_bal, _, b_coll) = ONE::sp_of(@0xBBBB);
        assert!(b_bal == 9_444_444_444, 1102);
        assert!(b_coll == 833_333_333, 1103);
    }

    #[test(deployer = @ONE)]
    #[expected_failure(abort_code = 14, location = ONE::ONE)]
    fun test_liquidation_cliff_guard_aborts(deployer: &signer) {
        setup(deployer);
        ONE::test_create_sp_position(@0xAAAA, 10_000_000_000);
        ONE::test_simulate_liquidation(9_999_999_000, 1_000_000_000);
        ONE::test_simulate_liquidation(999, 500);
    }

    // --- destroy_cap / ResourceCap tests ---

    #[test(deployer = @ONE)]
    #[expected_failure(abort_code = 17, location = ONE::ONE)]
    fun test_destroy_cap_non_origin_aborts(deployer: &signer) {
        setup(deployer);
        ONE::test_stash_cap_for_test(deployer);
        let attacker = account::create_signer_for_test(@0xBEEF);
        ONE::destroy_cap(&attacker);
    }

    #[test(deployer = @ONE)]
    fun test_destroy_cap_consumes_resource(deployer: &signer) {
        setup(deployer);
        ONE::test_stash_cap_for_test(deployer);
        let origin = account::create_signer_for_test(@origin);
        ONE::destroy_cap(&origin);
    }

    #[test(deployer = @ONE)]
    #[expected_failure(abort_code = 18, location = ONE::ONE)]
    fun test_destroy_cap_double_call_aborts(deployer: &signer) {
        setup(deployer);
        ONE::test_stash_cap_for_test(deployer);
        let origin = account::create_signer_for_test(@origin);
        ONE::destroy_cap(&origin);
        ONE::destroy_cap(&origin);
    }

    fun contains_bytes(hay: &vector<u8>, needle: &vector<u8>): bool {
        let hn = vector::length(hay);
        let nn = vector::length(needle);
        if (nn == 0 || nn > hn) return nn == 0;
        let i = 0;
        while (i + nn <= hn) {
            let j = 0;
            let ok = true;
            while (j < nn) {
                if (*vector::borrow(hay, i + j) != *vector::borrow(needle, j)) {
                    ok = false;
                    break
                };
                j = j + 1;
            };
            if (ok) return true;
            i = i + 1;
        };
        false
    }

    // R2-C01 regression: zombie positions (initial=0) must have their snapshots
    // refreshed on every sp_settle call, not left stale. Otherwise a later
    // redeposit pairs a fresh initial_balance with a stale snap_product /
    // snap_index_one pair, inflating the next pending_one by Δindex / stale_P.
    #[test(deployer = @ONE)]
    fun test_zombie_redeposit_no_phantom_reward(deployer: &signer) {
        setup(deployer);
        let alice = @0xA11CE;

        // Seed a zombie: initial=0, stale snap_p far below current P,
        // stale snap_i_one / snap_i_coll far below current reward indices.
        ONE::test_set_sp_position(alice, 0, 100_000_000_000_000, 500, 500);
        ONE::test_force_reward_indices(1_000_000_000_000_000_000, 2_000_000_000_000_000_000);

        ONE::test_call_sp_settle(alice);

        // Fix validation: snaps must be refreshed to current registry state
        // so a subsequent redeposit cannot inherit the stale pre-zombie diff.
        let (initial, snap_p, snap_i_one, snap_i_coll) = ONE::test_get_sp_snapshots(alice);
        assert!(initial == 0, 900);
        assert!(snap_p == 1_000_000_000_000_000_000, 901);
        assert!(snap_i_one == 1_000_000_000_000_000_000, 902);
        assert!(snap_i_coll == 2_000_000_000_000_000_000, 903);
    }
}
