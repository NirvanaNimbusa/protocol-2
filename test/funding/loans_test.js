const Hydro = artifacts.require('./Hydro.sol');
const assert = require('assert');

const { createAssets } = require('../utils/assets');
const { toWei } = require('../utils');

contract('Loans', accounts => {
    let hydro;

    const u1 = accounts[4];
    const u2 = accounts[5];

    beforeEach(async () => {
        hydro = await Hydro.deployed();

        await createAssets([
            {
                symbol: 'ETH',
                name: 'ETH',
                decimals: 18,
                oraclePrice: toWei('500'),
                collateralRate: 15000,
                initBalances: {
                    [u2]: toWei('1')
                },
                initCollaterals: {
                    [u2]: toWei('1')
                }
            },
            {
                symbol: 'USD',
                name: 'USD',
                decimals: 18,
                oraclePrice: toWei('1'),
                collateralRate: 15000,
                initPool: {
                    [u1]: toWei('1000')
                }
            }
        ]);
    });

    it('borrow from pool', async () => {
        assert.equal(true, true);
    });
});