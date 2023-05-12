require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    compilers: [
      {
        version: '0.7.6',
        settings: {
          optimizer: {
            enabled: true,
            runs: 800,
          },
          metadata: {
            // do not include the metadata hash, since this is machine dependent
            // and we want all generated code to be deterministic
            // https://docs.soliditylang.org/en/v0.7.6/metadata.html
            bytecodeHash: 'none',
          },
        }
      }
    ],
    overrides: {
      "contracts/BoosterPool.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        },
      },
      "contracts/libraries/FullMath.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "contracts/libraries/TickMath.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },


      "@openzeppelin/contracts/utils/math/Math.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "@openzeppelin/contracts/utils/Address.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "@openzeppelin/contracts/token/ERC20/IERC20.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "@openzeppelin/contracts/token/ERC20/ERC20.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "@openzeppelin/contracts/utils/Context.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "@openzeppelin/contracts/security/ReentrancyGuard.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "contracts/libraries/LiquidityAmounts.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "contracts/tokens/token6.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "contracts/tokens/token18.sol": {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      },
      "contracts/tokens/WETH.sol": {
        version: "0.4.22",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          }
        }
      }
    }

  }
}