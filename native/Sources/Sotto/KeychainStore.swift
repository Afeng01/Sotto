import Foundation
import Security

/// 豆包 API Key 的 macOS Keychain 存取（kSecClassGenericPassword）。
/// 非 sandbox 的 ad-hoc 签名 app 直接走 Security API，无需 entitlements。
enum KeychainStore {
    static let service = "com.luming.sotto.native"
    static let account = "doubao-api-key"

    /// 读取结果三态：found 有值 / missing 项不存在 / denied 系统拒绝访问。
    /// denied（errSecInteractionNotAllowed，常见于 app 签名变更后 ACL 不匹配）
    /// 绝不能呈现为「项不存在/为空」，调用方必须提示用户重新粘贴保存。
    enum AccessResult {
        case found(String)
        case missing
        case denied
    }

    @discardableResult
    static func set(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func getStatus() -> AccessResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8), !value.isEmpty else { return .missing }
            return .found(value)
        case errSecInteractionNotAllowed:
            // 项存在但当前进程无权读取（签名/ACL 变更），与「不存在」区分开
            return .denied
        default:
            return .missing
        }
    }

    static func get() -> String? {
        if case .found(let value) = getStatus() { return value }
        return nil
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
