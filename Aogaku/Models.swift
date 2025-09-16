import Foundation

public struct UserPublic: Identifiable, Equatable {
    public let uid: String
    public let idString: String
    public let name: String
    public let photoURL: String?
    public var id: String { uid }
}

public struct FriendRequest: Identifiable, Equatable {
    public let fromUid: String
    public let fromName: String
    public let fromId: String
    public let createdAt: Date
    public var id: String { fromUid }
}

public struct Friend: Identifiable, Equatable {
    public let friendUid: String
    public let friendName: String
    public let friendId: String
    public let createdAt: Date
    public var id: String { friendUid }
}
