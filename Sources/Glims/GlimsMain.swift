import Foundation
import GlimsKit

@main
@MainActor
enum GlimsMain {
    static func main() {
        exit(GlimsApplication.run(arguments: CommandLine.arguments))
    }
}
