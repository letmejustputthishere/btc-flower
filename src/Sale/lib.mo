import Array "mo:base/Array";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat16";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Option "mo:base/Option";
import Principal "mo:base/Principal";
import Random "mo:base/Random";
import Result "mo:base/Result";
import Time "mo:base/Time";
import TrieMap "mo:base/TrieMap";

import AviateAccountIdentifier "mo:accountid/AccountIdentifier";
import Root "mo:cap/Root";

import AID "../toniq-labs/util/AccountIdentifier";
import Buffer "../buffer";
import Env "../Env";
import Types "types";
import Utils "../utils";

module {
  public class Factory(this : Principal, state : Types.StableState, deps : Types.Dependencies, consts : Types.Constants) {

    /*********
    * STATE *
    *********/

    private var _saleTransactions : Buffer.Buffer<Types.SaleTransaction> = Utils.bufferFromArray<Types.SaleTransaction>(state._saleTransactionsState);
    private var _salesSettlements : TrieMap.TrieMap<Types.AccountIdentifier, Types.Sale> = TrieMap.fromEntries(state._salesSettlementsState.vals(), AID.equal, AID.hash);
    private var _failedSales : Buffer.Buffer<(Types.AccountIdentifier, Types.SubAccount)> = Utils.bufferFromArray<(Types.AccountIdentifier, Types.SubAccount)>(state._failedSalesState);
    private var _tokensForSale : Buffer.Buffer<Types.TokenIndex> = Utils.bufferFromArray<Types.TokenIndex>(state._tokensForSaleState);
    private var _ethFlowerWhitelist : Buffer.Buffer<Types.AccountIdentifier> = Utils.bufferFromArray<Types.AccountIdentifier>(state._ethFlowerWhitelistState);
    private var _modclubWhitelist : Buffer.Buffer<Types.AccountIdentifier> = Utils.bufferFromArray<Types.AccountIdentifier>(state._modclubWhitelistState);
    private var _soldIcp : Nat64 = state._soldIcpState;
    private var _sold : Nat = state._soldState;
    private var _totalToSell : Nat = state._totalToSellState;
    private var _nextSubAccount : Nat = state._nextSubAccountState;

    public func toStable() : Types.StableState {
      return {
        _saleTransactionsState = _saleTransactions.toArray();
        _salesSettlementsState = Iter.toArray(_salesSettlements.entries());
        _failedSalesState = _failedSales.toArray();
        _tokensForSaleState = _tokensForSale.toArray();
        _ethFlowerWhitelistState = _ethFlowerWhitelist.toArray();
        _modclubWhitelistState = _modclubWhitelist.toArray();
        _soldIcpState = _soldIcp;
        _soldState = _sold;
        _totalToSellState = _totalToSell;
        _nextSubAccountState = _nextSubAccount;
      };
    };

    // *** ** ** ** ** ** ** ** ** * * PUBLIC INTERFACE * ** ** ** ** ** ** ** ** ** ** /

    // updates
    public func initMint(caller : Principal) : async Result.Result<(), Text> {
      assert (caller == consts.minter and deps._Tokens.getNextTokenId() == 0);
      try {
        // get modclub whitelist from canister
        let modclubWhitelistFromCanister : [Types.AccountIdentifier] = Array.map<Principal, Types.AccountIdentifier>(
          await consts.WHITELIST_CANISTER.getWhitelist(),
          func(p : Principal) {
            Utils.toLowerString(AviateAccountIdentifier.toText(AviateAccountIdentifier.fromPrincipal(p, null)));
          },
        );
        //Mint
        mintCollection(Env.collectionSize);
        // turn whitelist into buffer for better performance
        setWhitelist(Env.ethFlowerWhitelist, _ethFlowerWhitelist);
        // concatenate with contest partiticapants that are hardcoded
        let concatenatedModclubWhitelist = Array.append(modclubWhitelistFromCanister, Env.modclubWhitelist);
        // set the whitelist
        setWhitelist(concatenatedModclubWhitelist, _modclubWhitelist);
        // get initial token indices (this will return all tokens as all of them are owned by "0000")
        _tokensForSale := switch (deps._Tokens.getTokensFromOwner("0000")) {
          case (?t) t;
          case (_) Buffer.Buffer<Types.TokenIndex>(0);
        };
        return #ok;
      } catch e {
        return #err("Failed to initialize");
      };
    };

    public func shuffleTokensForSale(caller : Principal) : async () {
      assert (caller == consts.minter and Nat32.toNat(Env.collectionSize) == _tokensForSale.size());
      // shuffle indices
      let seed : Blob = await Random.blob();
      _tokensForSale := deps._Shuffle.shuffleTokens(_tokensForSale, seed);
    };

    public func airdropTokens(caller : Principal, startingIndex : Nat) : () {
      assert (caller == consts.minter and _totalToSell == 0);
      // airdrop tokens
      var temp = 0;
      label airdrop for (a in Env.airdrop.vals()) {
        if (temp < startingIndex) {
          temp += 1;
          continue airdrop;
        } else if (temp >= startingIndex +1500) {
          break airdrop;
        };
        // nextTokens() updates _tokensForSale, removing consumed tokens
        deps._Tokens.transferTokenToUser(nextTokens(1)[0], a);
        temp += 1;
      };
    };

    public func startSale(caller : Principal) : Nat {
      assert (caller == consts.minter and _totalToSell == 0);
      _totalToSell := _tokensForSale.size();
      _tokensForSale.size();
    };

    public func reserve(amount : Nat64, quantity : Nat64, address : Types.AccountIdentifier, _subaccountNOTUSED : Types.SubAccount) : Result.Result<(Types.AccountIdentifier, Nat64), Text> {
      if (Time.now() < Env.publicSaleStart) {
        return #err("The sale has not started yet");
      };
      if (isWhitelistedAny(address) == false) {
        if (Time.now() < Env.whitelistTime) {
          return #err("The public sale has not started yet");
        };
      };
      if (availableTokens() == 0) {
        return #err("No more NFTs available right now!");
      };
      if (availableTokens() < Nat64.toNat(quantity)) {
        return #err("Not enough NFTs available!");
      };
      var total : Nat64 = (getAddressPrice(address) * quantity);
      var bp = getAddressBulkPrice(address);
      var lastq : Nat64 = 1;
      // check the bulk prices available
      for (a in bp.vals()) {
        // if there is a precise match, the end price is in the bulk price tuple
        // and we can replace total
        if (a.0 == quantity) {
          total := a.1;
        };
        lastq := a.0;
      };
      // we check that no one can buy more than specified in the bulk prices
      if (quantity > lastq) {
        return #err("Quantity error");
      };
      if (total > amount) {
        return #err("Price mismatch!");
      };
      let subaccount = getNextSubAccount();
      let paymentAddress : Types.AccountIdentifier = AID.fromPrincipal(this, ?subaccount);

      // we only reserve the tokens here, they deducted from the available tokens
      // after payment. otherwise someone could stall the sale by reserving all
      // the tokens without paying for them
      let tokens : [Types.TokenIndex] = tempNextTokens(quantity);
      if (Env.whitelistOneTimeOnly == true) {
        if (isWhitelisted(address, _ethFlowerWhitelist)) {
          removeFromWhitelist(address, _ethFlowerWhitelist);
        } else if (isWhitelisted(address, _modclubWhitelist)) {
          removeFromWhitelist(address, _modclubWhitelist);
        };
      };
      _salesSettlements.put(
        paymentAddress,
        {
          tokens = tokens;
          price = total;
          subaccount = subaccount;
          buyer = address;
          expires = Time.now() + Env.ecscrowDelay;
        },
      );
      #ok((paymentAddress, total));
    };

    public func retrieve(caller : Principal, paymentaddress : Types.AccountIdentifier) : async Result.Result<(), Text> {
      if (Option.isNull(_salesSettlements.get(paymentaddress))) {
        return #err("Nothing to settle");
      };

      let response : Types.ICPTs = await consts.LEDGER_CANISTER.account_balance_dfx({
        account = paymentaddress;
      });

      // because of the await above, we check again if there is a settlement available for the paymentaddress
      let settlement = switch (_salesSettlements.get(paymentaddress)) {
        case (?settlement) { settlement };
        case (null) {
          return #err("Nothing to settle");
        };
      };

      if (response.e8s >= settlement.price) {
        if (settlement.tokens.size() > availableTokens()) {
          // Issue refund if not enough NFTs available
          deps._Disburser.addDisbursement({
            to = settlement.buyer;
            fromSubaccount = settlement.subaccount;
            amount = response.e8s - 10000;
            tokenIndex = 0;
          });
          _salesSettlements.delete(paymentaddress);
          return #err("Not enough NFTs - a refund will be sent automatically very soon");
        } else {
          var tokens = nextTokens(Nat64.fromNat(settlement.tokens.size()));
          for (a in tokens.vals()) {
            deps._Tokens.transferTokenToUser(a, settlement.buyer);
          };
          _saleTransactions.add({
            tokens = tokens;
            seller = this;
            price = settlement.price;
            buyer = settlement.buyer;
            time = Time.now();
          });
          _soldIcp += settlement.price;
          _sold += tokens.size();
          _salesSettlements.delete(paymentaddress);
          let event : Root.IndefiniteEvent = {
            operation = "mint";
            details = [
              ("to", #Text(settlement.buyer)),
              ("price_decimals", #U64(8)),
              ("price_currency", #Text("ICP")),
              ("price", #U64(settlement.price)),
              // there can only be one token in tokens due to the reserve function
              ("token_id", #Text(Utils.indexToIdentifier(settlement.tokens[0], this))),
            ];
            caller;
          };
          ignore deps._Cap.insert(event);
          // Payout
          var bal : Nat64 = response.e8s - (10000 * 1); //Remove 2x tx fee
          deps._Disburser.addDisbursement({
            to = Env.teamAddress;
            fromSubaccount = settlement.subaccount;
            amount = bal;
            tokenIndex = 0;
          });
          return #ok();
        };
      } else {
        // if the settlement expired and they still didnt send the full amount, we add them to failedSales
        if (settlement.expires < Time.now()) {
          _failedSales.add((settlement.buyer, settlement.subaccount));
          _salesSettlements.delete(paymentaddress);
          if (Env.whitelistOneTimeOnly == true) {
            if (settlement.price == Env.ethFlowerWhitelistPrice) {
              addToWhitelist(settlement.buyer, _ethFlowerWhitelist);
            } else if (settlement.price == Env.modclubWhitelistPrice) {
              addToWhitelist(settlement.buyer, _modclubWhitelist);
            };
          };
          return #err("Expired");
        } else {
          return #err("Insufficient funds sent");
        };
      };
    };

    public func cronSalesSettlements(caller : Principal) : async () {
      // _saleSattlements can potentially be really big, we have to make sure
      // we dont get out of cycles error or error that outgoing calls queue is full.
      // This is done by adding the await statement.
      // For every message the max cycles is reset
      label settleLoop while (true) {
        switch (expiredSalesSettlements().keys().next()) {
          case (?paymentAddress) {
            try {
              ignore (await retrieve(caller, paymentAddress));
            } catch (e) {};
          };
          case null break settleLoop;
        };
      };
    };

    public func cronFailedSales() : async () {
      label failedSalesLoop while (true) {
        let last = _failedSales.removeLast();
        switch (last) {
          case (?failedSale) {
            let subaccount = failedSale.1;
            try {
              // check if subaccount holds icp
              let response : Types.ICPTs = await consts.LEDGER_CANISTER.account_balance_dfx({
                account = AID.fromPrincipal(this, ?subaccount);
              });
              if (response.e8s > 10000) {
                var bh = await consts.LEDGER_CANISTER.transfer({
                  memo = 0;
                  amount = { e8s = response.e8s - 10000 };
                  fee = { e8s = 10000 };
                  from_subaccount = ?subaccount;
                  to = switch (Utils.ledgerAccountIdentifierFromText(failedSale.0)) {
                    case (#ok(accountId)) {
                      accountId : [Nat8];
                    };
                    case (#err(_)) {
                      // this should never happen because account ids are always created from within the
                      // canister which should guarantee that they are valid and we are able to decode them
                      // to [Nat8]
                      continue failedSalesLoop;
                    };
                  };
                  created_at_time = null;
                });
              };
            } catch (e) {
              // if the transaction fails for some reason, we add it back to the Buffer
              _failedSales.add(failedSale);
            };
          };
          case (null) {
            break failedSalesLoop;
          };
        };
      };
    };

    public func getNextSubAccount() : Types.SubAccount {
      var _saOffset = 4294967296;
      _nextSubAccount += 1;
      return Utils.natToSubAccount(_saOffset +_nextSubAccount);
    };

    // queries
    public func salesSettlements() : [(Types.AccountIdentifier, Types.Sale)] {
      Iter.toArray(_salesSettlements.entries());
    };

    public func failedSales() : [(Types.AccountIdentifier, Types.SubAccount)] {
      _failedSales.toArray();
    };

    public func saleTransactions() : [Types.SaleTransaction] {
      _saleTransactions.toArray();
    };

    public func getSold() : Nat {
      _sold;
    };

    public func getTotalToSell() : Nat {
      _totalToSell;
    };

    public func salesSettings(address : Types.AccountIdentifier) : Types.SaleSettings {
      return {
        price = getAddressPrice(address);
        salePrice = Env.salePrice;
        remaining = availableTokens();
        sold = _sold;
        totalToSell = _totalToSell;
        startTime = Env.publicSaleStart;
        whitelistTime = Env.whitelistTime;
        whitelist = isWhitelistedAny(address);
        bulkPricing = getAddressBulkPrice(address);
      } : Types.SaleSettings;
    };

    /*******************
    * INTERNAL METHODS *
    *******************/

    // getters & setters
    public func ethFlowerWhitelistSize() : Nat {
      _ethFlowerWhitelist.size();
    };

    public func modclubWhitelistSize() : Nat {
      _modclubWhitelist.size();
    };

    public func availableTokens() : Nat {
      _tokensForSale.size();
    };

    public func soldIcp() : Nat64 {
      _soldIcp;
    };

    // internals
    func tempNextTokens(qty : Nat64) : [Types.TokenIndex] {
      Array.freeze(Array.init<Types.TokenIndex>(Nat64.toNat(qty), 0));
    };

    func getAddressPrice(address : Types.AccountIdentifier) : Nat64 {
      getAddressBulkPrice(address)[0].1;
    };

    //Set different price types here
    func getAddressBulkPrice(address : Types.AccountIdentifier) : [(Nat64, Nat64)] {
      // order by WL price, cheapest first
      if (isWhitelisted(address, _ethFlowerWhitelist)) {
        return [(1, Env.ethFlowerWhitelistPrice)];
      };
      if (isWhitelisted(address, _modclubWhitelist)) {
        return [(1, Env.modclubWhitelistPrice)];
      };
      return [(1, Env.salePrice)];
    };

    public func setWhitelist(whitelistAddresses : [Types.AccountIdentifier], whitelist : Buffer.Buffer<Types.AccountIdentifier>) {
      whitelist.append(Utils.bufferFromArray<Types.AccountIdentifier>(whitelistAddresses));
    };

    func nextTokens(qty : Nat64) : [Types.TokenIndex] {
      if (_tokensForSale.size() >= Nat64.toNat(qty)) {
        var ret : List.List<Types.TokenIndex> = List.nil();
        while (List.size(ret) < Nat64.toNat(qty)) {
          switch (_tokensForSale.removeLast()) {
            case (?token) {
              ret := List.push(token, ret);
            };
            case _ return [];
          };
        };
        List.toArray(ret);
      } else {
        [];
      };
    };

    func isWhitelisted(address : Types.AccountIdentifier, whitelist : Buffer.Buffer<Types.AccountIdentifier>) : Bool {
      if (Env.whitelistDiscountLimited == true and Time.now() >= Env.whitelistTime) {
        return false;
      };
      Option.isSome(whitelist.find(func(a : Types.AccountIdentifier) : Bool { a == address }));
    };

    func isWhitelistedAny(address : Types.AccountIdentifier) : Bool {
      return (isWhitelisted(address, _ethFlowerWhitelist) or isWhitelisted(address, _modclubWhitelist));
    };

    func removeFromWhitelist(address : Types.AccountIdentifier, whitelist : Buffer.Buffer<Types.AccountIdentifier>) : () {
      var found : Bool = false;
      whitelist.filterSelf(
        func(a : Types.AccountIdentifier) : Bool {
          if (found) { return true } else {
            if (a != address) return true;
            found := true;
            return false;
          };
        },
      );
    };

    func addToWhitelist(address : Types.AccountIdentifier, whitelist : Buffer.Buffer<Types.AccountIdentifier>) : () {
      whitelist.add(address);
    };

    func mintCollection(collectionSize : Nat32) {
      deps._Tokens.mintCollection(collectionSize);
    };

    func expiredSalesSettlements() : TrieMap.TrieMap<Types.AccountIdentifier, Types.Sale> {
      TrieMap.mapFilter<Types.AccountIdentifier, Types.Sale, Types.Sale>(
        _salesSettlements,
        AID.equal,
        AID.hash,
        func(a : (Types.AccountIdentifier, Types.Sale)) : ?Types.Sale {
          switch (a.1.expires < Time.now()) {
            case (true) {
              ?a.1;
            };
            case (false) {
              null;
            };
          };
        },
      );
    };
  };
};
