#pragma once
#include <string>
#include <string_view>
#include <vector>

namespace gc {

inline std::string trim(std::string_view s) {
  size_t a = 0, b = s.size();
  while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n')) a++;
  while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r' || s[b - 1] == '\n')) b--;
  return std::string(s.substr(a, b - a));
}

inline std::string stripQuotes(std::string_view s) {
  std::string t = trim(s);
  if (t.size() >= 2 && t.front() == '"' && t.back() == '"') return t.substr(1, t.size() - 2);
  return t;
}

inline std::vector<std::string> splitLines(std::string_view text) {
  std::vector<std::string> out;
  size_t start = 0;
  while (start <= text.size()) {
    size_t nl = text.find('\n', start);
    if (nl == std::string_view::npos) nl = text.size();
    out.emplace_back(text.substr(start, nl - start));
    start = nl + 1;
    if (nl == text.size()) break;
  }
  return out;
}

inline std::vector<std::string> splitWs(std::string_view s) {
  std::vector<std::string> out;
  size_t i = 0;
  while (i < s.size()) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) i++;
    size_t j = i;
    while (j < s.size() && s[j] != ' ' && s[j] != '\t') j++;
    if (j > i) out.emplace_back(s.substr(i, j - i));
    i = j;
  }
  return out;
}

inline std::string toLower(std::string s) {
  for (auto& c : s) c = char(tolower(static_cast<unsigned char>(c)));
  return s;
}

inline bool startsWith(std::string_view s, std::string_view p) { return s.size() >= p.size() && s.substr(0, p.size()) == p; }

/// Decodes chart/ini text with BOM sniffing (UTF-8 BOM stripped, UTF-16 LE/BE converted).
std::string decodeText(const std::vector<uint8_t>& data);

}  // namespace gc
