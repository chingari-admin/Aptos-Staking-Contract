module Staking::limits {
    friend Staking::staking;
    friend Staking::utils;

    use aptos_std::math64;

    /// Constants
    public(friend) fun get_staking_owner(): address {
        @staking_owner
    }
    public(friend) fun get_coin_address(): address {
        @coin_address
    }

    /// Logic
    public(friend) fun get_seconds_per_day(): u64 {
        24 * 60 * 60
    }
    public(friend) fun get_seconds_per_hour(): u64 {
        3600
    }
    public(friend) fun get_max_interest_rate_period_hours(): u64 {
        14 * 24
    }
    public(friend) fun get_interest_mul_factor(): u64 {
        100_000_000
    }
    public(friend) fun get_max_hours_interest_accrue(): u64 {
        15
    }
    public(friend) fun get_shares_mul_factor(): u64 {
        1_000_000
    }

    // (24 * 60 * 60) is SECONDS_PER_DAY; but `Other constants are not supported in constants` so writing the mathematical expr
    public(friend) fun get_max_staking_start_period(): u64 {
        (24 * 60 * 60) * 100
    }
    public(friend) fun get_max_staking_amount_limit(): u64 {
        1_000
    }
    public(friend) fun get_min_staking_period(): u64 {
        24 * 60 * 60
    }
    public(friend) fun get_max_staking_period(): u64 {
        (24 * 60 * 60) * 30
    }

    public(friend) fun get_decimal_point(): u64 {
        math64::pow(10_u64, 9_u64)
    }

    public(friend) fun max_hours(): u64 {
        100
    }

    public(friend) fun minimum_funding_amount(): u64 {
        100
    }
}