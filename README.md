# V4 Hook Contracts Downloader

This repo is used to download Uniswap V4 hook contracts.

## Step 1: Query Uniswap V4 Subgraph

Query the Uniswap V4 Subgraph at [The Graph Explorer](https://thegraph.com/explorer/subgraphs/DiYPVdygkfjDWhbxGSqAQxwBKmfKnkWQojqeM2rkLb3G?view=Query) to retrieve all the addresses that satisfy certain conditions.

**Example Query:**  
This query retrieves pools with a non-zero hook address and a total transaction count greater than 100.

```graphql
query Hooks {
  pools(
    where: {hooks_not: "0x0000000000000000000000000000000000000000", txCount_gt: "100"}
  ) {
    createdAtTimestamp
    hooks
    id
    token0 {
      id
      name
      symbol
    }
    token1 {
      id
      name
      symbol
    }
    txCount
  }
}
```

## Step 2: Prepare Hook Addresses

- Retrieve the unique hook addresses from the query result.
- Add them to the `addresses` array in `fetch.js`.
- Save your Etherscan API key in a `.env` file as `ETHERSCAN_API_KEY`.

## Step 3: Install Dependencies and Run

```bash
pnpm install
node fetch.js
```

This will save all hook contract sources.

---

## Notes

- The script **skips unverified contract addresses**.
- For **proxy contracts**, both the proxy and implementation contracts are saved.
- Due to the Etherscan API rate limit (5 calls per second), the script throttles requests accordingly.

---