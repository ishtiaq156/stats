import Foundation

@main
struct BonjourRetryTests {
    static func main() {
        var backoff = BonjourRetryBackoff()
        let expected: [TimeInterval] = [5, 10, 20, 40, 60, 60]
        for delay in expected {
            precondition(backoff.afterFailure() == delay, "Incorrect Bonjour retry delay: \(delay)")
        }
        backoff.reset()
        precondition(backoff.afterFailure() == 5, "Successful publication must reset the retry interval")
        print("Bonjour retry backoff: 7 checks passed")
    }
}
