This repo is used to download V4 hook contracts. 

Step 1) Query UniswapV4's Subgraph at https://thegraph.com/explorer/subgraphs/DiYPVdygkfjDWhbxGSqAQxwBKmfKnkWQojqeM2rkLb3G?view=Query to retrieve all the addresses that satisfy certain conditions. 

In this example, I used the following query to retrieve pools with non-zero hook address that have total transaction count of greater than 100. 

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

2) Retrieve the non duplicative hook address from the query return and feed them into fetch.js. Save your Etherscan API to .env

3) Install dependencies and run `node fetch.js` to save all hook addresses

Note: 
1) The script skips unverified contract addresses
2) For proxy contracts, save both the proxy and implementation contracts
3) Due to the rate limit of 5 calls per second from Etherscan API endpoint, the script makes no more than 5 calls per second