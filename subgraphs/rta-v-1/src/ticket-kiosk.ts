import { BigInt, Address, Bytes } from "@graphprotocol/graph-ts"
import {
  TicketMinted as TicketMintedEvent,
  RevenueDistributed as RevenueDistributedEvent
} from "../generated/templates/TicketKiosk/TicketKiosk"
import {
  Event,
  Ticket,
  TicketKiosk,
  RevenueDistribution,
  TicketMintedLog,
  RevenueDistributedLog,
  GlobalStats
} from "../generated/schema"

export function handleTicketMinted(event: TicketMintedEvent): void {
  // Create unique ticket ID using kiosk address and ticket ID
  let ticketId = event.address.toHex() + "-" + event.params.ticketId.toString()
  
  // Create Ticket entity
  let ticket = new Ticket(ticketId)
  ticket.ticketId = event.params.ticketId
  ticket.owner = event.params.buyer
  ticket.originalOwner = event.params.buyer
  ticket.purchasePrice = event.params.price
  ticket.purchaseTimestamp = event.block.timestamp
  ticket.ticketName = event.params.ticketName
  ticket.artCategory = event.params.artCategory
  ticket.kioskAddress = event.address.toHex()
  ticket.mintedAtTimestamp = event.block.timestamp
  ticket.mintedAtBlockNumber = event.block.number
  ticket.transactionHash = event.transaction.hash

  // Load TicketKiosk to get event information
  let kiosk = TicketKiosk.load(event.address.toHex())
  if (kiosk) {
    ticket.eventId = kiosk.eventId
    ticket.event = kiosk.eventId.toString()
    
    // Update kiosk stats
    kiosk.ticketsSold = kiosk.ticketsSold.plus(BigInt.fromI32(1))
    kiosk.totalRevenue = kiosk.totalRevenue.plus(event.params.price)
    kiosk.save()

    // Update event stats
    let eventEntity = Event.load(kiosk.eventId.toString())
    if (eventEntity) {
      eventEntity.ticketsSold = eventEntity.ticketsSold.plus(BigInt.fromI32(1))
      eventEntity.totalRevenue = eventEntity.totalRevenue.plus(event.params.price)
      eventEntity.updatedAtTimestamp = event.block.timestamp
      eventEntity.save()
    }

    // Set ticket number and total tickets (we'll need to track this)
    ticket.ticketNumber = kiosk.ticketsSold
    ticket.totalTickets = kiosk.ticketsAmount
  } else {
    // If we can't find the kiosk, set defaults
    ticket.eventId = BigInt.fromI32(0)
    ticket.event = "0"
    ticket.ticketNumber = BigInt.fromI32(1)
    ticket.totalTickets = BigInt.fromI32(1)
  }

  ticket.save()

  // Create TicketMintedLog entity
  let ticketLog = new TicketMintedLog(
    event.transaction.hash.toHex() + "-" + event.logIndex.toString()
  )
  ticketLog.ticketId = event.params.ticketId
  ticketLog.buyer = event.params.buyer
  ticketLog.ticketName = event.params.ticketName
  ticketLog.artCategory = event.params.artCategory
  ticketLog.price = event.params.price
  ticketLog.timestamp = event.block.timestamp
  ticketLog.blockNumber = event.block.number
  ticketLog.transactionHash = event.transaction.hash
  ticketLog.save()

  // Update global stats
  updateGlobalTicketStats(event.block.timestamp, event.block.number, event.params.price)
}

export function handleRevenueDistributed(event: RevenueDistributedEvent): void {
  // Create RevenueDistribution entity
  let revenueId = event.transaction.hash.toHex() + "-" + event.logIndex.toString()
  let revenue = new RevenueDistribution(revenueId)
  revenue.creator = event.params.creator
  revenue.treasury = event.params.treasury
  revenue.creatorAmount = event.params.creatorAmount
  revenue.treasuryAmount = event.params.treasuryAmount
  revenue.timestamp = event.block.timestamp
  revenue.blockNumber = event.block.number
  revenue.transactionHash = event.transaction.hash

  // Load TicketKiosk to get event and ticket information
  let kiosk = TicketKiosk.load(event.address.toHex())
  if (kiosk) {
    revenue.event = kiosk.eventId.toString()
    
    // Try to find the most recent ticket for this transaction
    // This is a simplified approach - in a real implementation you might want to be more precise
    let ticketId = event.address.toHex() + "-" + kiosk.ticketsSold.toString()
    let ticket = Ticket.load(ticketId)
    if (ticket) {
      revenue.ticket = ticketId
    }
  }

  revenue.save()

  // Create RevenueDistributedLog entity
  let revenueLog = new RevenueDistributedLog(
    event.transaction.hash.toHex() + "-revenue-" + event.logIndex.toString()
  )
  revenueLog.creator = event.params.creator
  revenueLog.treasury = event.params.treasury
  revenueLog.creatorAmount = event.params.creatorAmount
  revenueLog.treasuryAmount = event.params.treasuryAmount
  revenueLog.timestamp = event.block.timestamp
  revenueLog.blockNumber = event.block.number
  revenueLog.transactionHash = event.transaction.hash
  revenueLog.save()
}

function updateGlobalTicketStats(timestamp: BigInt, blockNumber: BigInt, ticketPrice: BigInt): void {
  let stats = GlobalStats.load("global")
  if (!stats) {
    stats = new GlobalStats("global")
    stats.totalEvents = BigInt.fromI32(0)
    stats.totalTickets = BigInt.fromI32(0)
    stats.totalRevenue = BigInt.fromI32(0)
    stats.totalActiveEvents = BigInt.fromI32(0)
    stats.totalFinalizedEvents = BigInt.fromI32(0)
  }

  stats.totalTickets = stats.totalTickets.plus(BigInt.fromI32(1))
  stats.totalRevenue = stats.totalRevenue.plus(ticketPrice)
  stats.lastUpdatedTimestamp = timestamp
  stats.lastUpdatedBlockNumber = blockNumber
  stats.save()
} 