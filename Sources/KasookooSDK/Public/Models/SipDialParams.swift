//
//  SipDialParams.swift
//  KasookooSDK
//
//  Parameters for SIP calling operations.
//

import Foundation

/// Parameters for `sdk.sip.dial(params:)`.
///
/// SIP calls connect to PSTN networks (regular phone numbers).
public struct SipDialParams: Sendable, Hashable {
    
    /// The destination phone number in E.164 format (e.g., "+447700900111").
    public let destinationNumber: String
    
    /// The caller's identity (initiating the SIP call).
    public let caller: Participant
    
    /// Optional caller ID to display to the recipient.
    /// Falls back to the SIP trunk's default if nil.
    public let callerIdNumber: String?
    
    /// Optional room name to associate this SIP call with.
    /// If nil, the SDK will generate one.
    public let roomName: String?
    
    /// Whether to record the call. Defaults to `false`.
    public let isCallRecording: Bool
    
    public init(
        destinationNumber: String,
        caller: Participant,
        callerIdNumber: String? = nil,
        roomName: String? = nil,
        isCallRecording: Bool = false
    ) {
        self.destinationNumber = destinationNumber
        self.caller = caller
        self.callerIdNumber = callerIdNumber
        self.roomName = roomName
        self.isCallRecording = isCallRecording
    }
    
    public func validate() throws {
        var errors: [String: String] = [:]
        
        let trimmedDest = destinationNumber.trimmingCharacters(in: .whitespaces)
        if trimmedDest.isEmpty {
            errors["destinationNumber"] = "destinationNumber cannot be empty"
        } else if !trimmedDest.hasPrefix("+") {
            errors["destinationNumber"] = "destinationNumber must be in E.164 format (start with +)"
        }
        
        do { try caller.validate() } catch let e as KasookooError {
            errors["caller"] = e.message
        }
        
        if !errors.isEmpty {
            throw KasookooError.configInvalid(
                "Invalid SIP dial parameters.",
                details: errors
            )
        }
    }
}
