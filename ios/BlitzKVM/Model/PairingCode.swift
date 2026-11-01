import ApprovalKit

/// Finds a pairing invite in what was scanned, pasted or opened as a link:
/// `blitzkvm-pair:<b64>`, also inside other text.
enum PairingCode {
    static func invite(from text: String) -> PairingInvite? {
        guard let range = text.range(of: PairingInvite.scheme, options: .caseInsensitive) else { return nil }
        let rest = text[range.upperBound...].drop { $0 == "/" }
        let code = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return PairingInvite(qrString: PairingInvite.scheme + code)
    }
}
