#[test_only]
module ONE::ONE_tests {
    use std::option;
    use std::string;
    use std::vector;
    use supra_framework::account;
    use supra_framework::fungible_asset::Metadata;
    use supra_framework::object::{Self, Object};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use ONE::ONE;

    const MOCK_SUPRA_HOST: address = @0xABCD;

    fun setup(deployer: &signer): Object<Metadata> {
        timestamp::set_time_has_started_for_testing(
            &account::create_signer_for_test(@supra_framework)
        );
        // Create mock SUPRA FA
        let supra_signer = account::create_signer_for_test(MOCK_SUPRA_HOST);
        let ctor = object::create_named_object(&supra_signer, b"SUPRA");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &ctor, option::none(),
            string::utf8(b"Supra"), string::utf8(b"SUPRA"), 8,
            string::utf8(b""), string::utf8(b""),
        );
        let supra_md = object::object_from_constructor_ref<Metadata>(&ctor);
        ONE::init_module_for_test(deployer, supra_md);
        supra_md
    }

    // --- init + view sanity ---

    #[test(deployer = @ONE)]
    fun test_init_creates_registry(deployer: &signer) {
        setup(deployer);
        let (debt, sp, p, r1, r2) = ONE::totals();
        assert!(debt == 0, 100);
        assert!(sp == 0, 101);
        assert!(p == 1_000_000_000_000_000_000, 102);  // PRECISION = initial product_factor
        assert!(r1 == 0, 103);
        assert!(r2 == 0, 104);
    }

    #[test(deployer = @ONE)]
    fun test_warning_text_on_chain(deployer: &signer) {
        setup(deployer);
        let w = ONE::read_warning();
        let prefix = b"ONE is an immutable";
        let i = 0;
        while (i < vector::length(&prefix)) {
            assert!(*vector::borrow(&w, i) == *vector::borrow(&prefix, i), 200);
            i = i + 1;
        };
        let sig = b"made by solo dev and claude ai";
        assert!(contains_bytes(&w, &sig), 201);
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
        let (bal, p_one, p_supra) = ONE::sp_of(@0xA11CE);
        assert!(bal == 0 && p_one == 0 && p_supra == 0, 400);
    }

    #[test(deployer = @ONE)]
    fun test_metadata_addr_stable(deployer: &signer) {
        setup(deployer);
        assert!(ONE::metadata_addr() == ONE::metadata_addr(), 500);
    }

    // --- error paths ---

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

    // --- SP accounting math (using test helpers to bypass FA plumbing) ---

    #[test(deployer = @ONE)]
    fun test_sp_position_creation_via_helper(deployer: &signer) {
        setup(deployer);
        let u = @0xBEEF;
        ONE::test_create_sp_position(u, 100_000_000);
        let (bal, p_one, p_supra) = ONE::sp_of(u);
        assert!(bal == 100_000_000, 600);
        assert!(p_one == 0, 601);
        assert!(p_supra == 0, 602);
    }

    #[test(deployer = @ONE)]
    fun test_reward_index_increment_and_pending(deployer: &signer) {
        setup(deployer);
        let u = @0xBEEF;
        ONE::test_create_sp_position(u, 100_000_000);
        ONE::test_route_fee_virtual(1_000_000);
        // Fee 1e6 raw arrives: 25% (250_000) burned, 75% (750_000) to SP
        // r_one += 750_000 * 1e18 / 1e8 = 7.5e15
        let (_, _, _, r_one, _) = ONE::totals();
        assert!(r_one == 7_500_000_000_000_000, 700);
        // Pending = initial * r_one / snap_product = 1e8 * 7.5e15 / 1e18 = 750_000
        let (bal, p_one, p_supra) = ONE::sp_of(u);
        assert!(bal == 100_000_000, 701);
        assert!(p_one == 750_000, 702);
        assert!(p_supra == 0, 703);
    }

    #[test(deployer = @ONE)]
    fun test_reward_index_pro_rata_two_depositors(deployer: &signer) {
        setup(deployer);
        ONE::test_create_sp_position(@0xAAAA, 200_000_000);
        ONE::test_create_sp_position(@0xBBBB, 100_000_000);
        ONE::test_route_fee_virtual(300_000_000);
        // Fee 3e8: 25% burned (7.5e7), 75% to SP (2.25e8)
        // r_one += 2.25e8 * 1e18 / 3e8 = 7.5e17
        // Alice: 2e8 * 7.5e17 / 1e18 = 1.5e8
        // Bob:   1e8 * 7.5e17 / 1e18 = 7.5e7
        let (_, pa, _) = ONE::sp_of(@0xAAAA);
        let (_, pb, _) = ONE::sp_of(@0xBBBB);
        assert!(pa == 150_000_000, 800);
        assert!(pb == 75_000_000, 801);
    }

    // --- Liquity-P math tests ---

    #[test(deployer = @ONE)]
    fun test_liquidation_single_depositor(deployer: &signer) {
        setup(deployer);
        // Alice deposits 100 ONE (raw 1e10 at 8 dec)
        ONE::test_create_sp_position(@0xAAAA, 10_000_000_000);
        // Simulate liq: debt=20 ONE, sp_supra_absorbed=25 (raw units)
        ONE::test_simulate_liquidation(2_000_000_000, 2_500_000_000);
        // Alice pending: 25 SUPRA, effective balance: 80 ONE
        // Formula: effective = 100 * 0.8 / 1 = 80
        //          pending_supra = 100 * (0.25e18 - 0) / 1e18 = 25
        let (bal, p_one, p_supra) = ONE::sp_of(@0xAAAA);
        assert!(bal == 8_000_000_000, 900);
        assert!(p_one == 0, 901);
        assert!(p_supra == 2_500_000_000, 902);
        // Verify global state after liq
        let (_, total_sp, pf, _, r_supra) = ONE::totals();
        assert!(total_sp == 8_000_000_000, 903);
        // P_new = 1e18 * 80/100 = 0.8e18
        assert!(pf == 800_000_000_000_000_000, 904);
        // r_supra = 0 + 25 * 1e18 / 100 (nominal is 1e10, so 25e8 * 1e18 / 1e10 = 25e16)
        assert!(r_supra == 250_000_000_000_000_000, 905);
    }

    #[test(deployer = @ONE)]
    fun test_liquidation_two_depositors_pro_rata(deployer: &signer) {
        setup(deployer);
        // Alice 100, Bob 100 → total 200
        ONE::test_create_sp_position(@0xAAAA, 10_000_000_000);
        ONE::test_create_sp_position(@0xBBBB, 10_000_000_000);
        // Liq: debt=20, absorbed=25
        ONE::test_simulate_liquidation(2_000_000_000, 2_500_000_000);
        // Each should get 12.5 SUPRA (half of 25), effective 90 each
        // P_new = 1e18 * 180/200 = 0.9e18
        let (a_bal, _, a_supra) = ONE::sp_of(@0xAAAA);
        let (b_bal, _, b_supra) = ONE::sp_of(@0xBBBB);
        assert!(a_bal == 9_000_000_000, 1000);
        assert!(b_bal == 9_000_000_000, 1001);
        assert!(a_supra == 1_250_000_000, 1002);
        assert!(b_supra == 1_250_000_000, 1003);
    }

    #[test(deployer = @ONE)]
    fun test_liquidation_sequential_math(deployer: &signer) {
        setup(deployer);
        // Alice deposits 100, then liq1 (debt=20, coll=25)
        ONE::test_create_sp_position(@0xAAAA, 10_000_000_000);
        ONE::test_simulate_liquidation(2_000_000_000, 2_500_000_000);
        // Now Bob deposits 100 at P=0.8
        ONE::test_create_sp_position(@0xBBBB, 10_000_000_000);
        // total_sp now = 80 + 100 = 180. P_current = 0.8e18.
        // Liq2: debt=10, coll=15
        ONE::test_simulate_liquidation(1_000_000_000, 1_500_000_000);
        // Liquity-P expected after liq2:
        //   reward_index_supra += 15 * 0.8e18 / 180 = 0.0667e18 scaled
        //   New r_supra = 0.25e18 + 0.0667e18 = 0.3167e18 ≈ 316_666_666_666_666_666
        //   P_new = 0.8e18 * 170/180 = 0.7555...e18 ≈ 755_555_555_555_555_555
        //   total_sp = 170

        // Alice: deposited at P=1e18, snap_s_supra=0.
        //   pending_supra = 100 * (0.3167e18 - 0) / 1e18 = ~31.67 → 3_166_666_666
        //   effective = 100 * 0.7555 / 1 = ~75.56 → 7_555_555_555
        let (a_bal, _, a_supra) = ONE::sp_of(@0xAAAA);
        assert!(a_bal == 7_555_555_555, 1100);
        assert!(a_supra == 3_166_666_666, 1101);

        // Bob: deposited at P=0.8e18, snap_s_supra=0.25e18.
        //   pending_supra = initial * (r_supra_now - snap) / snap_p
        //                 = 1e10 * (316_666_666_666_666_666 - 250_000_000_000_000_000) / 8e17
        //                 = 1e10 * 66_666_666_666_666_666 / 8e17
        //                 = 833_333_333 (rounded down)
        //   effective = 1e10 * 755_555_555_555_555_555 / 8e17 = 9_444_444_444 (rounded down)
        let (b_bal, _, b_supra) = ONE::sp_of(@0xBBBB);
        assert!(b_bal == 9_444_444_444, 1102);
        assert!(b_supra == 833_333_333, 1103);
    }

    /// R1 fix batch: cliff guard aborts when product_factor would drop below MIN_P_THRESHOLD (1e9).
    /// Drives P down in two steps and asserts the second step aborts with E_P_CLIFF (code 14).
    #[test(deployer = @ONE)]
    #[expected_failure(abort_code = 14, location = ONE::ONE)]
    fun test_liquidation_cliff_guard_aborts(deployer: &signer) {
        setup(deployer);
        ONE::test_create_sp_position(@0xAAAA, 10_000_000_000);
        // Liq1: debt = 9_999_999_000 → P_new = 1e18 * 1000 / 1e10 = 1e11, total_sp = 1000.
        ONE::test_simulate_liquidation(9_999_999_000, 1_000_000_000);
        // Liq2: debt = 999 → new_p = 1e11 * 1 / 1000 = 1e8 < MIN_P_THRESHOLD (1e9) → abort.
        ONE::test_simulate_liquidation(999, 500);
    }

    // --- helpers ---

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
}
