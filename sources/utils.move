module Staking::utils {
    friend Staking::staking;

    use std::error as std_error;

    use Staking::limits::{
        get_seconds_per_hour,
        get_max_interest_rate_period_hours,
    };
    use Staking::error;
    use Staking::u512;
    use U256::u256;
    use aptos_std::math64;
    use aptos_std::type_info;

    const INTEREST_MUL_FACTOR: u64 = 100_000_000;
    const MAX_HOURS_INTEREST_ACCRUE: u64 = 15;
    const SHARES_MUL_FACTOR: u64 = 1_000_000;

    public(friend) fun calculate_proportion(old_balance: u64, mul_factor: u64, div_factor: u64): u64 {
        ((old_balance * mul_factor) / div_factor)
    }

    public(friend) fun calculate_amount(total_shares: u128, total_staked: u64, ownership_share: u128): u64 {
        if (total_shares == 0) {
            return 0
        };

        let total_shares_bn = u256::from_u128(total_shares);
        let ownership_share_bn = u256::from_u128(ownership_share);
        let total_staked_bn = u256::from_u64(total_staked);
        let total_staked_mul_amount = u256::mul(total_staked_bn, ownership_share_bn);

        let div_result = u256::div(total_staked_mul_amount, total_shares_bn);

        u256::as_u64(div_result)
    }

    public(friend) fun calculate_new_shares(total_shares: u128, total_staked: u64, amount: u64): u128 {
        if (total_shares == 0) {
            return ((amount * SHARES_MUL_FACTOR) as u128)
        };

        let total_shares_bn = u256::from_u128(total_shares);
        let amount_bn = u256::from_u64(amount);
        let total_shares_mul_amount = u256::mul(total_shares_bn, amount_bn);
        let total_staked_bn = u256::from_u64(total_staked);

        assert!((u256::compare(&total_shares_mul_amount, &total_staked_bn) == 2), std_error::aborted(error::error_low_stake_amount()));

        let div_result = u256::div(total_shares_mul_amount, total_staked_bn);

        u256::as_u128(div_result)
    }

    public(friend) fun calculate_shares_to_burn(total_shares: u128, total_staked: u64, amount: u64): u128 {
        let total_shares_bn = u256::from_u128(total_shares);
        let total_staked_bn = u256::from_u64(total_staked);
        let amount_bn = u256::from_u64(amount);

        let result = u256::div(u256::mul(total_shares_bn, amount_bn), total_staked_bn);

        u256::as_u128(result)
    }

    public(friend) fun calculate_accrued_interest(
        last_interest_accrued_timestamp: u64,
        current_timestamp: u64,
        total_staked: u64,
        interest_rate: u64,
        max_hours: u64,
    ): (u64, u64) {
        let last_interest_accrued_timestamp_copy = last_interest_accrued_timestamp;
        let timestamp = &mut last_interest_accrued_timestamp_copy;
        let interest = &mut 0;

        let timestamp_diff = current_timestamp - last_interest_accrued_timestamp;

        if (timestamp_diff >= get_seconds_per_hour()) {
            let hours_elapsed = &mut (timestamp_diff / get_seconds_per_hour());

            if (max_hours > 0) {
                *hours_elapsed = math64::min(*hours_elapsed, max_hours);
            };

            assert!((*hours_elapsed < get_max_interest_rate_period_hours()), std_error::unavailable(error::error_accrued_interest_required()));

            let new_balance = &mut u512::from_u64(total_staked);
            let interest_mul_factor = u512::from_u64(INTEREST_MUL_FACTOR);

            let hourly_rate = u512::from_u64(INTEREST_MUL_FACTOR + interest_rate);

            let hours_remain = &mut *hours_elapsed;
            let hourly_rate_pow_max = u512::pow(hourly_rate, MAX_HOURS_INTEREST_ACCRUE);
            let interest_mul_factor_pow_max = u512::pow(interest_mul_factor, MAX_HOURS_INTEREST_ACCRUE);

            while (*hours_remain > 0) {
                if (*hours_remain < MAX_HOURS_INTEREST_ACCRUE) {
                    *new_balance = u512::div(
                        u512::mul(
                            *new_balance, 
                            u512::pow(
                                hourly_rate, 
                                *hours_remain
                            )
                        ), 
                        u512::pow(
                            interest_mul_factor, 
                            *hours_remain
                        )
                    );

                    *hours_remain = 0;
                } else {
                    *new_balance = u512::div(u512::mul(*new_balance, hourly_rate_pow_max), interest_mul_factor_pow_max);
                    *hours_remain = *hours_remain - MAX_HOURS_INTEREST_ACCRUE;
                };
            };

            *interest = u512::as_u64(*new_balance) - total_staked;
            *timestamp = (last_interest_accrued_timestamp + (get_seconds_per_hour() * *hours_elapsed));
        };

        (*interest, *timestamp)
    }

    public(friend) fun accrue_interest_internal(
        staking_data_last_interest_accrued_timestamp: &mut u64,
        staking_data_total_staked: &mut u64,
        staking_data_interest_rate_hourly: u64,
        staking_data_is_interest_accrual_paused: &mut bool,
        holding_wallet_balance: u64,
        current_timestamp: u64,
        max_hours: u64,
    ) {
        let (accrued_interest, new_timestamp) = calculate_accrued_interest(
            *staking_data_last_interest_accrued_timestamp,
            current_timestamp,
            *staking_data_total_staked,
            staking_data_interest_rate_hourly,
            max_hours
        );

        let new_total_staked = *staking_data_total_staked + accrued_interest;
        
        if (holding_wallet_balance < new_total_staked) {
            *staking_data_last_interest_accrued_timestamp = new_timestamp;
            *staking_data_is_interest_accrual_paused = true;

            return
        };

        if (accrued_interest > 0) {
            *staking_data_last_interest_accrued_timestamp = new_timestamp;
            *staking_data_total_staked = new_total_staked;
        }
    }

    public(friend) fun update_shares_on_unstake(
        total_staked: u64,
        total_shares: &mut u128,
        ownership_share: &mut u128,
        amount_expected: u64,
    ): (u128, u128) {
        if (amount_expected == 0) {
            *total_shares = *total_shares - *ownership_share;
            *ownership_share = 0;
            return (*total_shares, *ownership_share)
        };

        let amount_after = calculate_amount(*total_shares, total_staked, *ownership_share);

        if (amount_after > amount_expected) {
            let user_ownership_share = calculate_shares_to_burn(*total_shares, total_staked, amount_after);
            *total_shares = (*total_shares - *ownership_share + user_ownership_share);
            *ownership_share = user_ownership_share;
        };

        (*total_shares, *ownership_share)
    }

    public(friend) fun add_amount(staked_amount: &mut u64, ownership_share: u128, total_shares: u128, total_staked: u64, amount: u64): u64 {
        *staked_amount = *staked_amount + amount;
        let user_amount_after = calculate_amount(
                total_shares,
                total_staked,
                ownership_share,
            );
        if (*staked_amount < user_amount_after) {
            *staked_amount = user_amount_after;
        };

        *staked_amount
    }

    public(friend ) fun calculate_balance(staked_amount: u64, total_shares: u128, total_staked: u64, ownership_share: u128): u64 {
        let balance = &mut calculate_amount(
            total_shares,
            total_staked,
            ownership_share,
        );

        if (*balance < staked_amount) {
            *balance = staked_amount;
        };

        *balance
    }

    public(friend) fun saturating_sub(a: u64, b: u64): u64 {
        if (a < b) {
            0u64
        } else {
            a - b
        }
    }

     /// A helper function that returns the address of CoinType.
    public(friend) fun coin_address<CoinType>(): address {
        let type_info = type_info::type_of<CoinType>();
        type_info::account_address(&type_info)
    }
}