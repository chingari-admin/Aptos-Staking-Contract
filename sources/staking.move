module Staking::staking {
    use Staking::error::{
        error_unauth_caller, 
        error_invalid_starting_timestamp, 
        error_invalid_interest_rate, 
        error_invalid_amount, 
        error_invalid_minimum_staking_period, 
        error_account_does_not_match, 
        error_invalid_user_staking_account, 
        error_invalid_staking_data_account,
        error_stake_less_than_minimum_staking_amount, 
        error_insufficient_funds, 
        error_unstake_funds_error, 
        error_invalid_lock_params,
        error_minimum_period_for_unstake_is_not_passed,
        invalid_coin_type,
        error_minimum_staking_period_too_short,
        error_minimum_staking_period_too_long,
    };
    use Staking::limits::{
        get_decimal_point,
        get_staking_owner,
        get_coin_address,
        get_seconds_per_day,
        get_seconds_per_hour,
        get_max_interest_rate_period_hours,
        get_max_staking_start_period,
        get_max_staking_amount_limit,
        get_min_staking_period,
        get_max_staking_period,
        max_hours,
        minimum_funding_amount,
    };
    use Staking::utils::{
        accrue_interest_internal,
        add_amount,
        calculate_new_shares,
        calculate_shares_to_burn,
        calculate_balance,
        saturating_sub,
        update_shares_on_unstake,
        coin_address,
    };

    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_framework::coin;
    use aptos_framework:: managed_coin;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_std::simple_map::{Self, SimpleMap};
    use std::error;
    use std::signer;
    use std::string::{Self, String};

    struct InitializeStakingDataEvent has drop, store {
        staking_data_account: address,
        interest_rate_hourly: u64,
        max_interest_rate_hourly: u64,
        last_interest_accrued_timestamp: u64,
        minimum_staking_amount: u64,
        minimum_staking_period_sec: u64,
        is_interest_accrual_paused: bool,
    }

    struct SetInterestRateEvent has drop, store {
        staking_data_account: address,
        new_interest_rate: u64
    }

    struct UpdateLockPeriodEvent has drop, store {
        staking_data_account: address,
        minimum_staking_period_sec: u64
    }

    struct SetMinimumStakingAmountEvent has drop, store {
        staking_data_account: address,
        new_minimum_staking_amount: u64
    }

    struct AccrueInterestEvent has drop, store {
        staking_data_account: address,
    }

    struct FundStakingEvent has drop, store {
        staking_data_account: address,
        amount: u64,
    }

    struct InitializeStakingUserData has drop, store {
        staking_data_account: address,
    }

    struct StakeEvent has drop, store {
        amount: u64,
    }

    struct UnstakeEvent has drop, store {
        amount: u64,
    }

    struct LockAmountEvent has drop, store {
        amount: u64,
    }

    struct StakingData has store, key {
        /// Staking pool owner
        owner: address,
        /// Staking token
        staking_token: address,
        /// Wallet for storing staking token
        holding_wallet: address,
        /// Signer
        resource_cap: account::SignerCapability,
        total_staked: u64,
        total_shares: u128,
        /// Hourly interest rate in 1e-8 (1/10000 of a basis point)
        interest_rate_hourly: u64,
        max_interest_rate_hourly: u64,
        last_interest_accrued_timestamp: u64,
        minimum_staking_amount: u64,
        minimum_staking_period_sec: u64,
        is_interest_accrual_paused: bool,
    }

    struct StakingDataMap has key {
        staking_data: SimpleMap<vector<u8>, address>,
        initialize_staking_data_events: EventHandle<InitializeStakingDataEvent>,
        set_interest_rate_events: EventHandle<SetInterestRateEvent>,
        update_lock_period_events: EventHandle<UpdateLockPeriodEvent>,
        set_minimum_staking_amount_events: EventHandle<SetMinimumStakingAmountEvent>,
        accrue_interest_events: EventHandle<AccrueInterestEvent>,
        fund_staking_events: EventHandle<FundStakingEvent>,
    }

    struct StakingUserData has key {
        /// User wallet for holding staking token
        user_token_wallet: address,
        /// Link to staking pool
        staking_data: address,
        ownership_share: u128,
        staked_amount: u64,
        /// Amount of shares locked for the governance proposal vote
        locked_amount: u64,
        locked_until: u64,
        last_staking_timestamp: u64,
    }

    struct StakingUserDataEvent has key {
        initialize_events: EventHandle<InitializeStakingUserData>,
        stake_events: EventHandle<StakeEvent>,
        unstake_events: EventHandle<UnstakeEvent>,
        lock_amount_events: EventHandle<LockAmountEvent>,
    }

    public entry fun initialize_staking<CoinType>(
        account: &signer,
        starting_timestamp: u64,
        max_interest_rate: u64,
        starting_interest_rate: u64,
        seeds: vector<u8>,
        minimum_staking_amount: u64,
        minimum_staking_period_sec: u64,
        _memo: String,
    ) acquires StakingDataMap {
        // Signer Authorization check
        let account_addr = signer::address_of(account);
        assert!(account_addr == get_staking_owner(), error::unauthenticated(error_unauth_caller()));
        assert!(coin_address<CoinType>() == get_coin_address(), error::invalid_argument(invalid_coin_type()));

        let current_timestamp = timestamp::now_seconds();

        assert!((starting_timestamp > (current_timestamp - get_seconds_per_day())), error::invalid_argument(error_invalid_starting_timestamp()));

        let max_starting_timestamp = current_timestamp + get_max_staking_start_period();

        assert!((starting_timestamp < max_starting_timestamp), error::invalid_argument(error_invalid_starting_timestamp()));

        assert!((max_interest_rate > 0), error::invalid_argument(error_invalid_interest_rate()));

        // assert!((starting_interest_rate > 0), error::invalid_argument(error_invalid_interest_rate()));

        assert!((starting_interest_rate < max_interest_rate), error::invalid_argument(error_invalid_interest_rate()));

        let decimal_point = get_decimal_point();
        let max_staking_amount_limit = get_max_staking_amount_limit() * decimal_point;

        assert!((minimum_staking_amount > 0 && minimum_staking_amount < max_staking_amount_limit), error::invalid_argument(error_invalid_amount()));

        assert!((minimum_staking_period_sec > get_min_staking_period() && minimum_staking_period_sec < get_max_staking_period()), error::invalid_argument(error_invalid_minimum_staking_period()));

        // resource account
        let (staking, staking_cap) = account::create_resource_account(account, seeds);
        let staking_address = signer::address_of(&staking);

        if (!exists<StakingDataMap>(account_addr)) {
            move_to(account, StakingDataMap {
                staking_data: simple_map::create(), 
                initialize_staking_data_events: account::new_event_handle<InitializeStakingDataEvent>(account),
                set_interest_rate_events: account::new_event_handle<SetInterestRateEvent>(account),
                update_lock_period_events: account::new_event_handle<UpdateLockPeriodEvent>(account),
                set_minimum_staking_amount_events: account::new_event_handle<SetMinimumStakingAmountEvent>(account),
                accrue_interest_events: account::new_event_handle<AccrueInterestEvent>(account),
                fund_staking_events: account::new_event_handle<FundStakingEvent>(account),
            })
        };

        let maps = borrow_global_mut<StakingDataMap>(account_addr);
        simple_map::add(&mut maps.staking_data, seeds, staking_address);
        let staking_signer_from_cap = account::create_signer_with_capability(&staking_cap);

        // Register the coin in the resource account
        managed_coin::register<CoinType>(&staking_signer_from_cap);

        move_to(&staking_signer_from_cap, StakingData {
            owner: account_addr,
            staking_token: get_coin_address(),
            holding_wallet: staking_address,
            resource_cap: staking_cap,
            total_staked: 0,
            total_shares: 0,
            interest_rate_hourly: starting_interest_rate,
            max_interest_rate_hourly: max_interest_rate,
            last_interest_accrued_timestamp: starting_timestamp,
            minimum_staking_amount,
            minimum_staking_period_sec,
            is_interest_accrual_paused: false
        });

        event::emit_event<InitializeStakingDataEvent>(
            &mut maps.initialize_staking_data_events,
            InitializeStakingDataEvent {
                staking_data_account: staking_address,
                interest_rate_hourly: starting_interest_rate,
                max_interest_rate_hourly: max_interest_rate,
                last_interest_accrued_timestamp: starting_timestamp,
                minimum_staking_amount,
                minimum_staking_period_sec,
                is_interest_accrual_paused: false,
            },
        );
    }

    public entry fun initialize_staking_user(
        user: &signer,
        staking_data_acc: address,
        _memo: String,
    ) acquires StakingUserDataEvent {
        let user_account_addr = signer::address_of(user);

        // let maps = borrow_global<StakingDataMap>(owner);
        // let staking_data_account = simple_map::borrow(&maps.staking_data, &staking_data_seeds);
        assert!(exists<StakingData>(staking_data_acc), error::not_found(error_account_does_not_match()));

        if (!exists<StakingUserData>(user_account_addr)) {
            move_to(user, StakingUserData {
                user_token_wallet: user_account_addr,
                staking_data: staking_data_acc,
                ownership_share: 0,
                staked_amount: 0,
                locked_amount: 0,
                locked_until: 0,
                last_staking_timestamp: 0,
            })
        };

        if (!exists<StakingUserDataEvent>(user_account_addr)) {
            move_to(user, StakingUserDataEvent {
                initialize_events: account::new_event_handle<InitializeStakingUserData>(user),
                stake_events: account::new_event_handle<StakeEvent>(user),
                unstake_events: account::new_event_handle<UnstakeEvent>(user),
                lock_amount_events: account::new_event_handle<LockAmountEvent>(user),
            })
        };

        let staking_user_data_events = borrow_global_mut<StakingUserDataEvent>(user_account_addr);

        event::emit_event<InitializeStakingUserData>(
            &mut staking_user_data_events.initialize_events,
            InitializeStakingUserData {
                staking_data_account: staking_data_acc,
            },
        );
    }

    public entry fun set_interest_rate(
        account: &signer,
        staking_data_acc: address,
        new_interest_rate: u64,
        _memo: String,
    ) acquires StakingDataMap, StakingData {
        // Signer Authorization check
        let account_addr = signer::address_of(account);
        assert!(account_addr == get_staking_owner(), error::unauthenticated(error_unauth_caller()));

        let maps = borrow_global_mut<StakingDataMap>(account_addr);

        let max_interest_rate_hourly = &mut borrow_global_mut<StakingData>(staking_data_acc).max_interest_rate_hourly;
        assert!((new_interest_rate < *max_interest_rate_hourly), error::invalid_argument(error_invalid_interest_rate()));
        *max_interest_rate_hourly = new_interest_rate;

        event::emit_event<SetInterestRateEvent>(
            &mut maps.set_interest_rate_events,
            SetInterestRateEvent {
                staking_data_account: staking_data_acc,
                new_interest_rate
            }
        );

    }

    public entry fun set_minimum_staking_amount(
        owner: &signer,
        staking_data_acc: address,
        new_minimum_staking_amount: u64,
        _memo: String,
    ) acquires StakingDataMap, StakingData {
        let owner_addr = signer::address_of(owner);

        assert!(owner_addr == get_staking_owner(), error::unauthenticated(error_unauth_caller()));
        
        let maps = borrow_global_mut<StakingDataMap>(owner_addr);

        let decimal_point = get_decimal_point();
        let max_staking_amount_limit = get_max_staking_amount_limit() * decimal_point;

        assert!((new_minimum_staking_amount > 0 && new_minimum_staking_amount < max_staking_amount_limit), error::invalid_argument(error_invalid_amount()));

        let minimum_staking_amount = &mut borrow_global_mut<StakingData>(staking_data_acc).minimum_staking_amount;
        *minimum_staking_amount = new_minimum_staking_amount;

        event::emit_event<SetMinimumStakingAmountEvent>(
            &mut maps.set_minimum_staking_amount_events,
            SetMinimumStakingAmountEvent {
                staking_data_account: staking_data_acc,
                new_minimum_staking_amount
            }
        );
    }

    public entry fun stake<CoinType>(
        user: &signer,
        amount: u64,
        staking_data_acc: address,
        _memo: String,
    ) acquires StakingData, StakingUserData, StakingUserDataEvent {
        assert!(coin_address<CoinType>() == get_coin_address(), error::invalid_argument(invalid_coin_type()));

        let user_account_addr = signer::address_of(user);

        assert!(exists<StakingUserData>(user_account_addr), error::not_found(error_invalid_user_staking_account()));

        assert!(exists<StakingData>(staking_data_acc), error::not_found(error_invalid_staking_data_account()));

        let current_timestamp = timestamp::now_seconds();

        let staking_user_data = borrow_global_mut<StakingUserData>(user_account_addr);

        if (current_timestamp >= staking_user_data.locked_until) {
            staking_user_data.locked_amount = 0;
            staking_user_data.locked_until = 0;
        };

        let staking_data = borrow_global_mut<StakingData>(staking_data_acc);

        let balance = coin::balance<CoinType>(staking_data.holding_wallet);

        accrue_interest_internal(
            &mut staking_data.last_interest_accrued_timestamp,
            &mut staking_data.total_staked,
            staking_data.interest_rate_hourly,
            &mut staking_data.is_interest_accrual_paused,
            balance,
            current_timestamp,
            0,
        );

        assert!((amount >= staking_data.minimum_staking_amount), error::invalid_argument(error_stake_less_than_minimum_staking_amount()));
    
        let user_coin_balance = coin::balance<CoinType>(user_account_addr);

        assert!((user_coin_balance >= amount), error::invalid_argument(error_insufficient_funds()));

        coin::transfer<CoinType>(user, staking_data_acc, amount);

        let new_shares = calculate_new_shares(
            staking_data.total_shares,
            staking_data.total_staked,
            amount,
        );

        staking_data.total_staked = staking_data.total_staked + amount;
        staking_data.total_shares = staking_data.total_shares + new_shares;
        staking_user_data.ownership_share = staking_user_data.ownership_share + new_shares;
        add_amount(&mut staking_user_data.staked_amount, staking_user_data.ownership_share, staking_data.total_shares, staking_data.total_staked, amount);
        staking_user_data.last_staking_timestamp = current_timestamp;

        let staking_user_data_events = borrow_global_mut<StakingUserDataEvent>(user_account_addr);

        event::emit_event<StakeEvent>(
            &mut staking_user_data_events.stake_events,
            StakeEvent { amount },
        );
    }

    public entry fun init_staking_user_and_stake<CoinType>(
        user: &signer,
        amount: u64,
        staking_data_acc: address,
        _memo: String,
    ) acquires StakingData, StakingUserData, StakingUserDataEvent {
        let user_account_addr = signer::address_of(user);
        
        if (exists<StakingUserData>(user_account_addr)) {
            stake<CoinType>(
                user,
                amount,
                staking_data_acc,
                string::utf8(b"Stake"),
            );
        } else {
            initialize_staking_user(
                user,
                staking_data_acc,
                string::utf8(b"InitializeStakingUser"),
            );

            stake<CoinType>(
                user,
                amount,
                staking_data_acc,
                string::utf8(b"Stake"),
            );
        }
    }

    public entry fun unstake<CoinType>(
        user: &signer,
        amount: u64,
        staking_data_acc: address,
        _memo: String,
    ) acquires StakingData, StakingUserData, StakingUserDataEvent {
        assert!(coin_address<CoinType>() == get_coin_address(), error::invalid_argument(invalid_coin_type()));

        let user_account_addr = signer::address_of(user);

        assert!(exists<StakingUserData>(user_account_addr), error::not_found(error_invalid_user_staking_account()));
        assert!(exists<StakingData>(staking_data_acc), error::not_found(error_invalid_staking_data_account()));

        let current_timestamp = timestamp::now_seconds();

        let staking_user_data = borrow_global_mut<StakingUserData>(user_account_addr);
        let staking_data = borrow_global_mut<StakingData>(staking_data_acc);

        if (current_timestamp >= staking_user_data.locked_until) {
            staking_user_data.locked_amount = 0;
            staking_user_data.locked_until = 0;
        };

        assert!((amount > 0), error::invalid_argument(error_invalid_amount()));

        assert!((staking_data.total_staked > 0), error::invalid_argument(error_invalid_amount()));

        // if (staking_data.total_staked == 0) {
        //     abort error::invalid_state(error_unstake_funds_error())
        // };

        let staking_amount_lock_end = staking_user_data.last_staking_timestamp + staking_data.minimum_staking_period_sec;

        assert!((staking_amount_lock_end < current_timestamp), error::permission_denied(error_minimum_period_for_unstake_is_not_passed()));

        let balance = coin::balance<CoinType>(staking_data.holding_wallet);

        accrue_interest_internal(
            &mut staking_data.last_interest_accrued_timestamp,
            &mut staking_data.total_staked,
            staking_data.interest_rate_hourly,
            &mut staking_data.is_interest_accrual_paused,
            balance,
            current_timestamp,
            0,
        );

        let shares_to_burn = &mut calculate_shares_to_burn(
            staking_data.total_shares,
            staking_data.total_staked,
            amount,
        );

        if (*shares_to_burn == 0) {
            abort error::aborted(error_unstake_funds_error())
        };

        let user_current_balance = calculate_balance(staking_user_data.staked_amount, staking_data.total_shares, staking_data.total_staked, staking_user_data.ownership_share);

        let avail_amount = saturating_sub(user_current_balance, staking_user_data.locked_amount);

        assert!((amount <= avail_amount), error::invalid_argument(error_insufficient_funds()));

        if (*shares_to_burn > staking_user_data.ownership_share) {
            *shares_to_burn = staking_user_data.ownership_share
        };

        staking_user_data.staked_amount = user_current_balance- amount;
        staking_user_data.ownership_share = staking_user_data.ownership_share - *shares_to_burn;
        staking_data.total_shares = staking_data.total_shares - *shares_to_burn;
        staking_data.total_staked = staking_data.total_staked - amount;

        let (total_shares, ownership_share) = update_shares_on_unstake(
            staking_data.total_staked,
            &mut staking_data.total_shares,
            &mut staking_user_data.ownership_share,
            staking_user_data.staked_amount,
        );

        staking_data.total_shares = total_shares;
        staking_user_data.ownership_share = ownership_share;

        let staking_signer_from_cap = account::create_signer_with_capability(&staking_data.resource_cap);

        coin::transfer<CoinType>(&staking_signer_from_cap, user_account_addr, amount);

        let staking_user_data_events = borrow_global_mut<StakingUserDataEvent>(user_account_addr);

        event::emit_event<UnstakeEvent>(
            &mut staking_user_data_events.unstake_events,
            UnstakeEvent { amount },
        );
    }

    public entry fun accrue_interest<CoinType>(
        owner: &signer,
        staking_data_acc: address,
        _memo: String,
    ) acquires StakingDataMap, StakingData {
        let timestamp = &mut timestamp::now_seconds();

        let owner_addr = signer::address_of(owner);

        assert!(owner_addr == get_staking_owner(), error::unauthenticated(error_unauth_caller()));

        let maps = borrow_global_mut<StakingDataMap>(owner_addr);

        let staking_data = borrow_global_mut<StakingData>(staking_data_acc);
        
        let timestamp_diff = *timestamp - staking_data.last_interest_accrued_timestamp;

        let max_delay = (get_max_interest_rate_period_hours() * get_seconds_per_hour());

        if (timestamp_diff > max_delay) {
            *timestamp = staking_data.last_interest_accrued_timestamp + max_delay;
        };

        let balance = coin::balance<CoinType>(staking_data.holding_wallet);

        accrue_interest_internal(
            &mut staking_data.last_interest_accrued_timestamp,
            &mut staking_data.total_staked,
            staking_data.interest_rate_hourly,
            &mut staking_data.is_interest_accrual_paused,
            balance,
            *timestamp,
            max_hours()
        );

        event::emit_event<AccrueInterestEvent>(
            &mut maps.accrue_interest_events,
            AccrueInterestEvent {
                staking_data_account: staking_data_acc,
            }
        )
    }

    public entry fun lock_amount(user: &signer, until: u64, amount: u64, _memo: String) acquires StakingUserData, StakingUserDataEvent {
        let user_account_addr = signer::address_of(user);
        assert!(exists<StakingUserData>(user_account_addr), error::not_found(error_invalid_user_staking_account()));
        let staking_user_data = borrow_global_mut<StakingUserData>(user_account_addr);

        assert!(staking_user_data.staked_amount >= amount, error::invalid_argument(error_insufficient_funds()));
        assert!((until > staking_user_data.locked_until), error::invalid_argument(error_invalid_lock_params()));

        if (amount < staking_user_data.locked_amount) {
            return
        };

        staking_user_data.locked_amount = amount;
        staking_user_data.locked_until = until;

        let staking_user_data_events = borrow_global_mut<StakingUserDataEvent>(user_account_addr);

        event::emit_event<LockAmountEvent>(
            &mut staking_user_data_events.lock_amount_events,
            LockAmountEvent {
                amount
            }
        );
    }

    public entry fun fund_staking<CoinType>(
        funder: &signer,
        owner: address,
        staking_data_acc: address,
        amount: u64,
        _memo: String,
    ) acquires StakingDataMap, StakingData {
        assert!(owner == get_staking_owner(), error::unauthenticated(error_unauth_caller()));
        assert!(coin_address<CoinType>() == get_coin_address(), error::invalid_argument(invalid_coin_type()));
        assert!((amount > 0), error::invalid_argument(error_invalid_amount()));

        let maps = borrow_global_mut<StakingDataMap>(owner);

        let staking_data = borrow_global_mut<StakingData>(staking_data_acc);

        let holding_wallet_balance = coin::balance<CoinType>(staking_data.holding_wallet);
        let new_holding_wallet_balance = holding_wallet_balance + amount;

        coin::transfer<CoinType>(funder, staking_data.holding_wallet, amount);


        let current_timestamp = timestamp::now_seconds();
        let timestamp_diff = current_timestamp - staking_data.last_interest_accrued_timestamp;

        if (
            staking_data.is_interest_accrual_paused 
            && staking_data.total_staked < new_holding_wallet_balance
            && amount >= minimum_funding_amount()
        ) {
            staking_data.is_interest_accrual_paused = false;

            if (timestamp_diff >= get_seconds_per_day()) {
                staking_data.last_interest_accrued_timestamp = current_timestamp;
            };
        };

        event::emit_event<FundStakingEvent>(
            &mut maps.fund_staking_events,
            FundStakingEvent {
                staking_data_account: staking_data_acc,
                amount
            }
        );
    }

    public entry fun update_lock_period(
        owner: &signer,
        staking_data_acc: address,
        minimum_staking_period_sec: u64,
        _memo: String,
    ) acquires StakingDataMap, StakingData {
        let owner_addr = signer::address_of(owner);

        assert!(owner_addr == get_staking_owner(), error::unauthenticated(error_unauth_caller()));

        let maps = borrow_global_mut<StakingDataMap>(owner_addr);

        assert!(
            minimum_staking_period_sec > get_min_staking_period(),
            error::invalid_argument(error_minimum_staking_period_too_short())
        );
        assert!(
            minimum_staking_period_sec < get_max_staking_period(),
            error::invalid_argument(error_minimum_staking_period_too_long())
        );

        let lock_period = &mut borrow_global_mut<StakingData>(staking_data_acc).minimum_staking_period_sec;
        *lock_period = minimum_staking_period_sec;

        event::emit_event<UpdateLockPeriodEvent>(
            &mut maps.update_lock_period_events,
            UpdateLockPeriodEvent {
                staking_data_account: staking_data_acc,
                minimum_staking_period_sec
            }
        );
    }  
}