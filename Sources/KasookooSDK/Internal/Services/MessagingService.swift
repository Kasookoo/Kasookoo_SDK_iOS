//
//  MessagingService.swift
//  KasookooSDK
//
//

import Foundation

internal actor MessagingService: MessagingServicing {
    
    // MARK: - Dependencies
    
    private let apiClient: ApiClient
    private let stateStore: StateStore
    private let eventBus: EventBus
    private let logger: Logger
    private let config: KasookooConfig
    private let telemetry: TelemetryReporting
    
    /// Cached messaging tokens keyed by room name.
    private var roomTokens: [String: String] = [:]
    
    // MARK: - Init
    
    init(
        apiClient: ApiClient,
        stateStore: StateStore,
        eventBus: EventBus,
        logger: Logger,
        config: KasookooConfig,
        telemetry: TelemetryReporting = NoopTelemetry()
    ) {
        self.apiClient = apiClient
        self.stateStore = stateStore
        self.eventBus = eventBus
        self.logger = logger
        self.config = config
        self.telemetry = telemetry
    }
    
    // MARK: - MessagingServicing: connect
    
    func connect() async throws {
        guard config.features.messaging else {
            throw KasookooError.messageSendFailed(
                message: "Messaging is disabled in SDK configuration.",
                retryable: false
            )
        }
        logger.info("Messaging service ready (REST-based)")
    }
    
    // MARK: - MessagingServicing: getToken
    
    func getToken(params: MessagingTokenParams) async throws {
        try params.validate()
        
        guard config.features.messaging else {
            throw KasookooError.messageSendFailed(
                message: "Messaging is disabled.",
                retryable: false
            )
        }
        
        let request = GetMessagingTokenRequest(
            roomName: params.roomName,
            participantIdentity: params.sender.email,
            participantIdentityName: params.sender.name,
            participantIdentityType: params.sender.type.rawValue,
            sender: ParticipantDTO(from: params.sender),
            receiver: ParticipantDTO(from: params.receiver),
            deviceType: DeviceType.mobile.rawValue,
            isPushNotification: params.isPushNotification
        )
        
        let response = try await apiClient.send(
            apiRequest: MessagingRequests.getToken,
            body: request,
            responseType: GetMessagingTokenResponse.self,
            retryPolicy: .default
        )
        
        // Cache the token for later sends. The token response does not echo the
        // room name, so key the cache by the room we requested.
        if let token = response.effectiveToken {
            roomTokens[params.roomName] = token
            logger.debug("Messaging token cached for room: \(params.roomName)")
        }
    }
    
    // MARK: - MessagingServicing: send
    
    /// Instrumented entry point.
    ///
    /// `TraceContext.run` opens one feature lifecycle, so the send and every
    /// API request it makes share a single `call_trace_id`. That id also goes
    /// out as `X-Call-Trace-ID`, which is what joins this span in Tempo to the
    /// backend's own logs in Loki.
    @discardableResult
    func send(params: SendMessageParams) async throws -> Message {
        return try await TraceContext.run(.inAppMessaging) { () -> Message in
            let span = self.telemetry.startSpan(TelemetrySpan.messagingSend, attributes: [
                "room_name": .string(params.roomName),
                "message_type": .string(params.messageType.rawValue),
                "is_push_notification": .bool(params.isPushNotification)
            ])
            defer { span.end() }

            do {
                let message = try await self.performSend(params: params)
                span.setAttribute(TelemetryKey.result, .string("ok"))
                span.setAttribute("message_id", .string(message.id))
                return message
            } catch let error as KasookooError {
                span.setError(error.message)
                span.setAttribute(TelemetryKey.errorCode, .string(error.code.rawValue))
                self.telemetry.log(
                    event: TelemetryEvent.messageSendFailed,
                    message: error.message,
                    severity: .error,
                    attributes: [
                        "room_name": .string(params.roomName),
                        TelemetryKey.errorCode: .string(error.code.rawValue)
                    ]
                )
                throw error
            }
        }
    }

    private func performSend(params: SendMessageParams) async throws -> Message {
        try params.validate()
        
        guard config.features.messaging else {
            throw KasookooError.messageSendFailed(
                message: "Messaging is disabled.",
                retryable: false
            )
        }
        
        // ─── Resolve UserReference → user_id ───────────────────────────
        // Backend requires sender_user_id and receiver_user_id (not emails).
        // The StateStore cache is populated by identify() and listConversations().
        
        guard let senderUserId = await stateStore.resolveUserId(from: params.sender) else {
            throw KasookooError.messageSendFailed(
                message: "Cannot resolve sender user_id. Ensure sdk.identify() has been called.",
                retryable: false,
                details: ["sender": params.sender.value]
            )
        }
        
        guard let receiverUserId = await stateStore.resolveUserId(from: params.receiver) else {
            throw KasookooError.messageSendFailed(
                message: "Cannot resolve receiver user_id. Pass .userId(...) directly or call listConversations() first to populate the cache.",
                retryable: false,
                details: ["receiver": params.receiver.value]
            )
        }
        
        // Generate a client-side ID for log correlation
        let clientCorrelationId = UUID().uuidString
        logger.info("Sending message in room \(params.roomName) (correlation: \(clientCorrelationId))")
        
        // ─── Build server request ──────────────────────────────────────
        
        let request = SendMessageRequest(
            senderUserId: senderUserId,
            receiverUserId: receiverUserId,
            roomName: params.roomName,
            message: params.message,
            channel: "normal",
            messageType: params.messageType.rawValue,
            metadata: params.metadata,
            isPushNotification: params.isPushNotification
        )
        
        // ─── Send ──────────────────────────────────────────────────────
        
        let response: SendMessageResponse
        do {
            response = try await apiClient.send(
                apiRequest: MessagingRequests.send,
                body: request,
                responseType: SendMessageResponse.self,
                retryPolicy: .default
            )
        } catch let sdkError as KasookooError {
            logger.error("Send message failed: \(sdkError.message)")
            await emitMessageFailedEvent(
                roomName: params.roomName,
                correlationId: clientCorrelationId,
                error: sdkError
            )
            throw sdkError
        }
        
        // ─── Build final Message from response ─────────────────────────
        
        let messageId = response.effectiveMessageId ?? clientCorrelationId
        let sentDate = parseIso8601(response.effectiveTimestamp) ?? Date()
        let statusEnum = MessageStatus(rawValue: response.status ?? "") ?? .sent
        let effectiveRoom = response.roomName ?? response.conversationId ?? params.roomName
        
        let senderEmailForModel: String = {
            if case .email(let e) = params.sender { return e }
            return ""
        }()
        let receiverEmailForModel: String = {
            if case .email(let e) = params.receiver { return e }
            return ""
        }()
        
        let finalMessage = Message(
            id: messageId,
            roomName: effectiveRoom,
            senderEmail: senderEmailForModel,
            receiverEmail: receiverEmailForModel,
            content: params.message,
            messageType: params.messageType,
            mediaURL: nil,
            sentAt: sentDate,
            status: statusEnum,
            isOutgoing: true,
            conversationId: response.conversationId,
            metadata: params.metadata
        )
        
        // Emit success event
        await emitMessageEvent(
            EventName.messageSent,
            message: finalMessage,
            extra: ["correlationId": .string(clientCorrelationId)]
        )
        
        logger.info("Message sent: \(messageId)")
        return finalMessage
    }
    
    // MARK: - MessagingServicing: listConversations
    
    func listConversations(filters: ConversationFilters) async throws -> PaginatedResult<Conversation> {
        return try await TraceContext.run(.inAppMessaging) { () -> PaginatedResult<Conversation> in
            let span = self.telemetry.startSpan(TelemetrySpan.messagingSync, attributes: [
                "operation": .string("list_conversations"),
                "skip": .int(filters.skip),
                "limit": .int(filters.limit)
            ])
            defer { span.end() }

            do {
                let result = try await self.performListConversations(filters: filters)
                span.setAttribute(TelemetryKey.result, .string("ok"))
                span.setAttribute("item_count", .int(result.items.count))
                return result
            } catch let error as KasookooError {
                span.setError(error.message)
                span.setAttribute(TelemetryKey.errorCode, .string(error.code.rawValue))
                throw error
            }
        }
    }

    private func performListConversations(filters: ConversationFilters) async throws -> PaginatedResult<Conversation> {
        guard config.features.messaging else {
            throw KasookooError.messageSendFailed(
                message: "Messaging is disabled.",
                retryable: false
            )
        }
        
        guard let currentUserId = await stateStore.currentUserId else {
            throw KasookooError.messageSendFailed(
                message: "UserId is not available.",
                retryable: false
            )
        }
        
        let response = try await apiClient.send(
            apiRequest: MessagingRequests.listConversations(userId: currentUserId, skip: filters.skip, limit: filters.limit),
            responseType: ListConversationsResponse.self,
            retryPolicy: .default
        )
        
        let conversationDTOs = response.effectiveConversations
        let conversations = conversationDTOs.map { $0.toModel(currentUserId: currentUserId) }
        
        // Cache conversations + populate email→user_id mappings from participants
        for (idx, conv) in conversations.enumerated() {
            await stateStore.cacheConversation(conv)
            
            // If the DTO had aligned email/user_id arrays, cache the pairings
            let dto = conversationDTOs[idx]
            if let emails = dto.participantEmails,
               let userIds = dto.participantUserIds,
               emails.count == userIds.count {
                var mappings: [String: String] = [:]
                for (i, email) in emails.enumerated() {
                    mappings[email] = userIds[i]
                }
                await stateStore.cacheUserIds(mappings)
            }
        }
        
        return PaginatedResult(
            items: conversations,
            totalCount: response.effectiveTotal,
            hasMore: response.hasMore ?? (conversations.count >= filters.limit),
            nextCursor: response.nextCursor
        )
    }
    
    // MARK: - MessagingServicing: getMessages
    
    func getMessages(
        conversationId: String,
        paging: MessagePaging
    ) async throws -> PaginatedResult<Message> {
        return try await TraceContext.run(.inAppMessaging) { () -> PaginatedResult<Message> in
            let span = self.telemetry.startSpan(TelemetrySpan.messagingSync, attributes: [
                "operation": .string("get_messages"),
                "conversation_id": .string(conversationId),
                "skip": .int(paging.skip),
                "limit": .int(paging.limit)
            ])
            defer { span.end() }

            do {
                let result = try await self.performGetMessages(
                    conversationId: conversationId,
                    paging: paging
                )
                span.setAttribute(TelemetryKey.result, .string("ok"))
                span.setAttribute("item_count", .int(result.items.count))
                return result
            } catch let error as KasookooError {
                span.setError(error.message)
                span.setAttribute(TelemetryKey.errorCode, .string(error.code.rawValue))
                throw error
            }
        }
    }

    private func performGetMessages(
        conversationId: String,
        paging: MessagePaging
    ) async throws -> PaginatedResult<Message> {
        guard config.features.messaging else {
            throw KasookooError.messageSendFailed(
                message: "Messaging is disabled.",
                retryable: false
            )
        }
        
        guard !conversationId.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw KasookooError.configInvalid("conversationId cannot be empty")
        }
        
        guard let currentUserId = await stateStore.currentUserId else {
            throw KasookooError.messageSendFailed(
                message: "UserId is not available.",
                retryable: false
            )
        }
        
        let response = try await apiClient.send(
            apiRequest: MessagingRequests.getMessages(
                userId: currentUserId, conversationId: conversationId,
                skip: paging.skip,
                limit: paging.limit
            ),
            responseType: GetMessagesResponse.self,
            retryPolicy: .default
        )
        
        let messages = response.effectiveMessages.map { $0.toModel(currentUserId: currentUserId) }
        
        return PaginatedResult(
            items: messages,
            totalCount: response.effectiveTotal,
            hasMore: response.hasMore ?? (messages.count >= paging.limit),
            nextCursor: response.nextCursor
        )
    }
    
    // MARK: - MessagingServicing: markRead
    
    func markRead(conversationId: String, messageIds: [String]?) async throws {
        guard config.features.messaging else {
            throw KasookooError.messageSendFailed(
                message: "Messaging is disabled.",
                retryable: false
            )
        }
        
        guard !conversationId.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw KasookooError.configInvalid("conversationId cannot be empty")
        }
        
        logger.debug("Marking conversation as read: \(conversationId)")

        guard let currentUserId = await stateStore.currentUserId else {
            throw KasookooError.configInvalid(
                "Cannot mark messages as read without an identified user. Call identify() first."
            )
        }
        
        let request = MarkReadRequest(
            userId: currentUserId,
            conversationId: conversationId,
            messageIds: messageIds
        )
        
        let response = try await apiClient.send(
            apiRequest: MessagingRequests.markRead,
            body: request,
            responseType: MarkReadResponse.self,
            retryPolicy: .default
        )
        
        // Emit message.read event
        let event = SDKEvent(
            name: EventName.messageRead,
            organizationId: config.organizationId,
            userEmail: await stateStore.currentUserEmail(),
            data: [
                "conversationId": .string(conversationId),
                "markedCount": .int(response.messagesMarkedRead ?? 0)
            ]
        )
        await eventBus.emit(event)
    }
    
    // MARK: - MessagingServicing: getUnreadCount
    
    func getUnreadCount() async throws -> Int {
        guard config.features.messaging else {
            return 0
        }
        
        let response = try await apiClient.send(
            apiRequest: MessagingRequests.unreadCount,
            responseType: UnreadCountResponse.self,
            retryPolicy: .default
        )
        
        return response.effectiveCount
    }
    
    // MARK: - Private Helpers
    
    private func emitMessageEvent(
        _ name: String,
        message: Message,
        extra: [String: AnyCodableValue] = [:]
    ) async {
        var data: [String: AnyCodableValue] = [
            "messageId": .string(message.id),
            "roomName": .string(message.roomName),
            "senderEmail": .string(message.senderEmail),
            "receiverEmail": .string(message.receiverEmail),
            "messageType": .string(message.messageType.rawValue),
            "status": .string(message.status.rawValue),
            "sentAt": .string(ISO8601DateFormatter().string(from: message.sentAt))
        ]
        for (key, value) in extra {
            data[key] = value
        }
        
        let event = SDKEvent(
            name: name,
            organizationId: config.organizationId,
            userEmail: await stateStore.currentUserEmail(),
            data: data
        )
        await eventBus.emit(event)
    }
    
    private func emitMessageFailedEvent(
        roomName: String,
        correlationId: String,
        error: KasookooError
    ) async {
        let event = SDKEvent(
            name: EventName.messageSent,
            organizationId: config.organizationId,
            userEmail: await stateStore.currentUserEmail(),
            data: [
                "roomName": .string(roomName),
                "correlationId": .string(correlationId),
                "status": .string("failed"),
                "errorCode": .string(error.code.rawValue),
                "errorMessage": .string(error.message)
            ]
        )
        await eventBus.emit(event)
    }
    
    private func parseIso8601(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
