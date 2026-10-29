/*
 * compat/nlohmann/json.hpp — nlohmann/json 的**极小替身**（只为 scan_statdulpicate.cpp）
 *
 * 症状：C++ 版 packing_tool 的 src/scan_statdulpicate.cpp 里有
 *       `#include "nlohmann/json.hpp"`；改成 ohos_executable 时 GN 只给了一份
 *       **自研** src/json/（BUILD.gn 里没有 nlohmann 依赖），OHOS 源码树靠全局
 *       include 路径凑巧能看到 nlohmann —— 我们的交叉构建里没有，直接编译失败。
 * 根因：整棵 packing_tool 对 nlohmann 的用法只有 10 行（--stat-duplicate 的报告 JSON）：
 *         nlohmann::json jsonObject;
 *         jsonObject[RESULT] = nlohmann::json::array();
 *         jsonObject[RESULT].push_back({{"files", std::vector<std::string>},
 *                                       {"md5", std::string}, {"size", int64_t}});
 *         jsonObject[k] = std::string;   jsonStr = jsonObject.dump(4);
 *       既没读、也没 get<>/contains/迭代，没有任何"缺一个特性就跑不动"的复杂用法。
 * 修法：不为了 10 行用法往仓库里塞一份 900 KB 上游单头（那会引入一个需要做许可证/
 *       升级评估的第三方依赖），而是照 hapsigntool_cpp/compat 的既有做法写一个
 *       行为对齐的替身：同样的对象/数组语义、同样的 4 空格缩进 dump、同样的
 *       std::map 键序（= nlohmann 默认 object 类型，输出按字典序），字符串按 RFC 8259
 *       转义。**只实现用到的那个子集**；未实现的接口一律不声明 —— 将来有人写了新用法，
 *       编译期就会报"没有这个成员"，而不是悄悄给出错误输出。
 *
 * 影响面：只有 `--stat-duplicate` 这一条诊断路径的 JSON 字符串。HAP/HSP/APP 打包主
 *         链路完全不走这里（packager.cpp 只在 stat-duplicate 分支调它）。
 */
#ifndef PACKING_TOOL_OHOS_COMPAT_NLOHMANN_JSON_HPP
#define PACKING_TOOL_OHOS_COMPAT_NLOHMANN_JSON_HPP

#include <cstdint>
#include <cstdio>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace nlohmann {

class json {
public:
    using object_t = std::map<std::string, json>;
    using array_t = std::vector<json>;

    json() = default;
    json(std::nullptr_t) {}
    json(bool v) : type_(Type::kBool), bool_(v) {}
    json(int v) : type_(Type::kNumber), num_(static_cast<int64_t>(v)) {}
    json(unsigned int v) : type_(Type::kNumber), num_(static_cast<int64_t>(v)) {}
    json(long v) : type_(Type::kNumber), num_(static_cast<int64_t>(v)) {}
    json(unsigned long v) : type_(Type::kNumber), num_(static_cast<int64_t>(v)) {}
    json(long long v) : type_(Type::kNumber), num_(static_cast<int64_t>(v)) {}
    json(unsigned long long v) : type_(Type::kNumber), num_(static_cast<int64_t>(v)) {}
    json(double v) : type_(Type::kNumber), num_(0), isDouble_(true), dbl_(v) {}
    json(const char* v) : type_(Type::kString), str_(v ? v : "") {}
    json(const std::string& v) : type_(Type::kString), str_(v) {}
    json(const std::vector<std::string>& v) : type_(Type::kArray) {
        for (const auto& s : v) arr_.emplace_back(s);
    }
    json(std::initializer_list<std::pair<const std::string, json>> items)
        : type_(Type::kObject) {
        for (const auto& kv : items) obj_[kv.first] = kv.second;
    }

    static json array() { return json(Type::kArray); }

    /* 对象按 key 取子节点；对 null / object 是"取不到就建成 object 再取"，
     * 与 nlohmann 的 operator[] 一致（这里只会用在 object 上）。 */
    json& operator[](const std::string& key) {
        if (type_ != Type::kObject) {
            type_ = Type::kObject;
            arr_.clear();
            str_.clear();
        }
        return obj_[key];
    }
    json& operator[](const char* key) { return (*this)[std::string(key ? key : "")]; }

    void push_back(const json& v) {
        if (type_ != Type::kArray) {
            type_ = Type::kArray;
            obj_.clear();
            str_.clear();
        }
        arr_.push_back(v);
    }
    void push_back(json&& v) {
        if (type_ != Type::kArray) {
            type_ = Type::kArray;
            obj_.clear();
            str_.clear();
        }
        arr_.push_back(std::move(v));
    }

    bool is_null() const { return type_ == Type::kNull; }

    std::string dump(int indent = -1) const {
        std::string out;
        DumpTo(out, indent, 0);
        return out;
    }

private:
    enum class Type { kNull, kBool, kNumber, kString, kArray, kObject };

    explicit json(Type t) : type_(t) {}

    static void Indent(std::string& out, int indent, int depth) {
        if (indent <= 0) return;
        out.append(static_cast<size_t>(indent) * static_cast<size_t>(depth), ' ');
    }

    static void EscapeTo(std::string& out, const std::string& s) {
        out.push_back('"');
        for (unsigned char c : s) {
            switch (c) {
                case '"': out += "\\\""; break;
                case '\\': out += "\\\\"; break;
                case '\b': out += "\\b"; break;
                case '\f': out += "\\f"; break;
                case '\n': out += "\\n"; break;
                case '\r': out += "\\r"; break;
                case '\t': out += "\\t"; break;
                default:
                    if (c < 0x20) {
                        char buf[8];
                        std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                        out += buf;
                    } else {
                        out.push_back(static_cast<char>(c));
                    }
            }
        }
        out.push_back('"');
    }

    void DumpTo(std::string& out, int indent, int depth) const {
        const bool pretty = indent > 0;
        switch (type_) {
            case Type::kNull: out += "null"; return;
            case Type::kBool: out += bool_ ? "true" : "false"; return;
            case Type::kNumber: {
                char buf[64];
                if (isDouble_) {
                    std::snprintf(buf, sizeof(buf), "%.17g", dbl_);
                } else {
                    std::snprintf(buf, sizeof(buf), "%lld", static_cast<long long>(num_));
                }
                out += buf;
                return;
            }
            case Type::kString: EscapeTo(out, str_); return;
            case Type::kArray: {
                if (arr_.empty()) { out += "[]"; return; }
                out += '[';
                for (size_t i = 0; i < arr_.size(); ++i) {
                    if (i) out += ',';
                    if (pretty) { out += '\n'; Indent(out, indent, depth + 1); }
                    arr_[i].DumpTo(out, indent, depth + 1);
                }
                if (pretty) { out += '\n'; Indent(out, indent, depth); }
                out += ']';
                return;
            }
            case Type::kObject: {
                if (obj_.empty()) { out += "{}"; return; }
                out += '{';
                size_t i = 0;
                for (const auto& kv : obj_) {
                    if (i++) out += ',';
                    if (pretty) { out += '\n'; Indent(out, indent, depth + 1); }
                    EscapeTo(out, kv.first);
                    out += pretty ? ": " : ":";
                    kv.second.DumpTo(out, indent, depth + 1);
                }
                if (pretty) { out += '\n'; Indent(out, indent, depth); }
                out += '}';
                return;
            }
        }
    }

    Type type_ = Type::kNull;
    bool bool_ = false;
    int64_t num_ = 0;
    bool isDouble_ = false;
    double dbl_ = 0;
    std::string str_;
    array_t arr_;
    object_t obj_;
};

}  // namespace nlohmann

#endif /* PACKING_TOOL_OHOS_COMPAT_NLOHMANN_JSON_HPP */
