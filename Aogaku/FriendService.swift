import Foundation
import FirebaseAuth
import FirebaseFirestore

final class FriendService {
    static let shared = FriendService()
    private let db = Firestore.firestore()

    private var meUid: String {
        guard let uid = Auth.auth().currentUser?.uid else { fatalError("Not logged in") }
        return uid
    }

    // MARK: - Search
    func searchUsers(keyword: String, limit: Int = 20, completion: @escaping (Result<[UserPublic], Error>) -> Void) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { completion(.success([])); return }

        if trimmed.hasPrefix("@") || !trimmed.contains(" ") {
            let idKey = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
            db.collection("usernames").document(idKey).getDocument { snap, err in
                if let err = err { completion(.failure(err)); return }
                guard let data = snap?.data(), let uid = data["uid"] as? String else {
                    completion(.success([])); return
                }
                self.fetchUser(uid: uid, completion: completion)
            }
            return
        }

        let lower = trimmed.lowercased()
        let end = lower + "\u{f8ff}"
        db.collection("users")
            .whereField("name_lower", isGreaterThanOrEqualTo: lower)
            .whereField("name_lower", isLessThanOrEqualTo: end)
            .limit(to: limit)
            .getDocuments { snap, err in
                if let err = err { completion(.failure(err)); return }
                let users: [UserPublic] = snap?.documents.compactMap { doc in
                    let d = doc.data()
                    guard let name = d["name"] as? String,
                          let idStr = d["id"] as? String else { return nil }
                    return UserPublic(uid: doc.documentID, idString: idStr, name: name, photoURL: d["photoURL"] as? String)
                } ?? []
                completion(.success(users.filter { $0.uid != self.meUid }))
            }
    }

    private func fetchUser(uid: String, completion: @escaping (Result<[UserPublic], Error>) -> Void) {
        db.collection("users").document(uid).getDocument { snap, err in
            if let err = err { completion(.failure(err)); return }
            guard let d = snap?.data(),
                  let name = d["name"] as? String,
                  let idStr = d["id"] as? String else {
                completion(.success([])); return
            }
            completion(.success([UserPublic(uid: uid, idString: idStr, name: name, photoURL: d["photoURL"] as? String)]))
        }
    }

    // MARK: - Send / Cancel
    func sendRequest(to target: UserPublic, completion: @escaping (Result<Void, Error>) -> Void) {
        let batch = db.batch()
        let myRef = db.collection("users").document(meUid)
        let targetRef = db.collection("users").document(target.uid)

        let outRef = myRef.collection("requestsOutgoing").document(target.uid)
        batch.setData([
            "targetUid": target.uid,
            "targetId": target.idString,
            "targetName": target.name,
            "status": "pending",
            "createdAt": FieldValue.serverTimestamp()
        ], forDocument: outRef)

        let inRef = targetRef.collection("requestsIncoming").document(meUid)
        myRef.getDocument { snap, err in
            if let err = err { completion(.failure(err)); return }
            let myName = (snap?.data()?["name"] as? String) ?? ""
            let myId   = (snap?.data()?["id"] as? String) ?? ""
            batch.setData([
                "senderUid": self.meUid,
                "senderName": myName,
                "senderId": myId,
                "status": "pending",
                "createdAt": FieldValue.serverTimestamp()
            ], forDocument: inRef)

            batch.commit { error in
                if let error = error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }

    func cancelRequest(to targetUid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let batch = db.batch()
        let myRef = db.collection("users").document(meUid)
        let targetRef = db.collection("users").document(targetUid)
        batch.deleteDocument(myRef.collection("requestsOutgoing").document(targetUid))
        batch.deleteDocument(targetRef.collection("requestsIncoming").document(meUid))
        batch.commit { error in
            if let error = error { completion(.failure(error)) } else { completion(.success(())) }
        }
    }

    // MARK: - Accept / Remove
    func acceptRequest(from requester: UserPublic, completion: @escaping (Result<Void, Error>) -> Void) {
        let batch = db.batch()
        let myRef = db.collection("users").document(meUid)
        let rqInRef = myRef.collection("requestsIncoming").document(requester.uid)
        let rqOutRef = db.collection("users").document(requester.uid)
            .collection("requestsOutgoing").document(meUid)

        let myFriendsRef = myRef.collection("friends").document(requester.uid)
        let hisFriendsRef = db.collection("users").document(requester.uid)
            .collection("friends").document(meUid)

        myRef.getDocument { mySnap, err in
            if let err = err { completion(.failure(err)); return }
            let myName = (mySnap?.data()?["name"] as? String) ?? ""
            let myId   = (mySnap?.data()?["id"] as? String) ?? ""

            batch.setData([
                "friendUid": requester.uid,
                "friendName": requester.name,
                "friendId": requester.idString,
                "createdAt": FieldValue.serverTimestamp()
            ], forDocument: myFriendsRef)

            batch.setData([
                "friendUid": self.meUid,
                "friendName": myName,
                "friendId": myId,
                "createdAt": FieldValue.serverTimestamp()
            ], forDocument: hisFriendsRef)

            batch.deleteDocument(rqInRef)
            batch.deleteDocument(rqOutRef)

            batch.commit { error in
                if let error = error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }

    func removeFriend(_ friendUid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let batch = db.batch()
        let myRef = db.collection("users").document(meUid)
        let hisRef = db.collection("users").document(friendUid)
        batch.deleteDocument(myRef.collection("friends").document(friendUid))
        batch.deleteDocument(hisRef.collection("friends").document(meUid))
        batch.commit { error in
            if let error = error { completion(.failure(error)) } else { completion(.success(())) }
        }
    }

    // MARK: - Watch / Fetch
    func watchIncomingRequestCount(_ onUpdate: @escaping (Int) -> Void) -> ListenerRegistration {
        let q = db.collection("users").document(meUid)
            .collection("requestsIncoming")
            .whereField("status", isEqualTo: "pending")
        return q.addSnapshotListener { snap, _ in
            onUpdate(snap?.documents.count ?? 0)
        }
    }

    func fetchFriends(completion: @escaping (Result<[Friend], Error>) -> Void) {
        db.collection("users").document(meUid).collection("friends")
            .order(by: "createdAt", descending: true)
            .getDocuments { snap, err in
                if let err = err { completion(.failure(err)); return }
                let list: [Friend] = snap?.documents.compactMap { d in
                    guard let name = d["friendName"] as? String,
                          let fid  = d["friendId"] as? String,
                          let ts = d["createdAt"] as? Timestamp else { return nil }
                    return Friend(friendUid: d.documentID, friendName: name, friendId: fid, createdAt: ts.dateValue())
                } ?? []
                completion(.success(list))
            }
    }

    func fetchIncomingRequests(completion: @escaping (Result<[FriendRequest], Error>) -> Void) {
        db.collection("users").document(meUid).collection("requestsIncoming")
            .whereField("status", isEqualTo: "pending")
            .order(by: "createdAt", descending: true)
            .getDocuments { snap, err in
                if let err = err { completion(.failure(err)); return }
                let list: [FriendRequest] = snap?.documents.compactMap { d in
                    guard let name = d["senderName"] as? String,
                          let sid  = d["senderId"] as? String,
                          let ts = d["createdAt"] as? Timestamp else { return nil }
                    return FriendRequest(fromUid: d.documentID, fromName: name, fromId: sid, createdAt: ts.dateValue())
                } ?? []
                completion(.success(list))
            }
    }
}
