require('dotenv').config();
const fs = require('fs');
const path = require('path');

const addresses = [
  "0x62ee80f068dce30ea4a275e91bb733fb17fd0ac0",
  "0xede8ec3dbb11055a736612e174ab7b0b41028ac0",
  "0x83863f772f93e2a209dab0af924ca3d6764a40c4",
  "0x0000fe59823933ac763611a69c88f91d45f81888",
  "0x0010d0d5db05933fa0d9f7038d365e1541a41888",
  "0x5287e8915445aee78e10190559d8dd21e0e9ea88",
  "0xa6c8d7514785c4314ee05ed566cb41151d43c0c0",
  "0x12b504160222d66c38d916d9fba11b613c51e888",
  "0x99d32f38aa4d1ec911420cba3b52d11cb9f0b0c0"
];

const apiKey = process.env.ETHERSCAN_API_KEY;
const fetch = (...args) => import('node-fetch').then(({default: fetch}) => fetch(...args));

// Sleep function: ms milliseconds
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

(async () => {
  for (const address of addresses) {
    const url = `https://api.etherscan.io/api?module=contract&action=getsourcecode&address=${address}&apikey=${apiKey}`;
    const res = await fetch(url);
    const data = await res.json();
    let source = data.result && data.result[0] && data.result[0].SourceCode
      ? data.result[0].SourceCode
      : '';

    // Skip unverified contracts
    if (!source || source.trim() === "") {
      console.log(`Contract at ${address} is not verified. Skipping.`);
      continue;
    }

    // Remove extra wrapping if present (Etherscan sometimes wraps JSON in extra braces)
    if (source.startsWith('{{') && source.endsWith('}}')) {
      source = source.slice(1, -1);
    }

    let parsed = null;
    try {
      parsed = JSON.parse(source);
    } catch {
      // Sometimes SourceCode is a stringified JSON inside another string
      try {
        parsed = JSON.parse(JSON.parse(source));
      } catch {
        parsed = null;
      }
    }

    const folder = path.join(__dirname, address);
    fs.mkdirSync(folder, { recursive: true });

    // Save the raw JSON response
    fs.writeFileSync(path.join(folder, 'raw.json'), JSON.stringify(data, null, 2));

    // Check if contract is a proxy using the Etherscan API field
    const isProxy = data.result && data.result[0] && data.result[0].Proxy === "1";

    if (parsed && parsed.sources && typeof parsed.sources === 'object') {
      // Multi-file: write each file in the folder
      for (const [filePath, fileObj] of Object.entries(parsed.sources)) {
        const outPath = path.join(folder, filePath);
        fs.mkdirSync(path.dirname(outPath), { recursive: true });
        fs.writeFileSync(outPath, fileObj.content);
      }
      console.log(`Wrote multi-file contract for ${address}`);
    } else {
      // Single file: use ContractName.sol from API if available
      const contractName = data.result && data.result[0] && data.result[0].ContractName
        ? data.result[0].ContractName
        : 'Contract';
      const outPath = path.join(folder, `${contractName}.sol`);
      fs.writeFileSync(outPath, source);
      console.log(`Wrote single-file contract for ${address} as ${contractName}.sol`);
    }

    // If proxy, fetch logic contract using the Implementation field
    if (isProxy) {
      const implAddress = data.result[0].Implementation;
      if (implAddress && implAddress !== address) {
        console.log(`Proxy detected at ${address}, implementation at ${implAddress}`);
        // Fetch and save implementation contract source in a subfolder
        const implUrl = `https://api.etherscan.io/api?module=contract&action=getsourcecode&address=${implAddress}&apikey=${apiKey}`;
        const implRes = await fetch(implUrl);
        const implData = await implRes.json();
        let implSource = implData.result && implData.result[0] && implData.result[0].SourceCode
          ? implData.result[0].SourceCode
          : '';
        if (implSource && implSource.trim() !== "") {
          if (implSource.startsWith('{{') && implSource.endsWith('}}')) {
            implSource = implSource.slice(1, -1);
          }
          let implParsed = null;
          try {
            implParsed = JSON.parse(implSource);
          } catch {
            try {
              implParsed = JSON.parse(JSON.parse(implSource));
            } catch {
              implParsed = null;
            }
          }
          const implFolder = path.join(folder, 'implementation');
          fs.mkdirSync(implFolder, { recursive: true });
          fs.writeFileSync(path.join(implFolder, 'raw.json'), JSON.stringify(implData, null, 2));
          const implContractName = implData.result && implData.result[0] && implData.result[0].ContractName
            ? implData.result[0].ContractName
            : 'Implementation';
          if (implParsed && implParsed.sources && typeof implParsed.sources === 'object') {
            for (const [filePath, fileObj] of Object.entries(implParsed.sources)) {
              const outPath = path.join(implFolder, filePath);
              fs.mkdirSync(path.dirname(outPath), { recursive: true });
              fs.writeFileSync(outPath, fileObj.content);
            }
            console.log(`Wrote multi-file implementation contract for ${implAddress}`);
          } else {
            const outPath = path.join(implFolder, `${implContractName}.sol`);
            fs.writeFileSync(outPath, implSource);
            console.log(`Wrote single-file implementation contract for ${implAddress} as ${implContractName}.sol`);
          }
        } else {
          console.log(`Implementation contract at ${implAddress} is not verified or not found.`);
        }
      } else {
        console.log(`Proxy detected at ${address}, but could not find implementation address.`);
      }
    }

    // Wait 200ms before next request (5 requests per second)
    await sleep(200);
  }
})();