#include "test.h"

std::vector<TestCase>& allTests() { static std::vector<TestCase> t; return t; }
int& failCount() { static int f = 0; return f; }

int main() {
  setvbuf(stdout, nullptr, _IONBF, 0);
  int failed = 0;
  for (const auto& t : allTests()) {
    const int before = failCount();
    t.fn();
    const bool ok = failCount() == before;
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", t.name);
    if (!ok) failed++;
  }
  std::printf("\n%zu tests, %d failed\n", allTests().size(), failed);
  return failed ? 1 : 0;
}
