# moonbit-xsd-datatypes

**XSD 1.0 数据类型验证器，纯 MoonBit 实现。**

给定一个 XML Schema 简单类型和一个词法值，判定这个值是否合法，并给出值空间的规范化结果。

> **状态：v0.1。** 44 个内置类型、12 个 facet、三种 variety、XSD 正则方言、
> 文档解析都已落地；W3C 套件 974 个用例全部一致。不做内容模型，边界写在「已知限制」里。

---

## 安装

```bash
moon add ouoankang/moonbit-xsd-datatypes
```

已发布在 mooncakes：<https://mooncakes.io/docs/ouoankang/moonbit-xsd-datatypes>

---

## 这个项目解决什么问题

XML Schema 的验证分两件事：**结构**（元素能不能出现在这里、顺序对不对）和**值**
（这个字符串是不是一个合法的 `xs:date`）。本项目只做后者。

它要回答的是这一类问题：

```text
xs:dateTime  2026-02-30T00:00:00   -> 非法（2 月没有 30 日）
xs:decimal   1.230                 -> 合法，规范化为 1.23
xs:integer   1.0                   -> 非法（integer 的词法空间不含小数点）
xs:double    INF                   -> 合法
xs:hexBinary 0F3                   -> 非法（长度必须是偶数）
```

这类判断是企业数据交换的第一道关：电子发票、政务数据报送、ISO 20022 报文、
UBL 订单，都是先拿 XSD 卡值域，再谈业务。判错一个 `dateTime` 的时区，整批数据
会在对方系统里静默出错。

## 为什么 MoonBit 需要它

截至 2026-10-18 实测，mooncakes 上有 **88 个** XML 相关模块：pull parser 22 个、
OOXML / Office 12 个、XPath 2 个、格式化与工具 32 个。但描述里真正出现
`xsd`、`xml schema`、`datatype`、`facet` 的，**0 个**。

（`xsd` 关键词只命中 1 个 GPX 库的模糊匹配，`xmlschema` 只命中 1 个 XAML 库，
都核实过，与 XSD 无关。）

底层解析齐了，上层验证没人做。本项目补的就是这一层，而不是再造一个 XML 解析器。

## 用法

```bash
moon check --deny-warn     # 零警告
moon test                  # 59 个测试（58 单测 + 1 个 W3C 一致性）

# 直接验证内置类型
moon run --target js cmd/main -- dateTime 2026-02-30T00:00:00

# 读真实 XSD 文件，按其中声明的类型验证
moon run --target js cmd/main -- --schema examples/invoice.xsd amount 100.50 100000000
```

实际输出：

```text
$ moon run --target js cmd/main -- --schema examples/invoice.xsd amount 100.50 99999999.99 100000000 1.234
valid    amount  100.50       =>  100.5
valid    amount  99999999.99  =>  99999999.99
INVALID  amount  100000000    =>  facet violation: value is above maxInclusive
INVALID  amount  1.234        =>  facet violation: fractionDigits 3 exceeds 2
2 value(s) invalid
```

`examples/invoice.xsd` 是一个电子发票风格的 schema，覆盖定长数字码、带精度上限的
金额、闭集税率、真实日历日期。

## 覆盖范围

### 做

- **44 个内置简单类型**，全部落地：`string` 族、`boolean`、`decimal`、
  `float`/`double`、8 个日期时间类型、`duration`、`hexBinary`/`base64Binary`、
  `anyURI`、`QName`、`NOTATION`、以及 12 个 integer 子类型（含范围检查）。
- **12 个 facet**：`length`、`minLength`、`maxLength`、`pattern`、`enumeration`、
  `whiteSpace`（按类型固定）、`maxInclusive`、`maxExclusive`、`minInclusive`、
  `minExclusive`、`totalDigits`、`fractionDigits`。
- **三种 variety**：atomic、list、union。
- **XML Schema 正则方言**（`pattern` 用）：`\d`/`\w`/`\s` 的 Unicode 语义、
  字符类与减法、量词、分组、选择、`\i`/`\c`；`pattern` 按规范**隐式全串锚定**，
  要表达"包含"必须显式写 `.*`。
- **Namespace-aware XML 读取**：元素、属性、文本、CDATA、注释、PI、字符引用、
  实体引用、xmlns 作用域栈。默认命名空间作用于元素、**不**作用于属性。
- **XSD 文档解析**：从 `xs:simpleType` 与 `xs:element` 读出类型，
  支持 `restriction` / `list` / `union`、本地类型引用（含 `nist:someType`
  这种自定义前缀），以及 **element 内联的匿名 `simpleType`**——真实 schema
  和 W3C 套件大量使用这种写法。facet 值按 base 类型解析，所以 decimal 上的
  `minInclusive` 是按 decimal 比较，不是字符串比较。

### 不做（在「已知限制」里逐条列明）

- 内容模型匹配（`sequence` / `choice` / `all`）：需要元素声明与粒子模型，
  是另一层的活，见 [#1](https://github.com/ouoankang/moonbit-xsd-datatypes/issues/1)。
- 身份约束 `key` / `keyref` / `unique`。
- XSD 1.1（assertion、条件类型赋值）。
- PSVI 生成（W3C 套件本身也不检查 PSVI）。
- `substitutionGroup`、`redefine`、`override`。

## 关于命名空间

这一层最容易错，测试专门钉了几条：

- 默认命名空间作用于**元素**，不作用于**属性**；
- 内层声明遮蔽外层，兄弟元素不受影响；
- 未绑定的前缀是**错误**，不能静默当成空 URI；
- 不同前缀绑定到同一 URI 就是同一个名字，前缀本身不参与身份判定。

## 测试

58 个单元测试，覆盖词法空间的边界而非 happy path：`xs:integer` 拒绝 `1.0`、
2 月 30 日是词法合法但值非法、`INF` 区分大小写、`24:00:00` 是 24 点唯一合法值、
`pattern` 全串锚定（`A1` 不匹配 `[A-Z]+`）。另有一个跑 W3C 套件的测试。

```text
Total tests: 59, passed: 59, failed: 0.
w3c cases: 974/974 agreed, 0 schema errors
```

## 已知限制

- **拒绝 DOCTYPE**：不处理内部子集与外部实体。XSD 文档不需要它们，静默忽略反而
  危险，所以显式报错。
- **年份上限 9999**：更大的年份在词法上合法，但这里的日历运算按 4 位年份处理。
- **Unicode 类别是近似实现**：`\p{L}`、`\d` 等按主要区间判断，未加载完整 UCD 表。
  边界用例（生僻文字的类别）可能与规范有差异。
- **字符类减法**只支持一层。
- **不做内容模型**：元素能不能出现、顺序对不对，不在本项目范围内。
- 不做 XML 1.0 完整的 well-formedness 校验（重复属性、非法字符等）。

其中三条有明确的后续路径，记在 Issues 里而不是只留在这份文档中：

- 内容模型（`sequence` / `choice` / `all`）—— [#1](https://github.com/ouoankang/moonbit-xsd-datatypes/issues/1)
- 完整的 Unicode 类别表 —— [#2](https://github.com/ouoankang/moonbit-xsd-datatypes/issues/2)
- 从 974 个抽样用例扩到全量 19217 个 —— [#3](https://github.com/ouoankang/moonbit-xsd-datatypes/issues/3)

## 外部一致性证据

正确性以 **W3C XML Schema Test Suite**（<https://github.com/w3c/xsdtests>）为准。
官方不提供 test driver，README 里明确写着 "No test driver is supplied"，所以
driver 也在本项目范围内。

从 NIST 的 datatypes 贡献里取了 **510 个 (variety, type, facet) 组合**，每个组合
取一个代表性测试组，加一个 valid 和一个 invalid 实例，共 **974 个用例**。

```text
w3c cases: 974/974 agreed, 0 schema errors
```

**完全没有 100% 之前，有 2 个用例一直不一致，值得说明怎么解决的。** 它们用
`length` facet 约束 `xs:QName`：schema 写 `length="1"`，而 NIST 把一个 16 字符的
QName 标为 valid。查规范才明白为什么——XSD 1.0 和 1.1 都写着：

> The use of `length`, `minLength` and `maxLength` on QName, NOTATION, and
> datatypes derived from them is deprecated.

而且两版都没定义 QName 的"长度"到底是什么（它的值空间是三元组，不是字符串）。
规范既然称其为 deprecated 又不给度量方式，实现就没有可执行的规则；套件的 valid
标注反映的正是主流实现的行为。所以本实现在 QName / NOTATION 上跳过这三个 facet，
并在 `facets.mbt` 里写明依据。这不是为了让数字好看而放宽——是按规范原文处理，
并且有注释可查。

数据不随仓库分发：`scripts/gen_w3c.py` 按需下载，`testdata/` 已排除。仓库里只有
生成后的 `src/datatypes/w3c_cases.mbt`，其许可与来源见 `NOTICE`。要复现：

```bash
python scripts/gen_w3c.py     # 需要 GH_TOKEN 或已登录的 gh
moon test
```

## 实现进度

| 模块 | 状态 |
| --- | --- |
| Namespace-aware XML 读取 | 完成，17 测试 |
| 44 个内置类型 | 完成 |
| 12 个 facet | 完成 |
| 类型派生 restriction / list / union | 完成 |
| XML Schema 正则方言 | 完成（Unicode 类别为近似） |
| XSD 文档解析（simpleType / element，含匿名类型） | 完成 |
| CLI（内置类型 / 读 XSD 文件） | 完成 |
| W3C 测试套件 driver | 完成，974/974 一致 |

## 许可

Apache-2.0。第三方测试数据的来源与许可见 `NOTICE`；测试数据不随仓库分发。
