import Foundation

public enum KiesHTTP {
    public static let session: URLSession = {
        let delegate = SelfSignedDelegate()
        return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }()
}

private final class SelfSignedDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if DEBUG
        if (challenge.protectionSpace.host.hasSuffix(".ts.net") || challenge.protectionSpace.host.hasPrefix("100.") || challenge.protectionSpace.host.hasPrefix("192.168.")),
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }
}
