import Foundation
import Testing
@testable import InfluxKit

/// A Mac and a phone on one stand-in iCloud.
private struct Pair {
    let clock = SimClock()
    let mac: SimDevice
    let phone: SimDevice

    init() throws {
        let server = InMemorySyncServer()
        mac = try SimDevice("mac", server: server, clock: clock)
        phone = try SimDevice("phone", server: server, clock: clock)
    }

    /// Both devices open on the same posts, with nothing read yet: at
    /// the newest of them, as a timeline with no place or marker does.
    func open(_ minutes: Range<Int>) async throws {
        try await mac.fetch(minutes)
        try await phone.fetch(minutes)
    }

    func place(on device: SimDevice) async throws -> String? {
        try await device.storedPlace()?.mergeKey
    }
}

/// The reading place between two devices, each past problem as the script
/// that used to go wrong. These run the rules the app's timeline runs.
@Suite struct PlaceBetweenDevices {
    @Test func openDevicesFollowEachOther() async throws {
        let pair = try Pair()
        try await pair.open(0..<20)

        pair.clock.advance(by: 5)
        pair.mac.scroll(to: 8)
        try await pair.mac.pause()
        try await pair.mac.sync()
        try await pair.phone.sync()
        #expect(pair.phone.screen.topKey == "post:008")

        // And back up, from the place itself: the reader had seen it, so
        // going back on purpose takes the other device too.
        pair.clock.advance(by: 5)
        pair.phone.scroll(to: 3)
        try await pair.phone.pause()
        try await pair.phone.sync()
        try await pair.mac.sync()
        #expect(pair.mac.screen.topKey == "post:003")
        #expect(try await pair.mac.storedPlace()?.move == 2)

        // Following is not the reader's move: each device saved only its own.
        #expect(pair.mac.saves.map(\.place.mergeKey) == ["post:008"])
        #expect(pair.phone.saves.map(\.place.mergeKey) == ["post:003"])
    }

    /// influx-dev #39: holding the top row as rows arrive counted as the
    /// reader's move, and sent the old place over a newer one.
    @Test func rowsArrivingAreNotTheReadersMove() async throws {
        let pair = try Pair()
        try await pair.mac.fetch(0..<30)
        try await pair.phone.fetch(10..<30)

        pair.clock.advance(by: 5)
        pair.mac.scroll(to: 20)
        try await pair.mac.pause()
        try await pair.mac.sync()
        try await pair.phone.sync()
        #expect(pair.phone.screen.topKey == "post:020")

        // Older posts arrive above the phone's screen, and it holds its row.
        try await pair.phone.fetch(0..<10)
        try await pair.phone.pause()
        #expect(pair.phone.screen.topKey == "post:020")
        #expect(pair.phone.screen.rows.count == 30)
        #expect(pair.phone.saves.isEmpty)
    }

    /// influx-dev #119, #135: a place naming a post this device hasn't
    /// fetched goes to the row nearest it, and on to its own row once the
    /// post arrives.
    @Test func aPlaceWhosePostIsNotHereYetIsReachedWhenItArrives() async throws {
        let pair = try Pair()
        try await pair.mac.fetch(0..<30)
        try await pair.phone.fetch(0..<10)

        pair.clock.advance(by: 5)
        pair.mac.scroll(to: 20)
        try await pair.mac.pause()
        try await pair.mac.sync()
        try await pair.phone.sync()
        // The newest rows the phone has stand in, and it waits for the rest.
        #expect(pair.phone.screen.topKey == "post:005")
        #expect(pair.phone.tracker.waitsForPosts)

        try await pair.phone.fetch(10..<30)
        #expect(pair.phone.screen.topKey == "post:020")
        #expect(!pair.phone.tracker.waitsForPosts)
        #expect(pair.phone.saves.isEmpty)
        #expect(try await pair.place(on: pair.phone) == "post:020")
    }

    /// influx-dev #39, #106, #125: a scroll on a device still showing an
    /// old place used to take every other device back to it, because the
    /// newest move won by the clock. It now stays on that device, which is
    /// taken to the place the reader had really reached.
    @Test func aScrollFromAnOldPlaceDoesNotTakeOtherDevicesBack() async throws {
        let pair = try Pair()
        try await pair.open(0..<20)

        pair.clock.advance(by: 5)
        pair.mac.scroll(to: 12)
        try await pair.mac.pause()
        try await pair.mac.sync()

        // The phone hasn't synced: it still shows where both began. The
        // reader scrolls it before the Mac's place has arrived.
        pair.clock.advance(by: 5)
        pair.phone.scroll(to: 3)
        try await pair.phone.pause()
        try await pair.phone.sync()
        try await pair.mac.sync()

        #expect(pair.mac.screen.topKey == "post:012")
        #expect(pair.phone.screen.topKey == "post:012")
        #expect(try await pair.place(on: pair.phone) == "post:012")

        // Now that the phone has shown that place, going back from it is
        // the reader's choice, and goes to the Mac.
        pair.clock.advance(by: 5)
        pair.phone.scroll(to: 3)
        try await pair.phone.pause()
        try await pair.phone.sync()
        try await pair.mac.sync()
        #expect(pair.mac.screen.topKey == "post:003")
    }

    /// The other half of the rule: reading on past a place this device
    /// hadn't seen stands, since the reader is further along than it.
    @Test func readingOnPastAPlaceNotYetSeenStands() async throws {
        let pair = try Pair()
        try await pair.open(0..<30)
        pair.clock.advance(by: 5)
        pair.mac.scroll(to: 5)
        try await pair.mac.pause()
        try await pair.mac.sync()
        try await pair.phone.sync()
        #expect(pair.phone.screen.topKey == "post:005")

        pair.clock.advance(by: 5)
        pair.mac.scroll(to: 12)
        try await pair.mac.pause()
        try await pair.mac.sync()

        // The phone, not yet synced, is read on to beyond it.
        pair.clock.advance(by: 5)
        pair.phone.scroll(to: 20)
        try await pair.phone.pause()
        try await pair.phone.sync()
        try await pair.mac.sync()
        #expect(pair.phone.screen.topKey == "post:020")
        #expect(pair.mac.screen.topKey == "post:020")
        // The move after the Mac's, which it was made without knowing of.
        #expect(try await pair.mac.storedPlace()?.move == 3)
    }

    /// A phone off the network for a while saves many moves, one a pause.
    /// However many, they don't undo reading on that happened elsewhere
    /// without knowing of them.
    @Test func manyMovesOffTheNetworkDoNotUndoReadingOnElsewhere() async throws {
        let pair = try Pair()
        try await pair.open(0..<30)
        pair.clock.advance(by: 5)
        pair.mac.scroll(to: 5)
        try await pair.mac.pause()
        try await pair.mac.sync()
        try await pair.phone.sync()

        for row in [8, 7, 6] {
            pair.clock.advance(by: 5)
            pair.phone.scroll(to: row)
            try await pair.phone.pause()
        }
        #expect(try await pair.phone.storedPlace()?.move == 4)

        pair.clock.advance(by: 5)
        pair.mac.scroll(to: 15)
        try await pair.mac.pause()
        try await pair.mac.sync()

        try await pair.phone.sync()
        try await pair.mac.sync()
        #expect(pair.mac.screen.topKey == "post:015")
        #expect(pair.phone.screen.topKey == "post:015")
    }

    /// A place that arrives mid-scroll isn't followed while the reader is
    /// moving. Where they stop is weighed against it: short of it, and
    /// without having seen it, they are taken to it.
    @Test func aPlaceArrivingMidScrollIsWhereTheReaderEndsUpUnlessTheyPassIt() async throws {
        let pair = try Pair()
        try await pair.open(0..<20)

        pair.clock.advance(by: 5)
        pair.mac.scroll(to: 12)
        try await pair.mac.pause()
        try await pair.mac.sync()

        pair.clock.advance(by: 5)
        try await pair.phone.scrollThroughSync(to: 3)
        #expect(pair.phone.screen.topKey == "post:003")
        try await pair.phone.pause()
        #expect(pair.phone.screen.topKey == "post:012")
        #expect(pair.phone.saves.isEmpty)
        #expect(pair.phone.notes.contains { $0.contains("stays on this device") })

        try await pair.phone.sync()
        try await pair.mac.sync()
        #expect(pair.mac.screen.topKey == "post:012")
    }

    /// influx-dev #125, #141: the place is saved and sent as the app is put
    /// away, without waiting for the pause.
    @Test func aPlaceSavedOnLeavingReachesTheOtherDevice() async throws {
        let pair = try Pair()
        try await pair.open(0..<20)

        pair.clock.advance(by: 5)
        pair.phone.scroll(to: 6)
        try await pair.phone.putAway()
        try await pair.mac.sync()
        #expect(pair.mac.screen.topKey == "post:006")
    }

    /// influx-dev #131: a device with fewer posts, at the bottom of what
    /// it has, can't take a device that has read beyond them back. It
    /// hasn't reached the place, so its moves stay its own until it has.
    @Test func aDeviceWithFewerPostsCannotTakeOneWithMoreBack() async throws {
        let pair = try Pair()
        try await pair.open(0..<10)
        pair.clock.advance(by: 5)
        pair.phone.scroll(to: 2)
        try await pair.phone.pause()
        try await pair.phone.sync()
        try await pair.mac.sync()
        #expect(pair.mac.screen.topKey == "post:002")

        // The Mac fetches twenty more posts, and the reader reads on there.
        try await pair.mac.fetch(10..<30)
        pair.clock.advance(by: 5)
        pair.mac.scroll(to: 20)
        try await pair.mac.pause()
        try await pair.mac.sync()

        // The phone, not yet synced, is read to the bottom of what it has.
        pair.clock.advance(by: 5)
        pair.phone.scroll(to: 5)
        try await pair.phone.pause()
        try await pair.phone.sync()
        try await pair.mac.sync()
        #expect(pair.mac.screen.topKey == "post:020")
        #expect(try await pair.place(on: pair.phone) == "post:020")
        // The Mac saved its one move, and nothing to put it back.
        #expect(pair.mac.saves.count == 1)

        // The phone's newest rows stand in for a place it hasn't reached.
        // Scrolling about there changes nothing anywhere else, and it isn't
        // pulled back to the bottom each time it stops.
        pair.clock.advance(by: 5)
        pair.phone.scroll(to: 1)
        try await pair.phone.pause()
        #expect(pair.phone.screen.topKey == "post:001")
        try await pair.phone.sync()
        try await pair.mac.sync()
        #expect(pair.mac.screen.topKey == "post:020")

        // Opened again with the posts fetched, it is on the place.
        try await pair.phone.fetch(10..<30)
        try await pair.phone.relaunch()
        #expect(pair.phone.screen.topKey == "post:020")
    }

    /// A device opened after another moved opens on that place, and a
    /// place that arrives before its first rows is the one it opens on.
    @Test func aDeviceOpensOnThePlaceSetElsewhere() async throws {
        let pair = try Pair()
        try await pair.mac.fetch(0..<20)
        pair.clock.advance(by: 5)
        pair.mac.scroll(to: 9)
        try await pair.mac.pause()
        try await pair.mac.sync()

        // The phone syncs before it has shown anything.
        try await pair.phone.sync()
        try await pair.phone.fetch(0..<20)
        #expect(pair.phone.screen.topKey == "post:009")
        #expect(pair.phone.saves.isEmpty)

        // Quit and started again, it opens where it was.
        try await pair.phone.relaunch()
        #expect(pair.phone.screen.topKey == "post:009")
        #expect(pair.phone.saves.isEmpty)
    }
}

/// Devices with different posts, doing things in a random order: whatever
/// the order, they must end up agreeing.
private struct Simulation {
    static let universe = 40

    let clock = SimClock()
    var devices: [SimDevice] = []
    /// For each device: how far its fetch has reached, and the posts it
    /// never gets.
    var reached: [Int] = []
    var missing: [Set<Int>] = []
    var random: SimRandom
    /// Whether posts fetched after the first are placed as the app places
    /// late arrivals, below the newest row a device already has.
    var lateArrivals = false
    /// What happened, for a failure's message.
    var log: [String] = []

    init(seed: UInt64, devices count: Int) throws {
        random = SimRandom(seed: seed)
        let server = InMemorySyncServer()
        for index in 0..<count {
            devices.append(try SimDevice("device \(index)", server: server, clock: clock))
            reached.append(Int.random(in: 8...20, using: &random))
            missing.append(Set((0..<Self.universe).filter { _ in Int.random(in: 0..<10, using: &random) == 0 }))
        }
    }

    /// The posts a device's fetch brings when it reaches from `from` on.
    func posts(of index: Int, from: Int = 0) -> [Int] {
        (from..<reached[index]).filter { !missing[index].contains($0) }
    }

    mutating func run(steps: Int) async throws {
        for index in devices.indices {
            try await devices[index].fetch(posts(of: index))
        }
        for _ in 0..<steps {
            clock.advance(by: Double(Int.random(in: 1...50, using: &random)) / 10)
            let index = Int.random(in: devices.indices, using: &random)
            let device = devices[index]
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<30:
                let to = device.screen.top + Int.random(in: -3...6, using: &random)
                let pause = Int.random(in: 0..<10, using: &random)
                if pause < 2 {
                    try await device.scrollThroughSync(to: to)
                    log.append("\(device.name) scrolls to \(device.screen.topKey ?? "nothing") as a sync lands")
                } else {
                    device.scroll(to: to)
                    log.append("\(device.name) scrolls to \(device.screen.topKey ?? "nothing")")
                }
                if pause < 7 { try await device.pause() }
            case 30..<45:
                let from = reached[index]
                reached[index] = min(Self.universe, from + Int.random(in: 1...8, using: &random))
                try await device.fetch(posts(of: index, from: from), belowTheLine: lateArrivals)
                log.append("\(device.name) fetches up to \(reached[index])")
            case 45..<70:
                try await device.sync()
                log.append("\(device.name) syncs, now on \(device.screen.topKey ?? "nothing")")
            case 70..<76:
                try await device.putAway(sending: Bool.random(using: &random))
                log.append("\(device.name) is put away")
            case 76..<87:
                try await device.relaunch()
                log.append("\(device.name) starts again, on \(device.screen.topKey ?? "nothing")")
            case 87..<93:
                device.jump(to: device.screen.rows.count)
                log.append("\(device.name) jumps to the newest")
                if Int.random(in: 0..<10, using: &random) < 7 { try await device.pause() }
            default:
                try await device.pause()
                log.append("\(device.name) pauses")
            }
        }
    }

    /// The reader puts every device down, and sync runs until nothing more
    /// changes hands.
    func settle() async throws {
        for device in devices {
            clock.advance(by: 1)
            try await device.pause()
        }
        var quiet = 0
        for _ in 0..<12 where quiet < 2 {
            var busy = false
            for device in devices {
                let saved = device.saves.count
                try await device.sync()
                if device.saves.count != saved { busy = true }
                if try await device.hasUnsent() { busy = true }
            }
            quiet = busy ? 0 : quiet + 1
        }
        #expect(quiet == 2, "sync never settled")
    }
}

/// One run at a time: together they would take every core, and the tests
/// elsewhere that time something would fail for it.
@Suite(.serialized) struct PlaceSimulations {
    /// Thirty orderings on every run of the tests. For more, set
    /// `INFLUX_SIMULATION_SEEDS` to how many: a run that fails names its
    /// seed, and the same seed always gives the same run.
    static let seeds: ClosedRange<Int> = 1...max(1, ProcessInfo.processInfo.environment["INFLUX_SIMULATION_SEEDS"].flatMap(Int.init) ?? 30)

    @Test(arguments: seeds)
    func devicesEndUpAgreeing(seed: Int) async throws {
        try await check(seed: seed, lateArrivals: false)
    }

    /// The same, with posts that arrive after the first placed as the app
    /// places them: never above what a device's reader has read or has on
    /// the screen, so devices order the same posts differently until
    /// their positions sync.
    @Test(arguments: seeds)
    func devicesWithLateArrivalsEndUpAgreeing(seed: Int) async throws {
        try await check(seed: seed, lateArrivals: true)
    }

    private func check(seed: Int, lateArrivals: Bool) async throws {
        var simulation = try Simulation(seed: UInt64(seed), devices: seed % 3 == 0 ? 3 : 2)
        simulation.lateArrivals = lateArrivals
        try await simulation.run(steps: 60)
        try await simulation.settle()
        let story = simulation.log.suffix(25).joined(separator: "\n")

        // Every device's store holds the same place.
        var places: [ReadingPlace?] = []
        for device in simulation.devices {
            places.append(try await device.storedPlace())
        }
        #expect(Set(places.map { $0?.identity }).count == 1,
                "seed \(seed): stores disagree: \(places.map { $0.map { "\($0.mergeKey) move \($0.move)" } ?? "none" })\n\(story)")

        for device in simulation.devices {
            // Only the reader moves the place: a device saves one for a
            // move of theirs, and for nothing else.
            #expect(device.saves.count <= device.readerMoves,
                    "seed \(seed): \(device.name) saved \(device.saves.count) places for \(device.readerMoves) moves\n\(story)")

            // Every screen is on the agreed place: its own row, or the row
            // standing in for it on a device that doesn't have it. Not a
            // device whose reader last moved it somewhere the rule kept to
            // that device.
            guard device.isOpen, !device.readsApart, let place = places[0],
                  let index = ReadingPosition.row(at: place, in: device.screen.rows) else { continue }
            #expect(device.screen.top == device.screen.clamp(index),
                    "seed \(seed): \(device.name) is on \(device.screen.topKey ?? "nothing"), the place is \(place.mergeKey)\n\(story)")
        }

        // Reading on is never undone by a device that hadn't seen it: if
        // the place ended behind the furthest the reader got on any
        // device, a move made knowing the place before it came later.
        let moves = simulation.devices.flatMap { device in
            zip(device.saves, device.outcomes).compactMap { save, outcome -> (minute: Int, at: Date, knowing: Bool)? in
                guard case .moved(let place) = outcome, let minute = Int(place.mergeKey.dropFirst(5)) else { return nil }
                return (minute, place.updatedAt, save.knowing != .seen(nil))
            }
        }
        if let furthest = moves.max(by: { $0.minute < $1.minute }), let place = places[0],
           let ended = Int(place.mergeKey.dropFirst(5)), ended < furthest.minute {
            #expect(moves.contains { $0.knowing && $0.at > furthest.at },
                    "seed \(seed): the place ended on \(place.mergeKey), behind post \(furthest.minute), with no move made knowing it\n\(story)")
        }
    }
}
