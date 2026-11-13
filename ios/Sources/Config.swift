import Foundation

enum Config {
    static let synchub = "https://salon-sync-kappa.vercel.app"
    static let treatwell = "https://connect.treatwell.co.uk/"
    static let version = "ios-0.1.0"
    static let pollSeconds: UInt64 = 5
    // One browser identity for both the login page and the background requests, so Treatwell sees the same device.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}
