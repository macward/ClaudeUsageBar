import Foundation

internal enum FixtureLoader {

    internal enum FixtureError: Error {
        case missing(String)
    }

    internal static func data(named name: String) throws -> Data {
        let bundle: Bundle = Bundle(for: Marker.self)
        guard let url: URL = bundle.url(forResource: name, withExtension: "json") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    private final class Marker {}
}
