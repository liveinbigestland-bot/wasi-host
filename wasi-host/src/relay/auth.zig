/// 接入鉴权 — ED25519 签名挑战
const std = @import("std");
const crypto = std.crypto;
const Ed25519 = crypto.sign.Ed25519;

pub const NodeID = @import("registry.zig").NodeID;

pub const Challenge = [32]u8;
pub const Signature = [64]u8;
pub const PublicKey = [32]u8;

pub const Auth = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Auth {
        return Auth{ .alloc = alloc };
    }

    pub fn deinit(_: *Auth) void {}

    /// 生成随机挑战 nonce
    pub fn generateChallenge() Challenge {
        var challenge: Challenge = undefined;
        crypto.random.bytes(&challenge);
        return challenge;
    }

    /// 验证 ED25519 签名
    /// public_key: 节点公钥 (32 字节)
    /// message: 被签名的消息（挑战 nonce）
    /// signature: ED25519 签名 (64 字节)
    pub fn verifySignature(public_key: PublicKey, message: []const u8, signature: Signature) bool {
        const pk = Ed25519.PublicKey.fromBytes(public_key) catch return false;
        const sig = Ed25519.Signature.fromBytes(signature);
        sig.verify(message, pk) catch return false;
        return true;
    }

    /// 从 NodeID 派生验证用的公钥
    /// 注：NodeID 是公钥的 SHA-1 哈希，但验证需要完整公钥。
    /// 因此注册时必须同时提交公钥，或从 NodeID 查找公钥映射表。
    /// 当前设计：注册帧中节点同时提交 NodeID + 公钥。
    pub fn derivePublicKey(_: Auth, node_id: NodeID) ?PublicKey {
        _ = node_id;
        // NodeID is SHA-1 of public key — one-way, cannot recover.
        // Public key must be provided during registration.
        return null;
    }
};
