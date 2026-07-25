import Foundation

/// Maps the device's clock onto **station time** — the clock the station's
/// schedule is expressed in.
///
/// "Everyone hears the same second" is a claim about a *shared* timeline, and
/// a phone's own clock is not it: devices drift, users set the time by hand,
/// and a carrier-synced phone can still sit a second or two off. So the server
/// stamps every schedule message with its own clock, and this type turns those
/// stamps into an offset we can add to `Date()`.
///
/// The estimate is the standard round-trip one (NTP's, minus the discipline
/// loop): ask at `sentAt`, hear back at `receivedAt`, and assume the reply
/// spent half the round trip in flight, so the server's stamp describes an
/// instant `roundTrip / 2` before the reply landed.
///
///     offset = stationTime - receivedAt + roundTrip / 2
///
/// Latency is only *roughly* symmetric, so the error is bounded by half the
/// round trip — a few tens of milliseconds on a decent connection, which is
/// far below the threshold where a listener would notice two cars playing the
/// same track out of step. To keep that bound tight we hold the lowest-latency
/// sample seen in a sliding window rather than the most recent one: a sample
/// that queued behind a slow radio wake-up is exactly the one whose symmetry
/// assumption is worst.
///
/// A `StationClock` that has never been fed a sample is the identity map — the
/// device clock *is* station time. That's the honest local-only behaviour, and
/// it means nothing has to special-case "not synced yet".
public struct StationClock: Sendable, Equatable {

    /// One round trip against the station's clock.
    public struct Sample: Sendable, Equatable {
        /// The server's own clock at the moment it stamped the reply.
        public let stationTime: Date
        /// Device clock when we sent the request.
        public let sentAt: Date
        /// Device clock when the reply landed.
        public let receivedAt: Date

        public init(stationTime: Date, sentAt: Date, receivedAt: Date) {
            self.stationTime = stationTime
            self.sentAt = sentAt
            self.receivedAt = receivedAt
        }

        public var roundTripSeconds: Double {
            max(0, receivedAt.timeIntervalSince(sentAt))
        }

        /// Seconds to add to a device timestamp to get station time.
        public var offset: TimeInterval {
            stationTime.timeIntervalSince(receivedAt) + roundTripSeconds / 2
        }
    }

    public struct Config: Sendable, Equatable {
        /// How long a sample stays authoritative. Past this we take whatever
        /// the next sample says, however slow the round trip — a stale offset
        /// measured on a good connection is worse than a fresh mediocre one.
        public var sampleLifetimeSeconds: Double
        /// Round trips longer than this are never allowed to displace a
        /// usable sample: half of a four-second round trip is two seconds of
        /// potential error, which is audible.
        public var maxAcceptableRoundTripSeconds: Double

        public init(
            sampleLifetimeSeconds: Double = 60 * 5,
            maxAcceptableRoundTripSeconds: Double = 4
        ) {
            self.sampleLifetimeSeconds = sampleLifetimeSeconds
            self.maxAcceptableRoundTripSeconds = maxAcceptableRoundTripSeconds
        }
    }

    public let config: Config

    /// Seconds to add to device time to get station time. Zero until synced.
    public private(set) var offset: TimeInterval = 0
    /// Round trip of the sample the current offset came from.
    public private(set) var roundTripSeconds: Double?
    /// Device time at which the current sample landed.
    public private(set) var syncedAt: Date?

    public init(config: Config = Config()) {
        self.config = config
    }

    /// True once a server stamp has been accepted. Before that this clock is
    /// the identity map and the station is running on local time.
    public var isSynchronized: Bool { syncedAt != nil }

    /// Whether the accepted sample has aged out at `deviceNow`.
    public func isStale(at deviceNow: Date) -> Bool {
        guard let syncedAt else { return true }
        return deviceNow.timeIntervalSince(syncedAt) > config.sampleLifetimeSeconds
    }

    /// Fold in a round trip. Returns whether it displaced the current offset.
    @discardableResult
    public mutating func ingest(_ sample: Sample) -> Bool {
        // A reply that arrived before we sent it means the device clock was
        // changed mid-flight; the round trip is meaningless, so drop it.
        guard sample.receivedAt >= sample.sentAt else { return false }

        let roundTrip = sample.roundTripSeconds
        let haveUsableSample = isSynchronized && !isStale(at: sample.receivedAt)

        if haveUsableSample {
            guard roundTrip <= config.maxAcceptableRoundTripSeconds else { return false }
            // Keep the best sample of the window: a slower round trip has a
            // wider error bar, so it tells us less than what we already hold.
            if let best = roundTripSeconds, roundTrip > best { return false }
        }

        offset = sample.offset
        roundTripSeconds = roundTrip
        syncedAt = sample.receivedAt
        return true
    }

    /// Station time for a device timestamp.
    public func stationTime(forDevice deviceNow: Date) -> Date {
        deviceNow.addingTimeInterval(offset)
    }

    /// Device time for a station timestamp — the inverse, and the one the
    /// player needs: `AVPlayer` seeks and Now Playing elapsed times are all
    /// quoted against the device clock.
    public func deviceTime(forStation stationNow: Date) -> Date {
        stationNow.addingTimeInterval(-offset)
    }

    /// Drop the offset and fall back to local time (e.g. after signing out of
    /// a server, so a stale offset can't outlive the connection it came from).
    public mutating func reset() {
        offset = 0
        roundTripSeconds = nil
        syncedAt = nil
    }
}
