#[test_only]
module ONE::ONE_tests {
    use sui::clock;
    use sui::coin;
    use sui::test_scenario::{Self as ts, Scenario};
    use std::unit_test;
    use ONE::ONE::{Registry, ONE as ONE_TYPE};

    const DEPLOYER: address = @0xCAFE;
    const ALICE: address = @0xA11CE;
    const BOB: address = @0xB0B;

    fun start(): Scenario {
        let mut sc = ts::begin(DEPLOYER);
        ONE::ONE::init_for_testing(ts::ctx(&mut sc));
        sc
    }

    fun take_reg(sc: &mut Scenario): Registry {
        ts::next_tx(sc, DEPLOYER);
        ts::take_shared<Registry>(sc)
    }

    // ---- basic init / view surface ----

    #[test]
    fun test_init_creates_registry() {
        let mut sc = start();
        let reg = take_reg(&mut sc);
        let (debt, sp, p, r1, r2) = ONE::ONE::totals(&reg);
        assert!(debt == 0, 100);
        assert!(sp == 0, 101);
        assert!(p == 1_000_000_000_000_000_000, 102);
        assert!(r1 == 0, 103);
        assert!(r2 == 0, 104);
        assert!(ONE::ONE::is_sealed(&reg) == false, 105);
        assert!(ONE::ONE::reserve_balance(&reg) == 0, 106);
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    fun test_warning_text_on_chain() {
        let sc = start();
        let w = ONE::ONE::read_warning();
        let prefix = b"ONE is an immutable stablecoin";
        let mut i = 0;
        while (i < std::vector::length(&prefix)) {
            assert!(*std::vector::borrow(&w, i) == *std::vector::borrow(&prefix, i), 200);
            i = i + 1;
        };
        let sui_ref = b"Sui";
        let pyth_ref = b"Pyth Network";
        let governance_ref = b"ORACLE UPGRADE RISK";
        assert!(contains_bytes(&w, &sui_ref), 201);
        assert!(contains_bytes(&w, &pyth_ref), 202);
        assert!(contains_bytes(&w, &governance_ref), 203);
        ts::end(sc);
    }

    #[test]
    fun test_trove_of_unknown_returns_zero() {
        let mut sc = start();
        let reg = take_reg(&mut sc);
        let (c, d) = ONE::ONE::trove_of(&reg, ALICE);
        assert!(c == 0 && d == 0, 300);
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    fun test_sp_of_unknown_returns_zero() {
        let mut sc = start();
        let reg = take_reg(&mut sc);
        let (bal, p_one, p_coll) = ONE::ONE::sp_of(&reg, ALICE);
        assert!(bal == 0 && p_one == 0 && p_coll == 0, 400);
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    fun test_close_cost_unknown_zero() {
        let mut sc = start();
        let reg = take_reg(&mut sc);
        assert!(ONE::ONE::close_cost(&reg, ALICE) == 0, 500);
        ts::return_shared(reg);
        ts::end(sc);
    }

    // ---- abort-path coverage ----

    #[test]
    #[expected_failure(abort_code = ONE::ONE::E_TROVE)]
    fun test_close_trove_without_trove_aborts() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ts::next_tx(&mut sc, ALICE);
        let empty_one = coin::zero<ONE_TYPE>(ts::ctx(&mut sc));
        let out = ONE::ONE::close_trove(&mut reg, empty_one, ts::ctx(&mut sc));
        unit_test::destroy(out);
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ONE::ONE::E_SP_BAL)]
    fun test_sp_claim_without_position_aborts() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ts::next_tx(&mut sc, ALICE);
        ONE::ONE::sp_claim(&mut reg, ts::ctx(&mut sc));
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ONE::ONE::E_SP_BAL)]
    fun test_sp_withdraw_without_position_aborts() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ts::next_tx(&mut sc, ALICE);
        let out = ONE::ONE::sp_withdraw(&mut reg, 100_000_000, ts::ctx(&mut sc));
        unit_test::destroy(out);
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ONE::ONE::E_AMOUNT)]
    fun test_sp_deposit_zero_aborts() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ts::next_tx(&mut sc, ALICE);
        let zero_one = coin::zero<ONE_TYPE>(ts::ctx(&mut sc));
        ONE::ONE::sp_deposit(&mut reg, zero_one, ts::ctx(&mut sc));
        ts::return_shared(reg);
        ts::end(sc);
    }

    // ---- SP math via test helpers (oracle-free) ----

    #[test]
    fun test_sp_position_creation_via_helper() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ONE::ONE::test_create_sp_position(&mut reg, ALICE, 100_000_000);
        let (bal, p_one, p_coll) = ONE::ONE::sp_of(&reg, ALICE);
        assert!(bal == 100_000_000, 600);
        assert!(p_one == 0, 601);
        assert!(p_coll == 0, 602);
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    fun test_reward_index_increment_and_pending() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ONE::ONE::test_create_sp_position(&mut reg, ALICE, 100_000_000);
        ONE::ONE::test_route_fee_virtual(&mut reg, 1_000_000);
        let (_, _, _, r_one, _) = ONE::ONE::totals(&reg);
        assert!(r_one == 7_500_000_000_000_000, 700);
        let (bal, p_one, p_coll) = ONE::ONE::sp_of(&reg, ALICE);
        assert!(bal == 100_000_000, 701);
        assert!(p_one == 750_000, 702);
        assert!(p_coll == 0, 703);
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    fun test_reward_index_pro_rata_two_depositors() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ONE::ONE::test_create_sp_position(&mut reg, ALICE, 200_000_000);
        ONE::ONE::test_create_sp_position(&mut reg, BOB, 100_000_000);
        ONE::ONE::test_route_fee_virtual(&mut reg, 300_000_000);
        let (_, pa, _) = ONE::ONE::sp_of(&reg, ALICE);
        let (_, pb, _) = ONE::ONE::sp_of(&reg, BOB);
        assert!(pa == 150_000_000, 800);
        assert!(pb == 75_000_000, 801);
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    fun test_liquidation_single_depositor() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ONE::ONE::test_create_sp_position(&mut reg, ALICE, 10_000_000_000);
        ONE::ONE::test_simulate_liquidation(&mut reg, 2_000_000_000, 2_500_000_000);
        let (bal, p_one, p_coll) = ONE::ONE::sp_of(&reg, ALICE);
        assert!(bal == 8_000_000_000, 900);
        assert!(p_one == 0, 901);
        assert!(p_coll == 2_500_000_000, 902);
        let (_, total_sp, pf, _, r_coll) = ONE::ONE::totals(&reg);
        assert!(total_sp == 8_000_000_000, 903);
        assert!(pf == 800_000_000_000_000_000, 904);
        assert!(r_coll == 250_000_000_000_000_000, 905);
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    fun test_liquidation_two_depositors_pro_rata() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ONE::ONE::test_create_sp_position(&mut reg, ALICE, 10_000_000_000);
        ONE::ONE::test_create_sp_position(&mut reg, BOB, 10_000_000_000);
        ONE::ONE::test_simulate_liquidation(&mut reg, 2_000_000_000, 2_500_000_000);
        let (a_bal, _, a_coll) = ONE::ONE::sp_of(&reg, ALICE);
        let (b_bal, _, b_coll) = ONE::ONE::sp_of(&reg, BOB);
        assert!(a_bal == 9_000_000_000, 1000);
        assert!(b_bal == 9_000_000_000, 1001);
        assert!(a_coll == 1_250_000_000, 1002);
        assert!(b_coll == 1_250_000_000, 1003);
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    fun test_liquidation_sequential_math() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ONE::ONE::test_create_sp_position(&mut reg, ALICE, 10_000_000_000);
        ONE::ONE::test_simulate_liquidation(&mut reg, 2_000_000_000, 2_500_000_000);
        ONE::ONE::test_create_sp_position(&mut reg, BOB, 10_000_000_000);
        ONE::ONE::test_simulate_liquidation(&mut reg, 1_000_000_000, 1_500_000_000);
        let (a_bal, _, a_coll) = ONE::ONE::sp_of(&reg, ALICE);
        assert!(a_bal == 7_555_555_555, 1100);
        assert!(a_coll == 3_166_666_666, 1101);
        let (b_bal, _, b_coll) = ONE::ONE::sp_of(&reg, BOB);
        assert!(b_bal == 9_444_444_444, 1102);
        assert!(b_coll == 833_333_333, 1103);
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ONE::ONE::E_P_CLIFF)]
    fun test_liquidation_cliff_guard_aborts() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ONE::ONE::test_create_sp_position(&mut reg, ALICE, 10_000_000_000);
        ONE::ONE::test_simulate_liquidation(&mut reg, 9_999_999_000, 1_000_000_000);
        ONE::ONE::test_simulate_liquidation(&mut reg, 999, 500);
        ts::return_shared(reg);
        ts::end(sc);
    }

    // R2-C01 regression: zombie SP positions (initial=0) must refresh their
    // snapshots on every sp_settle, preventing a later redeposit from pairing
    // a fresh initial_balance with stale indices (which inflates pending_one).
    #[test]
    fun test_zombie_redeposit_no_phantom_reward() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);

        ONE::ONE::test_set_sp_position(&mut reg, ALICE, 0, 100_000_000_000_000, 500, 500);
        ONE::ONE::test_force_reward_indices(&mut reg, 1_000_000_000_000_000_000, 2_000_000_000_000_000_000);

        ts::next_tx(&mut sc, ALICE);
        ONE::ONE::test_call_sp_settle(&mut reg, ALICE, ts::ctx(&mut sc));

        let (initial, snap_p, snap_i_one, snap_i_coll) = ONE::ONE::test_get_sp_snapshots(&reg, ALICE);
        assert!(initial == 0, 1200);
        assert!(snap_p == 1_000_000_000_000_000_000, 1201);
        assert!(snap_i_one == 1_000_000_000_000_000_000, 1202);
        assert!(snap_i_coll == 2_000_000_000_000_000_000, 1203);
        ts::return_shared(reg);
        ts::end(sc);
    }

    // ---- seal via test helper (no UpgradeCap in unit tests) ----

    #[test]
    fun test_destroy_cap_flips_sealed() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ts::next_tx(&mut sc, DEPLOYER);
        let origin = ONE::ONE::test_mint_origin_cap(ts::ctx(&mut sc));
        let clk = clock::create_for_testing(ts::ctx(&mut sc));
        ONE::ONE::test_seal_without_upgrade_cap(origin, &mut reg, &clk, ts::ctx(&mut sc));
        assert!(ONE::ONE::is_sealed(&reg) == true, 1300);
        clock::destroy_for_testing(clk);
        ts::return_shared(reg);
        ts::end(sc);
    }

    #[test]
    #[expected_failure(abort_code = ONE::ONE::E_SEALED)]
    fun test_destroy_cap_double_call_aborts() {
        let mut sc = start();
        let mut reg = take_reg(&mut sc);
        ts::next_tx(&mut sc, DEPLOYER);
        let origin_a = ONE::ONE::test_mint_origin_cap(ts::ctx(&mut sc));
        let clk = clock::create_for_testing(ts::ctx(&mut sc));
        ONE::ONE::test_seal_without_upgrade_cap(origin_a, &mut reg, &clk, ts::ctx(&mut sc));
        let origin_b = ONE::ONE::test_mint_origin_cap(ts::ctx(&mut sc));
        ONE::ONE::test_seal_without_upgrade_cap(origin_b, &mut reg, &clk, ts::ctx(&mut sc));
        clock::destroy_for_testing(clk);
        ts::return_shared(reg);
        ts::end(sc);
    }

    // ---- helpers ----

    fun contains_bytes(hay: &vector<u8>, needle: &vector<u8>): bool {
        let hn = std::vector::length(hay);
        let nn = std::vector::length(needle);
        if (nn == 0 || nn > hn) return nn == 0;
        let mut i = 0;
        while (i + nn <= hn) {
            let mut j = 0;
            let mut ok = true;
            while (j < nn) {
                if (*std::vector::borrow(hay, i + j) != *std::vector::borrow(needle, j)) {
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
