import { BigInt, Bytes, Address } from "@graphprotocol/graph-ts"
import {
  EventCreated as EventCreatedEvent,
  MetadataUpdated as MetadataUpdatedEvent,
  ReservePriceUpdated as ReservePriceUpdatedEvent,
  EventFinalized as EventFinalizedEvent,
  EventFinalizedAndTransferred as EventFinalizedAndTransferredEvent,
  EventFactory
} from "../generated/EventFactory/EventFactory"
import {
  TicketKiosk as TicketKioskContract
} from "../generated/templates/TicketKiosk/TicketKiosk"
import {
  Event,
  EventCreatedLog,
  MetadataUpdatedLog,
  ReservePriceUpdatedLog,
  EventFinalizedLog,
  EventFinalizedAndTransferredLog,
  TicketKiosk,
  GlobalStats
} from "../generated/schema"
import { TicketKiosk as TicketKioskTemplate } from "../generated/templates"

export function handleEventCreated(event: EventCreatedEvent): void {
  // Get complete event data from contract
  let eventFactoryContract = EventFactory.bind(event.address)
  let eventDataResult = eventFactoryContract.try_getEvent(event.params.eventId)
  
  // Create or update the main Event entity
  let eventEntity = new Event(event.params.eventId.toString())
  eventEntity.eventId = event.params.eventId
  eventEntity.creator = event.params.creator
  eventEntity.startDate = event.params.startDate
  
  // Get eventDuration from contract call if successful
  if (!eventDataResult.reverted) {
    eventEntity.eventDuration = eventDataResult.value.eventDuration
  } else {
    eventEntity.eventDuration = BigInt.fromI32(0) // Default if call fails
  }
  
  eventEntity.reservePrice = event.params.reservePrice
  eventEntity.metadataURI = event.params.metadataURI
  eventEntity.artCategory = event.params.artCategory
  eventEntity.kioskAddress = event.params.ticketKioskAddress
  eventEntity.finalized = false
  eventEntity.createdAtTimestamp = event.block.timestamp
  eventEntity.createdAtBlockNumber = event.block.number
  eventEntity.updatedAtTimestamp = event.block.timestamp
  eventEntity.ticketsSold = BigInt.fromI32(0)
  eventEntity.totalRevenue = BigInt.fromI32(0)
  eventEntity.save()

  // Create EventCreatedLog entity for detailed tracking
  let eventLog = new EventCreatedLog(
    event.transaction.hash.toHex() + "-" + event.logIndex.toString()
  )
  eventLog.eventId = event.params.eventId
  eventLog.creator = event.params.creator
  eventLog.startDate = event.params.startDate
  eventLog.reservePrice = event.params.reservePrice
  eventLog.metadataURI = event.params.metadataURI
  eventLog.artCategory = event.params.artCategory
  eventLog.ticketKioskAddress = event.params.ticketKioskAddress
  eventLog.timestamp = event.block.timestamp
  eventLog.blockNumber = event.block.number
  eventLog.transactionHash = event.transaction.hash
  eventLog.save()

  // Create TicketKiosk entity and get kiosk data from TicketKiosk contract
  let kioskEntity = new TicketKiosk(event.params.ticketKioskAddress.toHex())
  kioskEntity.address = event.params.ticketKioskAddress
  kioskEntity.eventId = event.params.eventId
  kioskEntity.event = event.params.eventId.toString()
  kioskEntity.creator = event.params.creator
  kioskEntity.artCategory = event.params.artCategory
  kioskEntity.ticketsSold = BigInt.fromI32(0)
  kioskEntity.totalRevenue = BigInt.fromI32(0)
  kioskEntity.createdAtTimestamp = event.block.timestamp
  kioskEntity.createdAtBlockNumber = event.block.number
  
  // Start indexing the TicketKiosk contract first
  TicketKioskTemplate.create(event.params.ticketKioskAddress)
  
  // Try to bind to the TicketKiosk contract to get ticketsAmount and ticketPrice
  let ticketKioskContract = TicketKioskContract.bind(event.params.ticketKioskAddress)
  
  // Set default values first
  kioskEntity.ticketsAmount = BigInt.fromI32(0)
  kioskEntity.ticketPrice = BigInt.fromI32(0)
  
  // Try to get actual values from contract
  let ticketsAmountCall = ticketKioskContract.try_ticketsAmount()
  if (!ticketsAmountCall.reverted) {
    kioskEntity.ticketsAmount = ticketsAmountCall.value
  }
  
  let ticketPriceCall = ticketKioskContract.try_ticketPrice()
  if (!ticketPriceCall.reverted) {
    kioskEntity.ticketPrice = ticketPriceCall.value
  }
  
  kioskEntity.save()

  // Update global stats
  updateGlobalStats(event.block.timestamp, event.block.number, true, false)
}

export function handleMetadataUpdated(event: MetadataUpdatedEvent): void {
  let eventEntity = Event.load(event.params.eventId.toString())
  if (eventEntity) {
    eventEntity.metadataURI = event.params.newMetadataURI
    eventEntity.updatedAtTimestamp = event.block.timestamp
    eventEntity.save()
  }

  // Create log entity
  let metadataLog = new MetadataUpdatedLog(
    event.transaction.hash.toHex() + "-" + event.logIndex.toString()
  )
  metadataLog.eventId = event.params.eventId
  metadataLog.newMetadataURI = event.params.newMetadataURI
  metadataLog.timestamp = event.block.timestamp
  metadataLog.blockNumber = event.block.number
  metadataLog.transactionHash = event.transaction.hash
  metadataLog.save()
}

export function handleReservePriceUpdated(event: ReservePriceUpdatedEvent): void {
  let eventEntity = Event.load(event.params.eventId.toString())
  if (eventEntity) {
    eventEntity.reservePrice = event.params.newPrice
    eventEntity.updatedAtTimestamp = event.block.timestamp
    eventEntity.save()
  }

  // Create log entity
  let priceLog = new ReservePriceUpdatedLog(
    event.transaction.hash.toHex() + "-" + event.logIndex.toString()
  )
  priceLog.eventId = event.params.eventId
  priceLog.newPrice = event.params.newPrice
  priceLog.timestamp = event.block.timestamp
  priceLog.blockNumber = event.block.number
  priceLog.transactionHash = event.transaction.hash
  priceLog.save()
}

export function handleEventFinalized(event: EventFinalizedEvent): void {
  let eventEntity = Event.load(event.params.eventId.toString())
  if (eventEntity) {
    eventEntity.finalized = true
    eventEntity.finalizedAtTimestamp = event.block.timestamp
    eventEntity.finalizedAtBlockNumber = event.block.number
    eventEntity.updatedAtTimestamp = event.block.timestamp
    eventEntity.save()
  }

  // Create log entity
  let finalizedLog = new EventFinalizedLog(
    event.transaction.hash.toHex() + "-" + event.logIndex.toString()
  )
  finalizedLog.eventId = event.params.eventId
  finalizedLog.timestamp = event.block.timestamp
  finalizedLog.blockNumber = event.block.number
  finalizedLog.transactionHash = event.transaction.hash
  finalizedLog.save()

  // Update global stats
  updateGlobalStats(event.block.timestamp, event.block.number, false, true)
}

export function handleEventFinalizedAndTransferred(event: EventFinalizedAndTransferredEvent): void {
  let eventEntity = Event.load(event.params.eventId.toString())
  if (eventEntity) {
    eventEntity.finalized = true
    eventEntity.highestTipper = event.params.highestTipper
    eventEntity.finalizedAtTimestamp = event.block.timestamp
    eventEntity.finalizedAtBlockNumber = event.block.number
    eventEntity.updatedAtTimestamp = event.block.timestamp
    eventEntity.save()
  }

  // Create log entity
  let transferredLog = new EventFinalizedAndTransferredLog(
    event.transaction.hash.toHex() + "-" + event.logIndex.toString()
  )
  transferredLog.eventId = event.params.eventId
  transferredLog.highestTipper = event.params.highestTipper
  transferredLog.timestamp = event.block.timestamp
  transferredLog.blockNumber = event.block.number
  transferredLog.transactionHash = event.transaction.hash
  transferredLog.save()

  // Update global stats
  updateGlobalStats(event.block.timestamp, event.block.number, false, true)
}

function updateGlobalStats(timestamp: BigInt, blockNumber: BigInt, isNewEvent: boolean, isFinalized: boolean): void {
  let stats = GlobalStats.load("global")
  if (!stats) {
    stats = new GlobalStats("global")
    stats.totalEvents = BigInt.fromI32(0)
    stats.totalTickets = BigInt.fromI32(0)
    stats.totalRevenue = BigInt.fromI32(0)
    stats.totalActiveEvents = BigInt.fromI32(0)
    stats.totalFinalizedEvents = BigInt.fromI32(0)
  }

  if (isNewEvent) {
    stats.totalEvents = stats.totalEvents.plus(BigInt.fromI32(1))
    stats.totalActiveEvents = stats.totalActiveEvents.plus(BigInt.fromI32(1))
  }

  if (isFinalized) {
    stats.totalActiveEvents = stats.totalActiveEvents.minus(BigInt.fromI32(1))
    stats.totalFinalizedEvents = stats.totalFinalizedEvents.plus(BigInt.fromI32(1))
  }

  stats.lastUpdatedTimestamp = timestamp
  stats.lastUpdatedBlockNumber = blockNumber
  stats.save()
} 