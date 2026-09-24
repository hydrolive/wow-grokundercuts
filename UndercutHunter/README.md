# Undercut Hunter

Undercut Hunter is a World of Warcraft: Forever addon. It adds a **Bargains** tab to the Auction House and lists other players' auctions that are cheap compared with Auctionator's last scanned market price.

Interface: **16001** (Forever beta 1.60.1). This is not a Retail addon and not a Classic Era addon.

## Install

During the Forever beta, copy this folder to:

`World of Warcraft/_classic_beta_/Interface/AddOns/UndercutHunter`

It must sit next to Auctionator. After launch the client folder name may change. Keep `## Interface: 16001` and put `UndercutHunter` in that client's `Interface/AddOns` directory.

Optional libraries, installed as their own addon folders if you use them:

- LibStub
- LibAHTab-1-0

If LibAHTab is missing, or Forever renames the Auction House frame, the addon attaches itself. It looks for `AuctionHouseFrame` first and `AuctionFrame` second, and it does not call `PanelTemplates_SetNumTabs` (that call is what taints bags).

## Auctionator

Install **Auctionator's Forever / 1.60.1 build**, not a Classic Era zip. CurseForge Auctionator 337 and newer include the Forever fixes for durations, unit price, and the reagent bag.

This addon does not fork Auctionator and does not read Auctionator's saved database. It calls only the public API:

- `Auctionator.API.v1.GetAuctionPriceByItemID`
- `Auctionator.API.v1.GetAuctionPriceByItemLink`
- `Auctionator.API.v1.MultiSearch`
- `Auctionator.API.v1.RegisterForDBUpdate`

## First session

1. Enable Undercut Hunter and Auctionator.
2. Open the Auction House, open the **Auctionator** tab, and run **Full Scan**.
3. Open the **Bargains** tab.
4. Leave the threshold at **50** (at or below 50% of market).
5. Shift-click wool, herbs, or cloth into the box, or paste an item ID, and press **Add**.
6. Press **Scan**.
7. Click a row. Press **Buyout** and confirm.

Example that the scan is built for: Auctionator's market for wool is 10 silver, and someone listed wool at 1 silver buyout. That row sorts near the top (90% off). Select it and press Buyout. The confirm popup shows the item, quantity, listed price, market price, percent off, gold saved, and total cost.

Forever's auction house is per faction. Alliance cities share one house, Horde cities share another, and neutral cities (Gadgetzan, Booty Bay, Everlook) are separate and take a higher cut. Scan the house you are standing at. Prices are not cross-faction.

## What a scan does

The default scan is the watchlist, not a dump of the whole house.

On the modern Auction House API the scan sends at most 100 item keys per `SearchForItemKeys` call, waits when `IsThrottledMessageSystemReady` says the client is throttled, then runs `SendSearchQuery` for items that still look cheap. Listings are kept when the unit buyout is at or below your percent of Auctionator's unit price. Bid-only rows (buyout of 0) are skipped unless **Show bid-only** is on, and those rows cannot be bought out.

**Watchlist + pasted IDs** also scans item IDs you added with **Add IDs**. The cap box limits how many priced items are queried in one session (default 500).

**Deep Scan** calls `ReplicateItems` only after a warning. It is not the normal scan. It can stall the client. Buyout is still one confirmed purchase.

If this client has neither the modern `C_AuctionHouse` search API nor the legacy `QueryAuctionItems` API, the tab shows: "This client has no supported Auction House API."

## Buyout

Nothing is purchased by a timer, a queue, or an unattended click.

1. Buyout (or a double-click, if that option is on) re-queries that one item.
2. If the price, stack, or auction id no longer matches, the addon prints "Listing changed or disappeared." and buys nothing.
3. If it still matches, the confirm popup is the purchase click.

The modern client only accepts `PlaceBid` and `StartCommoditiesPurchase` from a real button click, so the fresh search finishes first and the confirm button places the bid. One confirm buys one listing. Turning **Confirm buyout** off still requires a second press of Buyout; that second press is the purchase, and it expires on its own without buying.

Commodity purchase is used only when the client returns commodity search results for that item. Wool-style goods stay ordinary stack auctions unless the client says otherwise.

## Slash commands

```
/uh
/uh scan
/uh stop
/uh threshold 50
/uh add [item link or item id]
/uh clear
/uh debug on
/uh debug off
```

`/uh debug on` prints the client build, whether the modern or legacy house API is present, which `C_AuctionHouse` functions exist, and whether Auctionator's public API loaded. Forever is still in beta; if a frame or event name moves, start there.

## Limitations

- The market price is Auctionator's last scan for the house you scanned, not a live realm-wide average.
- A listing can sell or expire between the scan and the confirm click. The addon aborts when the fresh query no longer matches.
- Forever's Auction House API can still change during beta. The addon picks modern or legacy at runtime instead of trusting `WOW_PROJECT_ID` (Forever currently reports itself as mainline).
- Vendor sell price is not used as a market unless you enable **Vendor price fallback**. That box defaults to off.
- Seller names are hidden unless **Show owner** is on. The scan does not depend on them.

## Terms of service

Scanning the Auction House and buying one listing after you click Buyout is the same class of tool as Auctionator. Auto-buy is not implemented. Do not add a ticker, a purchase queue, an external process, or anything that buys while you are away.

## Not Auctionator Cancelling

Auctionator's Cancelling scan looks for **your** auctions that someone else has undercut, so you can cancel and repost.

Undercut Hunter looks for **other people's** listings that are far below Auctionator's market price, so you can buy them. It does not cancel your auctions.
