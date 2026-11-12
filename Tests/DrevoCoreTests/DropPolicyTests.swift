import Foundation
import Testing
@testable import DrevoCore

@Test func finderDragSemantics() {
    #expect(DropPolicy.kind(sourceVolume: 1, destinationVolume: 1, optionKey: false, commandKey: false) == .move)
    #expect(DropPolicy.kind(sourceVolume: 1, destinationVolume: 2, optionKey: false, commandKey: false) == .copy)
    #expect(DropPolicy.kind(sourceVolume: 1, destinationVolume: 1, optionKey: true, commandKey: false) == .copy)
    #expect(DropPolicy.kind(sourceVolume: 1, destinationVolume: 2, optionKey: false, commandKey: true) == .move)
    #expect(DropPolicy.kind(sourceVolume: nil, destinationVolume: 2, optionKey: false, commandKey: false) == .copy)
}

@Test func sameVolumeOnDisk() {
    let tmp = TempDir()
    let a = tmp.file("a.txt")
    let dest = tmp.dir("dest")
    #expect(DropPolicy.kind(sources: [a], destination: dest, optionKey: false, commandKey: false) == .move)
    #expect(DropPolicy.kind(sources: [a], destination: dest, optionKey: true, commandKey: false) == .copy)
}
