module Staking::error {
    friend Staking::staking;
    friend Staking::utils;

    public(friend) fun error_unauth_caller(): u64 {
        0
    }

    public(friend) fun error_invalid_starting_timestamp(): u64 {
        1
    }

    public(friend) fun error_invalid_interest_rate(): u64 {
        2
    }

    public(friend) fun error_invalid_amount(): u64 {
        3
    }

    public(friend) fun error_invalid_minimum_staking_period(): u64 {
        4
    }

    public(friend) fun error_account_does_not_match(): u64 {
        5
    }

    public(friend) fun error_invalid_user_staking_account(): u64 {
        6
    }

    public(friend) fun error_invalid_staking_data_account(): u64 {
        7
    }

    public(friend) fun error_invalid_staking_data_map_account(): u64 {
        8
    }

    public(friend) fun error_stake_less_than_minimum_staking_amount(): u64 {
        9
    }

    public(friend) fun error_insufficient_funds(): u64 {
        10
    }

    public(friend) fun error_unstake_funds_error(): u64 {
        11
    }

    public(friend) fun error_accrued_interest_required(): u64 {
        12
    }

    public(friend) fun error_low_stake_amount(): u64 {
        13
    }

    public(friend) fun error_invalid_lock_params(): u64 {
        14
    }

    public(friend) fun error_minimum_period_for_unstake_is_not_passed(): u64 {
        15
    }

    public(friend) fun invalid_coin_type(): u64 {
        16
    }

    public(friend) fun error_minimum_staking_period_too_short(): u64 {
        17
    }

    public(friend) fun error_minimum_staking_period_too_long(): u64 {
        18
    }
}