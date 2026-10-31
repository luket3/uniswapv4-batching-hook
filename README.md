# Uniswap v4 Batching Hook

A Uniswap v4 `beforeSwap` hook that queues swaps and settles them together as a batch via `clearBatch`.

## Setup

Install [Foundry](https://book.getfoundry.sh/getting-started/installation), then make sure it is on your `PATH`:

```bash
echo 'export PATH="$PATH:$HOME/.foundry/bin"' >> ~/.bashrc
source ~/.bashrc
```

Clone with submodules and build:

```bash
git clone --recurse-submodules https://github.com/luket3/uniswapv4-batching-hook.git
cd uniswapv4-batching-hook
forge build
```

If you already cloned without submodules, run `git submodule update --init --recursive`.

## Running the tests

### Unit tests (local, no RPC needed)

```bash
forge test --match-path test/BatchingHook.t.sol
```

### Fork tests

The fork tests deploy the hook against the live Uniswap v4 contracts. They need an RPC URL and are skipped automatically if it is not set.

Create a `.env` file in the project root (it's already git-ignored). Forge loads it automatically:

```bash
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/<your-key>
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/<your-key>
```

Then run:

```bash
# Ethereum mainnet fork
forge test --match-path test/BatchingHookFork.t.sol

# Base fork
forge test --match-path test/BatchingHookBaseFork.t.sol
```

`https://mainnet.base.org` also works for the Base fork, but it is rate-limited.

### Everything

```bash
forge test
```

Add `-vvvv` to any command to see full traces.
