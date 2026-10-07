# Chord DHT 工作原理（本项目实现）

本文档结合 `src/p2p/chord/` 下的实际代码说明 Chord 是如何工作的。

代码位置：
- [ring.zig](../src/p2p/chord/ring.zig) — 哈希环基础类型与区间运算
- [routing.zig](../src/p2p/chord/routing.zig) — 路由表（finger 表、后继、前驱）
- [types.zig](../src/p2p/chord/types.zig) — 协议消息
- [node.zig](../src/p2p/chord/node.zig) — 节点主循环、加入、stabilize、DHT 存储

---

## 1. 环形 ID 空间

```zig
pub const NodeId = u160;       // 160 bit
pub const M: u8 = 160;         // 环的位数
```

- 节点和数据 key 都映射到 160 位的无符号整数空间 `[0, 2^160)`。
- 空间首尾相接形成环：`NodeId(2^160) == NodeId(0)`。
- 距离用顺时针方向定义：`distance(a, b) = (b - a) mod 2^160`。

### 区间判定（核心）

```zig
between(x, left, right)   // x ∈ (left, right] ，左开右闭
betweenLeftInclusive(x, left, right)  // x ∈ [left, right) ，左闭右开
```

区间要处理环回绕：当 `left > right` 时，区间跨过 0 点。

例：`between(50, 40, 100) = true`，`between(200, 250, 100) = true`（200 落在 250→0→100 的顺时针弧上）。

---

## 2. ID 的来源

### 节点 ID

来自配置中的 `key_file`（如 `p2p_key_seed.bin`）：

```
NodeId = SHA256(节点私钥) 的前 20 字节 → u160 大端
```

同一个 `key_file` 产生稳定的节点 ID，所以节点重启后 ID 不变。

### 数据 Key 的环位置

DHT 存储的 key 是字符串（如 `wasm/v1/<hash>`），负责它的节点：

```zig
// content.zig
keyToId(key) = SHA256(key_string) 前 20 字节 → u160
```

负责节点 = 环上 **ID ≥ key_id 的最小节点**（即 key 的后继 successor）。

> 内容寻址插件的身份是 `SHA256(字节码)` 的 64 位 hex，但其环位置再对键字符串 `wasm/v1/<hex>` 做一次 SHA256，与字节码 hash 不同。

---

## 3. 每个节点维护的状态

```
Routing:
  own_id              // 本节点 ID
  successor           // 直接后继（顺时针方向上第一个节点）
  predecessor         // 直接前驱
  backup_successors[2]// 后继的备份，主后继挂了立刻切换
  fingers[160]        // finger 表
```

### 后继 / 前驱

环上相邻的两个节点互为后继-前驱。数据归它的后继负责，所以后继是最关键的指针——**绝不能 null**。

### Finger 表

每个节点维护 160 个 finger（M=160）：

```
fingers[i].start = (own_id + 2^i) mod 2^160
fingers[i].node  = 环上第一个 ID ≥ start 的节点
```

finger[0] 必然等于 successor。finger 表让查找的每一步能跳过半程距离，实现 **O(log N)** 查找。

---

## 4. 三种核心协议消息

| 消息 | 方向 | 作用 |
|------|------|------|
| `find_successor(target)` | 请求 | 询问"target 的后继是谁" |
| `get_predecessor` | 请求 | 询问"你的前驱是谁"（stabilize 用） |
| `notify(node)` | 请求 | 告诉对方"我可能是你的前驱" |

### find_successor 的本地处理

```zig
// routing.zig
findSuccessor(target):
    if target ∈ (own_id, successor]:
        return successor          // 答案就是我的后继
    else:
        return closestPrecedingNode(target)  // 把请求转发给最接近 target 的 finger
```

`closestPrecedingNode` 从最大的 finger 往前找，返回第一个 ID 落在 `(own_id, target)` 内的节点。收到转发请求的节点重复同样逻辑，直到某个节点的后继直接覆盖 target。

这就是 Chord 的贪心路由：每一跳把请求送到离 target 更近的节点。

---

## 5. 节点加入（join）

新节点 N 必须通过 bootstrap（已知节点 B）入环：

```
1. N 向 B 发 find_successor(N.own_id)
2. B 返回 N 的后继 S
3. N 设置 successor = S
4. N 快速填充 finger 表：
   - finger[0] = S
   - 对于 i=1..15：若 start ∈ (N, S]，finger[i] = S
     否则向 S 发 find_successor(start) 查询
```

**注意**：N 加入后，S 的 predecessor 还没更新，这要等下一轮 stabilize 完成。

---

## 6. 周期性维护（stabilize / fix_fingers / check_predecessor）

`tick()` 由外部定时调用，里面跑三个维护任务。

### 6.1 stabilize（最关键）

```
1. 若 successor 为 null → 设置为自身（孤立 seed），返回
2. 向 successor 发 get_predecessor
   - 失败 → 用 backup_successors 切换，不行再重连 bootstrap
3. 拿到 successor 的前驱 P：
   - 若 P ∈ (N, successor)：后继应该是 P，更新 successor = P
   - 特例：successor == N 且 P != N（孤立 seed 发现新节点）→ successor = P
4. 向 successor 发 notify(N)，让对方知道 N 可能是它的前驱
5. 查 successor 的后继，填充 backup_successors
```

notify 的处理端：

```zig
// routing.zig notifyCandidate
if 我的前驱为空 or 就是自己:
    predecessor = candidate
else if candidate ∈ (pred, N):
    predecessor = candidate   // 新节点在我和旧前驱之间，更靠近我
```

### 6.2 fix_fingers

每次 tick 修复一个 finger（轮询 `next_finger`）：

```
start = fingers[next_finger].start
fingers[next_finger].node = findSuccessor(start)
next_finger = (next_finger + 1) % 160
```

逐步把整张表更新到最新拓扑。

### 6.3 check_predecessor

向前驱发 ping，若超时则 `predecessor = null`（让后继在 stabilize 时重新学到前驱）。

---

## 7. DHT 数据存取

### put

```zig
// content.zig publish()
target = locateKey(keyToId(key))   // 找到负责该 key 的节点
sendAndWait(.dht_put{key, value, ...}, target)
```

存储侧（`handleMessage .dht_put`）：
- 校验权限（`permission` 字段，枚举见 [metadata/permission.zig](../src/p2p/metadata/permission.zig)）
- 写入本地 KV 存储，并复制到后继（`dht_replicate`）实现副本

### get

```zig
target = locateKey(keyToId(key))
sendAndWait(.dht_get{key}, target) → 返回 value
```

---

## 8. 故障转移

后继失效时不能等 fix_fingers 慢慢修，否则数据不可达：

1. **备份后继**：stabilize 时查询 successor 的 successor，存入 `backup_successors[2]`
2. **立即切换**：`get_predecessor` 超时 → 从备份取出可用节点设为新 successor
3. **Bootstrap 兜底**：备份也全挂 → 重新向 bootstrap 节点 join

---

## 9. 传输层

协议消息本身与传输无关（统一编解码为 JSON），底层有三种通道：

| 通道 | 用途 | 配置开关 |
|------|------|---------|
| UDP | 默认，直连局域网/公网可达节点 | `transport_mode: udp` |
| TCP | ext 等 UDP 入站被屏蔽的节点 | `transport_mode: tcp` + `tcp_port` |
| 加密中继 | NAT 后无法直连时经 relay-server 转发 | `encrypted_relay.relays` |

发送时按优先级尝试：直连 → relay 回退。

---

## 10. 实际部署中的拓扑示例

LAN 三节点（已验证成环）：

```
ID 排序: node59(f11ee1) < seed(7b6bb7) < node60(b3f6ac)
                                      ↑
                           后继方向（顺时针）
```

- seed（bootstrap 空）→ 自成单节点环
- node59/60 → bootstrap 指向 seed，join 后形成环
- stabilize 每 30s 跑一次，finger 表逐步收敛

---

## 11. 常见问题定位

| 现象 | 可能原因 |
|------|---------|
| 后继长期等于自身 | bootstrap 不可达，stabilize 重连失败 |
| `get_predecessor` 超时 | 后继节点挂了或网络不通，看是否切到备份 |
| finger 表大量空 | fix_fingers 没跑起来或后继不可达 |
| find_successor 绕一圈才到 | finger 表陈旧，等几轮 fix_fingers |
