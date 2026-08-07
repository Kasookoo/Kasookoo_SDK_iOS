# Kasookoo SDK for iOS

A native iOS communications toolkit that adds voice calling, telephone network calling, and messaging to an application through a single Swift package. The SDK handles media transport, session lifecycle, device registration, native call presentation, and backend communication, and exposes them through a small, well organized interface. It ships without any interface of its own, so your application keeps full control of its branding and user experience.

## Features

* **Voice calling.** Live audio sessions between two participants over WebRTC.
* **Telephone calling (SIP).** Place outbound calls to any standard phone number over the telephone network, with caller id control, optional call recording, and full call lifecycle tracking.
* **Messaging.** Conversations, history, sending, read state, and unread counts.
* **In call controls.** Mute and unmute the microphone, switch between loudspeaker and earpiece, and send DTMF tones to navigate interactive voice menus.
* **Incoming calls.** Device registration and native call presentation through CallKit, so calls arrive even in the background.
* **Multitenant.** A single integration serves many organizations, with features governed per organization by the backend.
* **Modern concurrency.** Built with Swift actors and strict Sendable checking for safety by construction.

## Requirements

| Requirement | Detail |
|---|---|
| Platform | iOS 15.0 or later |
| Language | Swift |
| Tooling | A current version of Xcode with the Swift 5.9 tools or later |
| Distribution | Swift Package Manager |
| Credentials | A publishable key and organization id from Kasookoo |

## Installation

### Swift Package Manager (Xcode)

1. In Xcode, choose **File, then Add Package Dependencies**.
2. Enter the repository URL:

   ```
   https://github.com/Kasookoo/Kasookoo_SDK_iOS.git
   ```

3. Choose a version rule, for example **Up to Next Major** from `0.9.0`.
4. Add the **KasookooSDK** library product to your app target.

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/Kasookoo/Kasookoo_SDK_iOS", from: "0.9.0")
]
```

Then add `KasookooSDK` to your target's dependencies.

## Capabilities

The SDK relies on capabilities that your app target must declare:

* A microphone usage description (voice and telephone calls capture audio).
* The Push Notifications capability (incoming calls and events).
* The Audio and Voice over IP background modes (receiving calls in the background).

## Quick Start

```swift
import KasookooSDK

let sdk = KasookooSDK()

// 1. Configure
let config = KasookooConfig(
    publishableKey: "your_publishable_key",
    organizationId: "your_organization_id",
    environment: .production
)

// 2. Initialize and connect
try await sdk.initialize(config: config)
try await sdk.connect()

// 3. Identify the current user
let profile = CallerProfile(
    name: "Alex Rivera",
    email: "alex@example.com",
    phoneNumber: "+10000000000",
    type: .customer
)
try await sdk.identify(callerProfile: profile)

// 4. Use a feature
let message = try await sdk.messaging.send(
    params: SendMessageParams(
        roomName: "room_alex_sam",
        sender: .email("alex@example.com"),
        receiver: .email("sam@example.com"),
        message: "Hello from the SDK",
        messageType: .text,
        isPushNotification: true
    )
)
```

### Placing a telephone call (SIP)

Dial a standard phone number over the telephone network. The call is returned as
a `CallInfo` you can track, and ended with `endCall`.

```swift
let call = try await sdk.sip.dial(
    params: SipDialParams(
        destinationNumber: "+441234567890",
        caller: Participant(
            name: "Alex Rivera",
            email: "alex@example.com",
            phoneNumber: "+10000000000",
            type: .agent
        ),
        callerIdNumber: "+441111111111",
        isCallRecording: false
    )
)

// in call controls
try await sdk.sip.setMuted(true, callId: call.id)           // mute
try await sdk.sip.setMuted(false, callId: call.id)          // unmute
try await sdk.sip.setSpeakerEnabled(true, callId: call.id)  // loudspeaker
try await sdk.sip.sendDTMF("1", callId: call.id)            // navigate an IVR menu

// end the call
try await sdk.sip.endCall(callId: call.id)
```

Application to application audio calls use `sdk.call` in a similar way. See the
feature guides for the full parameters and call controls.

### Observing events

```swift
let token = sdk.on(EventName.callIncoming) { event in
    // update your interface for an incoming call
}
```

The same events are also available as a Combine publisher through `sdk.events`.

## Documentation

Full guides are available for installation, integration, authentication, and each feature. Start with the Quick Start Guide, then the Integration Guide for wiring the SDK into a host application.

## Versioning

This SDK follows semantic versioning. Releases in the `0.x` range indicate that the public interface is still stabilizing and may change between minor versions. The interface will be declared stable at `1.0.0`.

## License

This SDK is commercial software licensed by Kasookoo. Use is permitted only under a valid license agreement with Kasookoo. See the [LICENSE](LICENSE) file for terms. For licensing enquiries, contact Kasookoo.

## Support

For access, credentials, and support, contact Kasookoo.
