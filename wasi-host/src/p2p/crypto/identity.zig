/// ED25519 身份管理：密钥对生成、签名、验签、序列化

const std = @import("std");

pub const Seed = [32]u8;
pub const PublicKeyBytes = [32]u8;
pub const SecretKeyBytes = [64]u8;
pub const SignatureBytes = [64]u8;

const Ed25519 = std.crypto.sign.Ed25519;

/// P2P 节点身份，封装 ED25519 密钥对
pub const Identity = struct {
    key_pair: Ed25519.KeyPair,

    /// 生成随机新密钥对
    pub fn generate() Identity {
        return .{ .key_pair = Ed25519.KeyPair.generate() };
    }

    /// 从种子恢复密钥对（用于持久化重启）
    pub fn fromSeed(seed_bytes: Seed) !Identity {
        return .{ .key_pair = try Ed25519.KeyPair.generateDeterministic(seed_bytes) };
    }

    /// 从密钥对字节恢复
    pub fn fromSecretKey(sk: SecretKeyBytes) !Identity {
        const secret_key = try Ed25519.SecretKey.fromBytes(sk);
        return .{ .key_pair = try Ed25519.KeyPair.fromSecretKey(secret_key) };
    }

    /// 获取公钥字节
    pub fn publicKeyBytes(self: Identity) PublicKeyBytes {
        return self.key_pair.public_key.toBytes();
    }

    /// 获取私钥种子（用于持久化）
    pub fn seed(self: Identity) Seed {
        return self.key_pair.secret_key.seed();
    }

    /// 对消息签名
    pub fn sign(self: Identity, msg: []const u8) !SignatureBytes {
        const sig = try self.key_pair.sign(msg, null);
        return sig.toBytes();
    }

    /// 获取公钥的 SHA-1 哈希作为 Chord 节点 ID
    pub fn chordId(self: Identity) [20]u8 {
        const pk = self.key_pair.public_key.toBytes();
        var h = std.crypto.hash.Sha1.init(.{});
        h.update(&pk);
        var out: [20]u8 = undefined;
        h.final(&out);
        return out;
    }
};

/// 验证签名
pub fn verify(pubkey: PublicKeyBytes, msg: []const u8, sig_bytes: SignatureBytes) !void {
    const pk = try Ed25519.PublicKey.fromBytes(pubkey);
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    try sig.verify(msg, pk);
}

/// 将公钥编码为 base64 字符串
pub fn pubkeyToBase64(pk: PublicKeyBytes) [44]u8 {
    var buf: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&buf, &pk);
    return buf;
}

/// 从 base64 解码公钥
pub fn pubkeyFromBase64(encoded: []const u8) !PublicKeyBytes {
    var buf: PublicKeyBytes = undefined;
    _ = try std.base64.standard.Decoder.decode(&buf, encoded);
    return buf;
}

test "identity generate sign verify" {
    const id = Identity.generate();
    const msg = "test message";
    const sig = try id.sign(msg);
    try verify(id.publicKeyBytes(), msg, sig);
}

test "identity from seed" {
    var seed: Seed = undefined;
    std.crypto.random.bytes(&seed);
    const id1 = try Identity.fromSeed(seed);
    const id2 = try Identity.fromSeed(seed);
    try std.testing.expectEqualSlices(u8, &id1.publicKeyBytes(), &id2.publicKeyBytes());
}

test "base64 roundtrip" {
    const id = Identity.generate();
    const pk = id.publicKeyBytes();
    const encoded = pubkeyToBase64(pk);
    const decoded = try pubkeyFromBase64(&encoded);
    try std.testing.expectEqualSlices(u8, &pk, &decoded);
}
