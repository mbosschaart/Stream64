import Foundation

struct UltimateMenuScreen: Equatable, Sendable {
    static let columns = 40
    static let rows = 25
    static let planeSize = columns * rows

    let characters: [UInt8]
    let colors: [UInt8]

    static let blank = UltimateMenuScreen(
        characters: [UInt8](
            repeating: 0x20, count: planeSize),
        colors: [UInt8](
            repeating: 0x0F, count: planeSize))

    init(characters: [UInt8], colors: [UInt8]) {
        self.characters = characters
        self.colors = colors
    }

    init(data: Data) throws {
        guard data.count == Self.planeSize * 2 else {
            throw UltimateAPIClient.APIError.httpError(
                200,
                "menu_screen returned \(data.count) bytes; expected 2000")
        }
        characters = Array(data.prefix(Self.planeSize))
        colors = Array(data.suffix(Self.planeSize))
    }

    func character(at column: Int, row: Int) -> UInt8 {
        characters[row * Self.columns + column]
    }

    func color(at column: Int, row: Int) -> UInt8 {
        colors[row * Self.columns + column]
    }
}
