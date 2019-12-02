/*
-----------------------------------------------------------------
MODULE DESCRIPTION
-----------------------------------------------------------------

The SNX supply schedule contract determines the amount of SNX tokens
mintable over the course of 195 weeks.

Exponential Decay Inflation Schedule

Synthetix.mint() function is used to mint the inflationary supply.

The mechanics for Inflation Smoothing and Terminal Inflation 
have been defined in these sips
https://sips.synthetix.io/sips/sip-23
https://sips.synthetix.io/sips/sip-24

The previous SNX Inflation Supply Schedule is at 
https://etherscan.io/address/0xA3de830b5208851539De8e4FF158D635E8f36FCb#code

-----------------------------------------------------------------
*/

pragma solidity 0.4.25;

import "./SafeDecimalMath.sol";
import "./Owned.sol";
import "./interfaces/ISynthetix.sol";

/**
 * @title SupplySchedule contract
 */
contract SupplySchedule is Owned {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    // How long each inflation period is before mint can be called
    uint public mintPeriodDuration = 1 weeks;

    // Time of the last inflation supply mint event
    uint public lastMintEvent;

    // Counter for number of weeks since the start of supply inflation
    uint public weekCounter;

    // The number of SNX rewarded to the caller of Synthetix.mint()
    uint public minterReward = 50 * SafeDecimalMath.unit();

    // Calculated in the constructor. The initial weekly inflationary supply is 75m / 52 until the start of the decay rate. 
    uint public initialWeeklySupply;    

    // Address of the SynthetixProxy for the onlySynthetix modifier
    address public synthetixProxy;

    uint public constant INFLATION_START_DATE = 1551830400; // 2019-03-06T00:00:00+00:00
    uint8 public constant SUPPLY_DECAY_START = 40; // Week 40 (Wednesday, 11 December 2019 00:00:00)
    uint8 public constant SUPPLY_DECAY_END = 234; //  Supply Decay stops after Week 234 (195 weeks of inflation decay)
    
    // Percentage decay of inflationary supply from the first 40 weeks of the 75% inflation rate
    uint public constant DECAY_RATE = 12500000000000000; // 1.25% weekly

    // Percentage growth of terminal supply per annum
    uint public terminalSupplyRate = 25000000000000000; // 2.5% pa
    
    constructor(
        address _owner,
        uint _lastMintEvent,
        uint _currentWeek)
        Owned(_owner)
        public
    {
        // initial weekly inflation supply is 75m / 52  in Year 1
        initialWeeklySupply = 75e6 * SafeDecimalMath.unit() / 52;

        lastMintEvent = _lastMintEvent;
        weekCounter = _currentWeek;
    }

    // ========== VIEWS ==========     
    
    /**    
    * @return The amount of SNX mintable for the inflationary supply
    */
    function mintableSupply()
        public
        view
        returns (uint)
    {
        uint totalAmount;

        if (!isMintable()) {
            return totalAmount;
        }
        
        uint remainingWeeksToMint = weeksSinceLastIssuance();
          
        uint currentWeek = weekCounter;
        
        // Calculate total mintable supply from exponential decay function
        // The decay function stops after week 234
        while (remainingWeeksToMint > 0) {
            currentWeek++;            
            
            // If current week is before supply decay we add initial supply to mintableSupply
            if (currentWeek < SUPPLY_DECAY_START) {
                totalAmount = totalAmount.add(initialWeeklySupply);
                remainingWeeksToMint--;
            }
            // if current week before supply decay ends we add the new supply for the week 
            else if (currentWeek < SUPPLY_DECAY_END) {
                
                // number of decays is diff between current week and (Supply decay start week - 1)  
                uint decayCount = currentWeek.sub(SUPPLY_DECAY_START -1);
                
                totalAmount = totalAmount.add(tokenDecaySupplyForWeek(decayCount));
                remainingWeeksToMint--;
            } 
            // Terminal supply is calculated on the total supply of Synthetix including any new supply
            // We can compound the remaining week's supply at the fixed terminal rate  
            else {
                uint totalSupply = ISynthetix(synthetixProxy).totalSupply();
                uint currentTotalSupply = totalSupply.add(totalAmount);

                totalAmount = totalAmount.add(terminalInflationSupply(currentTotalSupply, remainingWeeksToMint));
                remainingWeeksToMint = 0;
            }
        }
        
        return totalAmount;
    }

    /**
    * @return A unit amount of decaying inflationary supply from the initialWeeklySupply
    * @dev New token supply reduces by the decay rate each week calculated as supply = initialWeeklySupply * () 
    */
    function tokenDecaySupplyForWeek(uint counter)
        public 
        view
        returns (uint)
    {   
        // Apply exponential decay function to number of weeks since
        // start of inflation smoothing to calculate diminishing supply for the week.
        uint decay_factor = (SafeDecimalMath.unit().sub(DECAY_RATE)) ** counter;
        
        return initialWeeklySupply.multiplyDecimal(decay_factor);
    }    
    
    /**
    * @return A unit amount of terminal inflation supply
    * @dev Weekly compound rate based on number of weeks     
    */
    function terminalInflationSupply(uint totalSupply, uint numOfweeks)
        public 
        view
        returns (uint)
    {   
        // Terminal inflationary supply is compounded weekly from Synthetix total supply 
        uint effectiveRate = (SafeDecimalMath.unit().add(terminalSupplyRate.divideDecimal(52))) ** numOfweeks;
        
        // return compounded supply for period
        return totalSupply.multiplyDecimal((effectiveRate).sub(SafeDecimalMath.unit()));
    }

    /**    
    * @dev Take timeDiff in seconds (Dividend) and mintPeriodDuration as (Divisor)
    * @return Calculate the numberOfWeeks since last mint rounded down to 1 week
    */
    function weeksSinceLastIssuance()
        public
        view
        returns (uint)
    {
        // Get weeks since lastMintEvent
        // If lastMintEvent not set or 0, then start from inflation start date.
        uint timeDiff = lastMintEvent > 0 ? now.sub(lastMintEvent) : now.sub(INFLATION_START_DATE);
        return timeDiff.div(mintPeriodDuration);
    }

    /**
     * @return boolean whether the mintPeriodDuration (7 days)
     * has passed since the lastMintEvent.
     * */
    function isMintable()
        public
        view
        returns (bool)
    {
        if (now - lastMintEvent > mintPeriodDuration)
        {
            return true;
        }
        return false;
    }

    // ========== MUTATIVE FUNCTIONS ==========

    /**
     * @notice Record the mint event from Synthetix by incrementing the inflation 
     * week counter for the number of weeks minted (probabaly always 1)
     * and store the time of the event.
     * @param supplyMinted the amount of SNX the total supply was inflated by.
     * */
    function recordMintEvent(uint supplyMinted)
        external
        onlySynthetix
        returns (bool)
    {
        uint numberOfWeeksIssued = weeksSinceLastIssuance();

        // add number of weeks minted to weekCounter
        weekCounter.add(numberOfWeeksIssued);

        // Update mint event to now
        lastMintEvent = now;

        emit SupplyMinted(supplyMinted, numberOfWeeksIssued, now);
        return true;
    }

    /**
     * @notice Sets the reward amount of SNX for the caller of the public 
     * function Synthetix.mint(). 
     * This incentivises anyone to mint the inflationary supply and the mintr 
     * Reward will be deducted from the inflationary supply and sent to the caller.
     * @param amount the amount of SNX to reward the minter.
     * */
    function setMinterReward(uint amount)
        external
        onlyOwner
    {
        minterReward = amount;
        emit MinterRewardUpdated(minterReward);
    }

    // ========== SETTERS ========== */

    /**
     * @notice Set the SynthetixProxy should it ever change.
     * SupplySchedule requires Synthetix address as it has the authority
     * to record mint event.
     * */
    function setSynthetixProxy(ISynthetix _synthetixProxy)
        external
        onlyOwner
    {
        synthetixProxy = _synthetixProxy;
    }

    // ========== MODIFIERS ==========

    /**
     * @notice Only the Synthetix contract is authorised to call this function
     * */
    modifier onlySynthetix() {
        require(msg.sender == address(Proxy(synthetixProxy).target()), "Only the synthetix contract can perform this action");
        _;
    }

    /* ========== EVENTS ========== */
    /**
     * @notice Emitted when the inflationary supply is minted
     * */
    event SupplyMinted(uint supplyMinted, uint numberOfWeeksIssued, uint timestamp);

    /**
     * @notice Emitted when the SNX minter reward amount is updated
     * */
    event MinterRewardUpdated(uint newRewardAmount);
}
