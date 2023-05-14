import 'dotenv/config'
import { HardhatUserConfig } from 'hardhat/config'
import '@nomiclabs/hardhat-etherscan'
import '@nomiclabs/hardhat-waffle'
import '@nomiclabs/hardhat-ethers'
import '@typechain/hardhat'
import 'hardhat-gas-reporter'
import 'hardhat-abi-exporter'
import 'hardhat-deploy'
import 'solidity-coverage'
import '@atixlabs/hardhat-time-n-mine'
import 'hardhat-contract-sizer'

const hardhatUserconfig: HardhatUserConfig = {
  solidity: {
    version: '0.8.17',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  namedAccounts: {
    deployer: 0,
    owner: 1
  },
  defaultNetwork: 'hardhat',
  networks: {
    hardhat: {
      accounts: {
        count: 10,
        accountsBalance: '1000000000000000000000000'
      },
      mining: {
        auto: true
      },
      saveDeployments: false
    },
    local: {
      url: process.env.LOCAL_URL || 'http://localhost:8545',
      accounts: {
        mnemonic: process.env.LOCAL_MNEMONIC,
        path: "m/44'/60'/0'/0",
        initialIndex: 0,
        count: 10,
        passphrase: ''
      },
      live: false,
      saveDeployments: false
    },
    testnet: {
      url: process.env.TESTNET_URL,
      accounts: { mnemonic: process.env.TEST_MNEMONIC },
      chainId: 1666700000,
      live: true,
      gasMultiplier: 2,
      saveDeployments: false
    },
    mainnet: {
      url: process.env.MAINNET_URL,
      accounts: { mnemonic: process.env.MNEMONIC },
      chainId: 1666600000,
      live: true,
      gasPrice: 100e+9,
      gasMultiplier: 2,
      gas: 10e+6
    },
    s1: {
      url: process.env.S1_URL,
      accounts: { mnemonic: process.env.MNEMONIC },
      chainId: 1666600001,
      live: true,
      gasPrice: 100e+9,
      gasMultiplier: 2,
      gas: 10e+6
    }
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: 'USD'
  },
  paths: {
    sources: './contracts',
    tests: './test',
    cache: './cache',
    artifacts: './build'
  },
  mocha: {
    timeout: 60000
  },
  abiExporter: {
    path: './abi',
    runOnCompile: true,
    clear: true,
    flat: true,
    only: [
      'ReverseRegistrar',
      'LengthBasedPriceOracle',
      'SimpleAssetPriceOracle',
      'RegistrarController',
      'TLDBaseRegistrarImplementation',
      'TLDNameWrapper',
      'ENSDeployer',
      'PublicResolver',
      'Registry'
    ],
    format: 'json',
    spacing: 2
  },
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
    strict: true
  }
}

export default hardhatUserconfig
